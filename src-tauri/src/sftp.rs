use crate::models::{
    AppSettings, RemoteFile, SftpAccount, SftpConflictGroup, SftpConflictOwner,
    SftpConflictProgress, SftpConflictReport, SftpConnectionResult, SftpOperationResult,
    UploadResult,
};
use crate::paths::{safe_file_component, AppPaths};
use anyhow::{bail, Context, Result};
use base64::Engine;
use chrono::{TimeZone, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use ssh2::{Session, Sftp};
use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};
use std::fs::File;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use uuid::Uuid;
use walkdir::WalkDir;

const MAX_REMOTE_SCAN_DIRECTORIES: usize = 96;
const MAX_REMOTE_SCAN_DEPTH: usize = 7;
const MAX_REMOTE_SCAN_ENTRIES_PER_DIRECTORY: usize = 300;
const MAX_REMOTE_TREE_ENTRIES: usize = 20_000;
const MAX_REMOTE_CONFLICT_MODS: usize = 64;
const MAX_REMOTE_CONFLICT_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const MAX_REMOTE_NOTE_CHARS: usize = 20_000;
const CONFLICT_DOWNLOAD_WORKERS: usize = 4;
const CONFLICT_PARSE_WORKERS: usize = 4;
const CONFLICT_DOWNLOAD_CHUNK_BYTES: usize = 512 * 1024;
const CONFLICT_PROGRESS_INTERVAL: Duration = Duration::from_millis(140);
const MAX_CONFLICT_ENTRIES_CACHE_BYTES: u64 = 64 * 1024 * 1024;

pub type SftpConflictProgressCallback = Arc<dyn Fn(SftpConflictProgress) + Send + Sync>;

pub fn active_account<'a>(
    settings: &'a AppSettings,
    account_id: Option<&str>,
) -> Result<&'a SftpAccount> {
    if let Some(id) = account_id {
        return settings
            .sftp_accounts
            .iter()
            .find(|item| item.id == id)
            .with_context(|| format!("找不到指定的 SFTP 账户 {id}"));
    }
    if let Some(active_id) = settings.active_sftp_account_id.as_deref() {
        if let Some(account) = settings
            .sftp_accounts
            .iter()
            .find(|item| item.id == active_id)
        {
            return Ok(account);
        }
    }
    settings
        .sftp_accounts
        .first()
        .context("尚未保存 SFTP 服务器账户")
}

pub fn test_connection(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
) -> Result<SftpConnectionResult> {
    let account = active_account(settings, Some(account_id))?;
    let session = handshake_session(account)?;
    let fingerprint = host_key_fingerprint(&session)?;
    match expected_fingerprint(paths, account)? {
        Some(expected) if expected != fingerprint => {
            bail!(
                "服务器主机密钥已变化，已拒绝连接。已信任指纹：{expected}；当前指纹：{fingerprint}"
            );
        }
        Some(_) => {}
        None => {
            return Ok(SftpConnectionResult {
                ok: false,
                message: format!(
                    "首次连接需要确认服务器主机密钥指纹：{fingerprint}。请与服务器管理员核对后再信任。"
                ),
                detected_mods_path: None,
                detected_ue4ss_path: None,
                pak_mods: Vec::new(),
                ue4ss_mods: Vec::new(),
                scanned_directories: 0,
                home_path: None,
                host_key_fingerprint: Some(fingerprint),
                requires_trust: true,
            });
        }
    }
    authenticate_session(paths, &session, account)?;
    let sftp = session.sftp().context("无法建立 SFTP 通道")?;
    let home_path = sftp
        .realpath(Path::new("."))
        .ok()
        .map(|path| path.to_string_lossy().into_owned());
    let detected = detect_server_paths(&sftp, account);
    let pak_mods = detected
        .pak_mods_path
        .as_deref()
        .map(|path| list_pak_mods(&sftp, path))
        .unwrap_or_default();
    let ue4ss_mods = detected
        .ue4ss_mods_path
        .as_deref()
        .map(|path| list_ue4ss_mods(&sftp, path))
        .unwrap_or_default();
    let mut found = Vec::new();
    if let Some(path) = &detected.pak_mods_path {
        found.push(format!("PAK {path}"));
    }
    if let Some(path) = &detected.ue4ss_mods_path {
        found.push(format!("UE4SS {path}"));
    }
    Ok(SftpConnectionResult {
        ok: true,
        message: if found.is_empty() {
            format!(
                "连接成功，但未自动定位 PAK / UE4SS 模组目录（已检查 {} 个远端目录）",
                detected.scanned_directories
            )
        } else {
            format!(
                "连接成功，已定位 {}；发现 {} 个 PAK、{} 个 UE4SS 模组",
                found.join("、"),
                pak_mods.len(),
                ue4ss_mods.len()
            )
        },
        detected_mods_path: detected.pak_mods_path,
        detected_ue4ss_path: detected.ue4ss_mods_path,
        pak_mods,
        ue4ss_mods,
        scanned_directories: detected.scanned_directories,
        home_path,
        host_key_fingerprint: Some(fingerprint),
        requires_trust: false,
    })
}

pub fn trust_host(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
    expected_fingerprint: &str,
) -> Result<SftpConnectionResult> {
    let account = active_account(settings, Some(account_id))?;
    let session = handshake_session(account)?;
    let fingerprint = host_key_fingerprint(&session)?;
    if expected_fingerprint.trim() != fingerprint {
        bail!(
            "主机指纹已变化，拒绝保存。待确认：{}；当前：{fingerprint}",
            expected_fingerprint.trim()
        );
    }
    let key = known_host_key(account);
    let mut known_hosts = load_known_hosts(paths)?;
    if let Some(existing) = known_hosts.hosts.get(&key) {
        if existing != &fingerprint {
            bail!(
                "该服务器已信任其他主机密钥，拒绝静默替换。已信任：{existing}；当前：{fingerprint}"
            );
        }
    }
    known_hosts.hosts.insert(key, fingerprint.clone());
    save_known_hosts(paths, &known_hosts)?;
    Ok(SftpConnectionResult {
        ok: true,
        message: format!("已信任服务器主机密钥 {fingerprint}"),
        detected_mods_path: None,
        detected_ue4ss_path: None,
        pak_mods: Vec::new(),
        ue4ss_mods: Vec::new(),
        scanned_directories: 0,
        home_path: None,
        host_key_fingerprint: Some(fingerprint),
        requires_trust: false,
    })
}

pub fn list_files(
    paths: &AppPaths,
    settings: &AppSettings,
    remote_path: &str,
) -> Result<Vec<RemoteFile>> {
    let account = active_account(settings, None)?;
    let path = if remote_path.trim().is_empty() {
        account.mods_path.as_str()
    } else {
        remote_path.trim()
    };
    with_sftp(paths, account, |sftp| Ok(read_remote_files(sftp, path)))
}

pub fn download_file(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
    remote_path: &str,
    local_path: &str,
) -> Result<SftpOperationResult> {
    let account = active_account(settings, Some(account_id))?;
    let remote_path = normalize_remote_path(remote_path);
    if !is_clean_remote_path(&remote_path) {
        bail!("远端文件路径无效");
    }
    let local_path = PathBuf::from(local_path);
    if local_path.as_os_str().is_empty() {
        bail!("本地保存路径无效");
    }
    let name = entry_name(&remote_path);
    with_sftp(paths, account, |sftp| {
        let stat = sftp
            .stat(Path::new(&remote_path))
            .with_context(|| format!("无法读取远端文件 {remote_path}"))?;
        if stat.is_dir() {
            bail!("不能把远端目录下载为单个文件");
        }
        let file_name = local_path
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
            .unwrap_or_else(|| "download".to_string());
        let partial = local_path.with_file_name(format!(".{file_name}.{}.part", Uuid::new_v4()));
        let download = (|| -> Result<()> {
            let mut remote = sftp
                .open(Path::new(&remote_path))
                .with_context(|| format!("无法读取远端文件 {remote_path}"))?;
            let mut output = File::create(&partial)
                .with_context(|| format!("无法创建本地文件 {}", partial.display()))?;
            std::io::copy(&mut remote, &mut output)
                .with_context(|| format!("无法下载远端文件 {remote_path}"))?;
            output.flush()?;
            if local_path.exists() {
                std::fs::remove_file(&local_path)
                    .with_context(|| format!("无法覆盖本地文件 {}", local_path.display()))?;
            }
            std::fs::rename(&partial, &local_path)
                .with_context(|| format!("无法提交本地文件 {}", local_path.display()))?;
            Ok(())
        })();
        if download.is_err() {
            let _ = std::fs::remove_file(&partial);
        }
        download?;
        Ok(())
    })?;
    Ok(SftpOperationResult {
        message: format!("已下载远端文件 {name}"),
        path: local_path.to_string_lossy().into_owned(),
    })
}

pub fn upload_files(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
    kind: &str,
    local_paths: &[String],
) -> Result<UploadResult> {
    let account = active_account(settings, Some(account_id))?;
    match kind {
        "pak" => upload_pak_files(paths, account, local_paths),
        "ue4ss" => upload_ue4ss_directories(paths, account, local_paths),
        _ => bail!("不支持的远端模组类型：{kind}"),
    }
}

pub fn rename_entry(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
    remote_path: &str,
    new_name: &str,
) -> Result<SftpOperationResult> {
    let account = active_account(settings, Some(account_id))?;
    ensure_remote_operation_allowed(account, remote_path)?;
    if normalize_remote_path(remote_path) == normalize_remote_path(&account.mods_path)
        || normalize_remote_path(remote_path) == normalize_remote_path(&account.ue4ss_path)
    {
        bail!("不能重命名模组根目录");
    }
    let new_name = validate_remote_name(new_name)?;
    let source = normalize_remote_path(remote_path);
    let parent = remote_parent(&source).context("远端模组路径缺少父目录")?;
    let target = remote_join(&parent, &new_name);
    ensure_remote_operation_allowed(account, &target)?;
    if source.eq_ignore_ascii_case(&target) {
        return Ok(SftpOperationResult {
            message: "远端模组名称未变化".to_string(),
            path: source,
        });
    }
    if source.to_ascii_lowercase().ends_with(".pak")
        && !target.to_ascii_lowercase().ends_with(".pak")
    {
        bail!("PAK 模组必须保留 .pak 扩展名");
    }

    with_sftp(paths, account, |sftp| {
        if sftp.lstat(Path::new(&target)).is_ok() {
            bail!("目标名称已存在：{target}");
        }
        let signature_pair = source.to_ascii_lowercase().ends_with(".pak").then(|| {
            (
                remote_with_extension(&source, "sig"),
                remote_with_extension(&target, "sig"),
            )
        });
        if let Some((source_sig, target_sig)) = &signature_pair {
            if sftp.lstat(Path::new(source_sig)).is_ok()
                && sftp.lstat(Path::new(target_sig)).is_ok()
            {
                bail!("目标签名文件已存在：{target_sig}");
            }
        }
        sftp.rename(Path::new(&source), Path::new(&target), None)
            .with_context(|| format!("无法重命名远端模组 {source} -> {target}"))?;
        if let Some((source_sig, target_sig)) = signature_pair {
            if sftp.lstat(Path::new(&source_sig)).is_ok() {
                sftp.rename(Path::new(&source_sig), Path::new(&target_sig), None)
                    .with_context(|| {
                        format!("无法重命名远端签名文件 {source_sig} -> {target_sig}")
                    })?;
            }
        }
        Ok(())
    })?;
    let _ = move_remote_notes(paths, account_id, &source, &target);
    Ok(SftpOperationResult {
        message: format!("已重命名为 {}", entry_name(&target)),
        path: target,
    })
}

pub fn delete_entry(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
    remote_path: &str,
) -> Result<SftpOperationResult> {
    let account = active_account(settings, Some(account_id))?;
    ensure_remote_operation_allowed(account, remote_path)?;
    let target = normalize_remote_path(remote_path);
    if target == normalize_remote_path(&account.mods_path)
        || target == normalize_remote_path(&account.ue4ss_path)
    {
        bail!("不能删除模组根目录");
    }
    let name = entry_name(&target);
    with_sftp(paths, account, |sftp| {
        let mut visited = 0;
        remove_remote_tree(sftp, &target, 0, &mut visited)?;
        if target.to_ascii_lowercase().ends_with(".pak") {
            let signature = remote_with_extension(&target, "sig");
            if sftp.lstat(Path::new(&signature)).is_ok() {
                sftp.unlink(Path::new(&signature))
                    .with_context(|| format!("无法删除远端签名文件 {signature}"))?;
            }
        }
        Ok(())
    })?;
    let _ = remove_remote_notes_under(paths, account_id, &target);
    Ok(SftpOperationResult {
        message: format!("已删除远端模组 {name}"),
        path: target,
    })
}

pub fn read_remote_notes(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
) -> Result<BTreeMap<String, String>> {
    active_account(settings, Some(account_id))?;
    Ok(load_remote_notes(paths)?
        .accounts
        .remove(account_id)
        .unwrap_or_default())
}

pub fn save_remote_note(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
    remote_path: &str,
    note: &str,
) -> Result<BTreeMap<String, String>> {
    active_account(settings, Some(account_id))?;
    let remote_path = normalize_remote_path(remote_path);
    if !is_clean_remote_path(&remote_path) {
        bail!("远端模组路径无效");
    }
    if note.chars().count() > MAX_REMOTE_NOTE_CHARS {
        bail!("备注不能超过 {MAX_REMOTE_NOTE_CHARS} 个字符");
    }
    let mut notes = load_remote_notes(paths)?;
    let account_notes = {
        let account_notes = notes.accounts.entry(account_id.to_string()).or_default();
        if note.trim().is_empty() {
            account_notes.remove(&remote_path);
        } else {
            account_notes.insert(remote_path, note.to_string());
        }
        account_notes.clone()
    };
    save_remote_notes(paths, &notes)?;
    Ok(account_notes)
}

pub fn analyze_remote_conflicts(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
    progress: SftpConflictProgressCallback,
) -> Result<SftpConflictReport> {
    let account = active_account(settings, Some(account_id))?;
    if account.mods_path.trim().is_empty() {
        bail!("尚未定位远端 PAK 模组目录");
    }
    let cache_dir = paths
        .root
        .join("cache")
        .join("sftp_conflicts")
        .join(safe_file_component(account_id));
    std::fs::create_dir_all(&cache_dir)
        .with_context(|| format!("无法创建冲突分析缓存 {}", cache_dir.display()))?;
    send_conflict_progress(
        &progress,
        "preparing",
        0,
        0,
        0,
        0,
        None,
        "正在读取远端 PAK 列表",
    );
    match analyze_remote_conflicts_inner(paths, account, &cache_dir, &progress) {
        Ok(report) => {
            send_conflict_progress(
                &progress,
                "completed",
                report.analyzed_mods,
                report.analyzed_mods + report.skipped_mods,
                0,
                0,
                None,
                &report.message,
            );
            Ok(report)
        }
        Err(error) => {
            send_conflict_progress(
                &progress,
                "error",
                0,
                0,
                0,
                0,
                None,
                &format!("冲突分析失败：{error:#}"),
            );
            Err(error)
        }
    }
}

fn upload_pak_files(
    paths: &AppPaths,
    account: &SftpAccount,
    local_paths: &[String],
) -> Result<UploadResult> {
    if account.mods_path.trim().is_empty() {
        bail!("尚未设置服务器远端 ~mods 路径");
    }
    let uploaded = with_sftp(paths, account, |sftp| {
        if !remote_dir_exists(sftp, &account.mods_path) {
            bail!("远端 PAK 目录不存在：{}", account.mods_path);
        }
        let mut uploaded = 0;
        for local in local_paths {
            let local = Path::new(local);
            if !local.is_file() {
                continue;
            }
            if !local
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("pak"))
            {
                bail!("仅支持上传 .pak 文件：{}", local.display());
            }
            let name = validate_remote_name(
                &local
                    .file_name()
                    .context("上传文件缺少文件名")?
                    .to_string_lossy(),
            )?;
            let remote = remote_join(&account.mods_path, &name);
            upload_local_file(sftp, local, &remote)?;
            let local_signature = local.with_extension("sig");
            if local_signature.is_file() {
                upload_local_file(
                    sftp,
                    &local_signature,
                    &remote_with_extension(&remote, "sig"),
                )?;
            }
            uploaded += 1;
        }
        Ok(uploaded)
    })?;
    Ok(UploadResult {
        uploaded,
        message: format!("已上传 {uploaded} 个 PAK 到 {}", account.mods_path),
    })
}

fn upload_ue4ss_directories(
    paths: &AppPaths,
    account: &SftpAccount,
    local_paths: &[String],
) -> Result<UploadResult> {
    if account.ue4ss_path.trim().is_empty() {
        bail!("尚未设置服务器远端 UE4SS Mods 路径");
    }
    let uploaded = with_sftp(paths, account, |sftp| {
        if !remote_dir_exists(sftp, &account.ue4ss_path) {
            bail!("远端 UE4SS Mods 目录不存在：{}", account.ue4ss_path);
        }
        let mut uploaded = 0;
        for local in local_paths {
            let local = Path::new(local);
            if !local.is_dir() {
                continue;
            }
            let name = validate_remote_name(
                &local
                    .file_name()
                    .context("上传目录缺少名称")?
                    .to_string_lossy(),
            )?;
            let target = remote_join(&account.ue4ss_path, &name);
            uploaded += upload_remote_tree(sftp, local, &target)?;
        }
        Ok(uploaded)
    })?;
    Ok(UploadResult {
        uploaded,
        message: format!("已上传 {uploaded} 个 UE4SS 文件到 {}", account.ue4ss_path),
    })
}

fn upload_remote_tree(sftp: &Sftp, local_root: &Path, remote_root: &str) -> Result<usize> {
    ensure_remote_dir(sftp, remote_root)?;
    let mut uploaded = 0;
    for entry in WalkDir::new(local_root).follow_links(false) {
        let entry = entry.with_context(|| format!("无法遍历 {}", local_root.display()))?;
        if entry.path() == local_root {
            continue;
        }
        let relative = entry
            .path()
            .strip_prefix(local_root)
            .context("UE4SS 上传路径越界")?;
        if relative
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
        {
            bail!("UE4SS 上传路径包含非法目录");
        }
        let relative = relative.to_string_lossy().replace('\\', "/");
        let remote = remote_join(remote_root, &relative);
        if entry.file_type().is_dir() {
            ensure_remote_dir(sftp, &remote)?;
        } else if entry.file_type().is_file() {
            upload_local_file(sftp, entry.path(), &remote)?;
            uploaded += 1;
        }
        if uploaded > MAX_REMOTE_TREE_ENTRIES {
            bail!("UE4SS 上传文件数量超过 {MAX_REMOTE_TREE_ENTRIES} 个");
        }
    }
    Ok(uploaded)
}

fn upload_local_file(sftp: &Sftp, local: &Path, remote: &str) -> Result<()> {
    let mut source = File::open(local).with_context(|| format!("无法读取 {}", local.display()))?;
    let mut target = sftp
        .create(Path::new(remote))
        .with_context(|| format!("无法创建远端文件 {remote}"))?;
    std::io::copy(&mut source, &mut target)?;
    Ok(())
}

fn ensure_remote_dir(sftp: &Sftp, path: &str) -> Result<()> {
    if remote_dir_exists(sftp, path) {
        return Ok(());
    }
    let parent = remote_parent(path);
    if let Some(parent) = parent {
        if parent != path {
            ensure_remote_dir(sftp, &parent)?;
        }
    }
    sftp.mkdir(Path::new(path), 0o755)
        .with_context(|| format!("无法创建远端目录 {path}"))
}

fn remove_remote_tree(sftp: &Sftp, path: &str, depth: usize, visited: &mut usize) -> Result<()> {
    if depth > 64 {
        bail!("远端目录层级过深，已停止删除");
    }
    *visited += 1;
    if *visited > MAX_REMOTE_TREE_ENTRIES {
        bail!("远端目录条目过多，已停止删除");
    }
    let stat = sftp
        .lstat(Path::new(path))
        .with_context(|| format!("无法读取远端路径 {path}"))?;
    if stat.file_type().is_symlink() || !stat.is_dir() {
        return sftp
            .unlink(Path::new(path))
            .with_context(|| format!("无法删除远端文件 {path}"));
    }
    let entries = sftp
        .readdir(Path::new(path))
        .with_context(|| format!("无法读取远端目录 {path}"))?;
    for (entry_path, _) in entries {
        let name = entry_name(&entry_path.to_string_lossy());
        if name == "." || name == ".." {
            continue;
        }
        let child = normalize_remote_path(&entry_path.to_string_lossy());
        if child != path {
            remove_remote_tree(sftp, &child, depth + 1, visited)?;
        }
    }
    sftp.rmdir(Path::new(path))
        .with_context(|| format!("无法删除远端目录 {path}"))
}

fn with_sftp<T>(
    paths: &AppPaths,
    account: &SftpAccount,
    operation: impl FnOnce(&Sftp) -> Result<T>,
) -> Result<T> {
    let password = crate::secrets::read_secret(&paths.sftp_secret(&account.id))
        .with_context(|| format!("账户 {} 尚未安全保存密码", account.name))?;
    let session = handshake_session(account)?;
    let fingerprint = host_key_fingerprint(&session)?;
    let expected = expected_fingerprint(paths, account)?
        .context("尚未信任该服务器的主机密钥，请先在服务器页测试连接并确认指纹")?;
    if expected != fingerprint {
        bail!("服务器主机密钥已变化，已拒绝连接。已信任指纹：{expected}；当前指纹：{fingerprint}");
    }
    authenticate_session_with_password(&session, account, &password)?;
    let sftp = session.sftp().context("无法建立 SFTP 通道")?;
    operation(&sftp)
}

fn handshake_session(account: &SftpAccount) -> Result<Session> {
    let addresses = format!("{}:{}", account.host.trim(), account.port)
        .to_socket_addrs()
        .context("服务器地址无法解析")?;
    let mut last_error = None;
    let mut tcp = None;
    for address in addresses {
        match TcpStream::connect_timeout(&address, Duration::from_secs(12)) {
            Ok(stream) => {
                tcp = Some(stream);
                break;
            }
            Err(error) => last_error = Some(error),
        }
    }
    let tcp = tcp.ok_or_else(|| {
        anyhow::anyhow!(
            "无法连接 SFTP 服务器：{}",
            last_error
                .map(|error| error.to_string())
                .unwrap_or_else(|| "未知网络错误".to_string())
        )
    })?;
    tcp.set_read_timeout(Some(Duration::from_secs(25)))?;
    tcp.set_write_timeout(Some(Duration::from_secs(25)))?;

    let mut session = Session::new().context("无法初始化 SSH 会话")?;
    session.set_tcp_stream(tcp);
    session.set_timeout(25_000);
    session.handshake().context("SSH 握手失败")?;
    Ok(session)
}

fn authenticate_session(paths: &AppPaths, session: &Session, account: &SftpAccount) -> Result<()> {
    let password = crate::secrets::read_secret(&paths.sftp_secret(&account.id))
        .with_context(|| format!("账户 {} 尚未安全保存密码", account.name))?;
    authenticate_session_with_password(session, account, &password)
}

fn authenticate_session_with_password(
    session: &Session,
    account: &SftpAccount,
    password: &str,
) -> Result<()> {
    session
        .userauth_password(account.username.trim(), password)
        .context("SFTP 用户名或密码错误")?;
    if !session.authenticated() {
        bail!("SFTP 身份验证失败");
    }
    Ok(())
}

fn host_key_fingerprint(session: &Session) -> Result<String> {
    let (key, _) = session.host_key().context("SSH 服务器未提供主机密钥")?;
    let digest = Sha256::digest(key);
    Ok(format!(
        "SHA256:{}",
        base64::engine::general_purpose::STANDARD_NO_PAD.encode(digest)
    ))
}

fn known_host_key(account: &SftpAccount) -> String {
    format!(
        "{}:{}",
        account.host.trim().to_ascii_lowercase(),
        account.port
    )
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct KnownHostsFile {
    #[serde(default)]
    hosts: BTreeMap<String, String>,
}

fn expected_fingerprint(paths: &AppPaths, account: &SftpAccount) -> Result<Option<String>> {
    Ok(load_known_hosts(paths)?
        .hosts
        .get(&known_host_key(account))
        .cloned())
}

fn load_known_hosts(paths: &AppPaths) -> Result<KnownHostsFile> {
    if !paths.sftp_known_hosts.exists() {
        return Ok(KnownHostsFile::default());
    }
    let raw = std::fs::read_to_string(&paths.sftp_known_hosts)
        .with_context(|| format!("无法读取 {}", paths.sftp_known_hosts.display()))?;
    serde_json::from_str(&raw).context("SFTP 主机密钥信任文件格式无效")
}

fn save_known_hosts(paths: &AppPaths, known_hosts: &KnownHostsFile) -> Result<()> {
    if let Some(parent) = paths.sftp_known_hosts.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(known_hosts)?;
    std::fs::write(&paths.sftp_known_hosts, format!("{json}\n"))
        .with_context(|| format!("无法写入 {}", paths.sftp_known_hosts.display()))?;
    Ok(())
}

#[derive(Debug, Default)]
struct DetectedServerPaths {
    pak_mods_path: Option<String>,
    ue4ss_mods_path: Option<String>,
    scanned_directories: usize,
}

fn detect_server_paths(sftp: &Sftp, account: &SftpAccount) -> DetectedServerPaths {
    let mut detected = DetectedServerPaths {
        pak_mods_path: valid_remote_dir(sftp, &account.mods_path),
        ue4ss_mods_path: valid_remote_dir(sftp, &account.ue4ss_path),
        scanned_directories: 0,
    };

    for root in candidate_game_roots(account) {
        if detected.pak_mods_path.is_none() {
            detected.pak_mods_path = pak_path_candidates(&root)
                .into_iter()
                .find(|candidate| remote_dir_exists(sftp, candidate));
        }
        if detected.ue4ss_mods_path.is_none() {
            detected.ue4ss_mods_path = ue4ss_path_candidates(&root)
                .into_iter()
                .find(|candidate| remote_dir_exists(sftp, candidate));
        }
        if detected.pak_mods_path.is_some() && detected.ue4ss_mods_path.is_some() {
            break;
        }
    }

    if detected.pak_mods_path.is_none() || detected.ue4ss_mods_path.is_none() {
        let discovered = discover_server_paths(
            sftp,
            account,
            detected.pak_mods_path.is_none(),
            detected.ue4ss_mods_path.is_none(),
        );
        detected.scanned_directories = discovered.scanned_directories;
        if detected.pak_mods_path.is_none() {
            detected.pak_mods_path = discovered.pak_mods_path;
        }
        if detected.ue4ss_mods_path.is_none() {
            detected.ue4ss_mods_path = discovered.ue4ss_mods_path;
        }
    }

    detected
}

fn discover_server_paths(
    sftp: &Sftp,
    account: &SftpAccount,
    find_pak: bool,
    find_ue4ss: bool,
) -> DetectedServerPaths {
    let mut detected = DetectedServerPaths::default();
    let mut queue = VecDeque::new();
    for root in discovery_roots(account) {
        queue.push_back((root, 0usize));
    }
    let mut visited = HashSet::new();

    while let Some((directory, depth)) = queue.pop_front() {
        if detected.scanned_directories >= MAX_REMOTE_SCAN_DIRECTORIES
            || (!find_pak || detected.pak_mods_path.is_some())
                && (!find_ue4ss || detected.ue4ss_mods_path.is_some())
        {
            break;
        }
        let directory = normalize_remote_path(&directory);
        if depth > MAX_REMOTE_SCAN_DEPTH || !visited.insert(directory.clone()) {
            continue;
        }
        let Ok(entries) = sftp.readdir(Path::new(&directory)) else {
            continue;
        };
        detected.scanned_directories += 1;

        for (entry_path, stat) in entries
            .into_iter()
            .take(MAX_REMOTE_SCAN_ENTRIES_PER_DIRECTORY)
        {
            if !stat.is_dir() {
                continue;
            }
            let path = normalize_remote_path(&entry_path.to_string_lossy());
            let name = entry_name(&path);
            let lower = name.to_ascii_lowercase();
            let parent = entry_name(
                Path::new(&path)
                    .parent()
                    .map(|value| value.to_string_lossy())
                    .as_deref()
                    .unwrap_or_default(),
            );
            let parent_lower = parent.to_ascii_lowercase();

            if find_pak
                && detected.pak_mods_path.is_none()
                && lower == "~mods"
                && parent_lower == "paks"
            {
                detected.pak_mods_path = Some(path.clone());
            }
            if find_ue4ss && detected.ue4ss_mods_path.is_none() {
                if lower == "mods" && parent_lower == "ue4ss" {
                    detected.ue4ss_mods_path = Some(path.clone());
                } else if lower == "ue4ss" {
                    let mods_path = remote_join(&path, "Mods");
                    if remote_dir_exists(sftp, &mods_path) {
                        detected.ue4ss_mods_path = Some(mods_path);
                    }
                }
            }
            if should_skip_remote_scan_dir(&lower) {
                continue;
            }
            queue.push_back((path, depth + 1));
        }
    }

    detected
}

fn candidate_game_roots(account: &SftpAccount) -> Vec<String> {
    let user = account.username.trim();
    let mut roots = vec![
        "/".to_string(),
        "/srv/scum/SCUM".to_string(),
        "/srv/scum".to_string(),
        "/srv/SCUM".to_string(),
        "/opt/scum/SCUM".to_string(),
        "/opt/scum".to_string(),
        "/scum/SCUM".to_string(),
        "/scum".to_string(),
        "/SCUM".to_string(),
        format!("/home/{user}/scum/SCUM"),
        format!("/home/{user}/scum"),
        format!("/home/{user}/SCUM"),
        format!("/home/{user}/.steam/steam/steamapps/common/SCUM"),
        format!("/home/{user}/Steam/steamapps/common/SCUM"),
    ];
    if let Some(root) = root_from_pak_path(&account.mods_path) {
        roots.push(root);
    }
    if let Some(root) = root_from_ue4ss_path(&account.ue4ss_path) {
        roots.push(root);
    }
    let mut seen = HashSet::new();
    roots
        .into_iter()
        .map(|root| normalize_remote_path(&root))
        .filter(|root| !root.is_empty() && seen.insert(root.to_ascii_lowercase()))
        .collect()
}

fn discovery_roots(account: &SftpAccount) -> Vec<String> {
    let user = account.username.trim();
    let mut roots = vec![
        "/srv".to_string(),
        "/opt".to_string(),
        "/mnt".to_string(),
        "/var/lib".to_string(),
        "/games".to_string(),
        "/scum".to_string(),
        "/SCUM".to_string(),
        format!("/home/{user}"),
    ];
    if let Some(root) = root_from_pak_path(&account.mods_path) {
        roots.insert(0, root);
    }
    if let Some(root) = root_from_ue4ss_path(&account.ue4ss_path) {
        roots.insert(0, root);
    }
    let mut seen = HashSet::new();
    roots
        .into_iter()
        .map(|root| normalize_remote_path(&root))
        .filter(|root| !root.is_empty() && seen.insert(root.to_ascii_lowercase()))
        .collect()
}

fn pak_path_candidates(root: &str) -> Vec<String> {
    let root = normalize_remote_path(root);
    vec![
        remote_join(&root, "Content/Paks/~mods"),
        remote_join(&root, "SCUM/Content/Paks/~mods"),
    ]
}

fn ue4ss_path_candidates(root: &str) -> Vec<String> {
    let root = normalize_remote_path(root);
    let nested_root = remote_join(&root, "SCUM");
    let mut candidates = Vec::new();
    for game_root in [root.as_str(), nested_root.as_str()] {
        for platform in ["Win64", "Linux"] {
            let binaries = remote_join(game_root, &format!("Binaries/{platform}"));
            for folder in ["ue4ss", "UE4SS"] {
                candidates.push(remote_join(&binaries, &format!("{folder}/Mods")));
            }
            candidates.push(remote_join(&binaries, "Mods"));
        }
    }
    candidates
}

fn root_from_pak_path(path: &str) -> Option<String> {
    let lower = path.trim().to_ascii_lowercase();
    let marker = "/content/paks/~mods";
    lower
        .find(marker)
        .map(|index| normalize_remote_path(&path.trim()[..index]))
        .filter(|root| !root.is_empty())
}

fn root_from_ue4ss_path(path: &str) -> Option<String> {
    let lower = path.trim().to_ascii_lowercase();
    let marker = "/binaries/";
    lower
        .find(marker)
        .map(|index| normalize_remote_path(&path.trim()[..index]))
        .filter(|root| !root.is_empty())
}

fn valid_remote_dir(sftp: &Sftp, path: &str) -> Option<String> {
    let path = path.trim();
    if path.is_empty() {
        return None;
    }
    remote_dir_exists(sftp, path).then(|| normalize_remote_path(path))
}

fn remote_dir_exists(sftp: &Sftp, path: &str) -> bool {
    sftp.stat(Path::new(path))
        .map(|stat| stat.is_dir())
        .unwrap_or(false)
}

fn should_skip_remote_scan_dir(name: &str) -> bool {
    matches!(
        name,
        "proc" | "sys" | "dev" | "run" | "tmp" | "node_modules" | ".git" | ".cache" | "lost+found"
    )
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RemoteNotesFile {
    #[serde(default)]
    accounts: BTreeMap<String, BTreeMap<String, String>>,
}

fn load_remote_notes(paths: &AppPaths) -> Result<RemoteNotesFile> {
    if !paths.sftp_remote_notes.exists() {
        return Ok(RemoteNotesFile::default());
    }
    let raw = std::fs::read_to_string(&paths.sftp_remote_notes)
        .with_context(|| format!("无法读取 {}", paths.sftp_remote_notes.display()))?;
    serde_json::from_str(&raw).context("SFTP 远端备注文件格式无效")
}

fn save_remote_notes(paths: &AppPaths, notes: &RemoteNotesFile) -> Result<()> {
    if let Some(parent) = paths.sftp_remote_notes.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(notes)?;
    std::fs::write(&paths.sftp_remote_notes, format!("{json}\n"))
        .with_context(|| format!("无法写入 {}", paths.sftp_remote_notes.display()))
}

fn move_remote_notes(paths: &AppPaths, account_id: &str, source: &str, target: &str) -> Result<()> {
    let mut file = load_remote_notes(paths)?;
    let Some(notes) = file.accounts.get_mut(account_id) else {
        return Ok(());
    };
    let mut changed = false;
    let moves = notes
        .iter()
        .filter(|(path, _)| {
            path.as_str() == source
                || path
                    .strip_prefix(source)
                    .is_some_and(|suffix| suffix.starts_with('/'))
        })
        .map(|(path, note)| (path.clone(), note.clone()))
        .collect::<Vec<_>>();
    for (old_path, note) in moves {
        notes.remove(&old_path);
        let suffix = old_path.strip_prefix(source).unwrap_or_default();
        notes.insert(format!("{target}{suffix}"), note);
        changed = true;
    }
    if changed {
        save_remote_notes(paths, &file)?;
    }
    Ok(())
}

fn remove_remote_notes_under(paths: &AppPaths, account_id: &str, remote_path: &str) -> Result<()> {
    let mut file = load_remote_notes(paths)?;
    let Some(notes) = file.accounts.get_mut(account_id) else {
        return Ok(());
    };
    let before = notes.len();
    notes.retain(|path, _| {
        path != remote_path
            && !path
                .strip_prefix(remote_path)
                .is_some_and(|suffix| suffix.starts_with('/'))
    });
    if notes.len() != before {
        save_remote_notes(paths, &file)?;
    }
    Ok(())
}

#[derive(Clone)]
struct ConflictDownloadTask {
    file: RemoteFile,
    local: PathBuf,
    cache_name: String,
}

fn analyze_remote_conflicts_inner(
    paths: &AppPaths,
    account: &SftpAccount,
    cache_dir: &Path,
    progress: &SftpConflictProgressCallback,
) -> Result<SftpConflictReport> {
    let pak_files = with_sftp(paths, account, |sftp| {
        Ok(list_pak_mods(sftp, &account.mods_path))
    })?;
    let mut accepted = Vec::new();
    let mut skipped_mods = 0usize;
    let mut total_bytes = 0u64;
    for file in pak_files {
        if accepted.len() >= MAX_REMOTE_CONFLICT_MODS
            || total_bytes.saturating_add(file.size) > MAX_REMOTE_CONFLICT_BYTES
        {
            skipped_mods += 1;
            continue;
        }
        total_bytes = total_bytes.saturating_add(file.size);
        accepted.push(file);
    }
    let total_files = accepted.len();

    let mut downloaded = Vec::new();
    let mut preparsed = Vec::new();
    let mut pending = Vec::new();
    let mut keep_names = HashSet::new();
    let mut cached_bytes = 0u64;
    for file in accepted {
        let cache_name = conflict_cache_name(&file);
        let entries_name = conflict_entries_cache_name(&cache_name);
        let local = cache_dir.join(&cache_name);
        let entries_local = cache_dir.join(&entries_name);
        keep_names.insert(cache_name.clone());
        keep_names.insert(entries_name);
        let cached = std::fs::metadata(&local)
            .map(|metadata| metadata.len() == file.size)
            .unwrap_or(false);
        if cached {
            cached_bytes = cached_bytes.saturating_add(file.size);
            if let Some(entries) = read_conflict_entries_cache(&entries_local) {
                preparsed.push((file, entries));
            } else {
                downloaded.push((file, local));
            }
        } else {
            pending.push(ConflictDownloadTask {
                file,
                local,
                cache_name,
            });
        }
    }
    send_conflict_progress(
        progress,
        "downloading",
        downloaded.len() + preparsed.len(),
        total_files,
        cached_bytes,
        total_bytes,
        None,
        if downloaded.is_empty() && preparsed.is_empty() {
            format!("准备并行下载 {total_files} 个远端 PAK")
        } else {
            format!(
                "已命中 {} 个缓存（{} 个解析结果可直接复用），准备下载 {} 个远端 PAK",
                downloaded.len() + preparsed.len(),
                preparsed.len(),
                pending.len()
            )
        }
        .as_str(),
    );

    let downloaded = Arc::new(Mutex::new(downloaded));
    let completed_files = Arc::new(AtomicUsize::new(
        downloaded.lock().unwrap().len() + preparsed.len(),
    ));
    let completed_bytes = Arc::new(AtomicU64::new(cached_bytes));
    if !pending.is_empty() {
        let tasks = Arc::new(pending);
        let next_task = Arc::new(AtomicUsize::new(0));
        let worker_count = CONFLICT_DOWNLOAD_WORKERS.min(tasks.len());
        let last_progress = Arc::new(Mutex::new(Instant::now() - CONFLICT_PROGRESS_INTERVAL));
        std::thread::scope(|scope| -> Result<()> {
            let mut handles = Vec::new();
            for _ in 0..worker_count {
                let tasks = tasks.clone();
                let next_task = next_task.clone();
                let downloaded = downloaded.clone();
                let completed_files = completed_files.clone();
                let completed_bytes = completed_bytes.clone();
                let progress = progress.clone();
                let account = account.clone();
                let last_progress = last_progress.clone();
                handles.push(scope.spawn(move || -> Result<()> {
                    with_sftp(paths, &account, |sftp| {
                        loop {
                            let index = next_task.fetch_add(1, Ordering::Relaxed);
                            if index >= tasks.len() {
                                break;
                            }
                            let task = &tasks[index];
                            send_conflict_progress(
                                &progress,
                                "downloading",
                                completed_files.load(Ordering::Relaxed),
                                total_files,
                                completed_bytes.load(Ordering::Relaxed),
                                total_bytes,
                                Some(task.file.name.clone()),
                                &format!("正在下载 {}", task.file.name),
                            );
                            let partial = task
                                .local
                                .with_file_name(format!("{}.part", task.cache_name));
                            let _ = std::fs::remove_file(&partial);
                            let mut task_bytes = 0u64;
                            let download = (|| -> Result<()> {
                                let mut remote =
                                    sftp.open(Path::new(&task.file.path)).with_context(|| {
                                        format!("无法读取远端 PAK {}", task.file.path)
                                    })?;
                                let mut output = File::create(&partial).with_context(|| {
                                    format!("无法创建冲突分析缓存 {}", partial.display())
                                })?;
                                let mut buffer = vec![0u8; CONFLICT_DOWNLOAD_CHUNK_BYTES];
                                loop {
                                    let read = remote.read(&mut buffer)?;
                                    if read == 0 {
                                        break;
                                    }
                                    output.write_all(&buffer[..read])?;
                                    task_bytes = task_bytes.saturating_add(read as u64);
                                    let bytes = completed_bytes
                                        .fetch_add(read as u64, Ordering::Relaxed)
                                        + read as u64;
                                    let should_emit = {
                                        let mut last = last_progress.lock().unwrap();
                                        if last.elapsed() >= CONFLICT_PROGRESS_INTERVAL {
                                            *last = Instant::now();
                                            true
                                        } else {
                                            false
                                        }
                                    };
                                    if should_emit {
                                        send_conflict_progress(
                                            &progress,
                                            "downloading",
                                            completed_files.load(Ordering::Relaxed),
                                            total_files,
                                            bytes,
                                            total_bytes,
                                            Some(task.file.name.clone()),
                                            &format!("正在下载 {}", task.file.name),
                                        );
                                    }
                                }
                                output.flush()?;
                                std::fs::rename(&partial, &task.local).with_context(|| {
                                    format!("无法提交冲突分析缓存 {}", task.local.display())
                                })?;
                                Ok(())
                            })();
                            if let Err(error) = download {
                                let _ = std::fs::remove_file(&partial);
                                return Err(error);
                            }
                            downloaded
                                .lock()
                                .unwrap()
                                .push((task.file.clone(), task.local.clone()));
                            let finished = completed_files.fetch_add(1, Ordering::Relaxed) + 1;
                            if task_bytes < task.file.size {
                                completed_bytes
                                    .fetch_add(task.file.size - task_bytes, Ordering::Relaxed);
                            }
                            send_conflict_progress(
                                &progress,
                                "downloading",
                                finished,
                                total_files,
                                completed_bytes.load(Ordering::Relaxed),
                                total_bytes,
                                Some(task.file.name.clone()),
                                &format!("已完成 {}", task.file.name),
                            );
                        }
                        Ok(())
                    })
                }));
            }
            for handle in handles {
                handle
                    .join()
                    .map_err(|_| anyhow::anyhow!("远端 PAK 下载线程异常退出"))??;
            }
            Ok(())
        })?;
    }
    let downloaded = Arc::try_unwrap(downloaded)
        .map_err(|_| anyhow::anyhow!("冲突分析缓存仍被占用"))?
        .into_inner()
        .unwrap();

    send_conflict_progress(
        progress,
        "parsing",
        preparsed.len(),
        total_files,
        0,
        total_bytes,
        None,
        if preparsed.is_empty() {
            "开始并行解析 PAK 资源清单"
        } else {
            "已复用部分 PAK 解析缓存，继续解析剩余文件"
        },
    );
    let downloaded = Arc::new(downloaded);
    let parsed = Arc::new(Mutex::new(preparsed));
    let parse_failures = Arc::new(AtomicUsize::new(0));
    let parse_done = Arc::new(AtomicUsize::new(parsed.lock().unwrap().len()));
    if !downloaded.is_empty() {
        let next_parse = Arc::new(AtomicUsize::new(0));
        let worker_count = CONFLICT_PARSE_WORKERS.min(downloaded.len());
        std::thread::scope(|scope| -> Result<()> {
            let mut handles = Vec::new();
            for _ in 0..worker_count {
                let downloaded = downloaded.clone();
                let parsed = parsed.clone();
                let parse_failures = parse_failures.clone();
                let parse_done = parse_done.clone();
                let next_parse = next_parse.clone();
                let progress = progress.clone();
                handles.push(scope.spawn(move || loop {
                    let index = next_parse.fetch_add(1, Ordering::Relaxed);
                    if index >= downloaded.len() {
                        break;
                    }
                    let (file, local) = &downloaded[index];
                    send_conflict_progress(
                        &progress,
                        "parsing",
                        parse_done.load(Ordering::Relaxed),
                        total_files,
                        0,
                        total_bytes,
                        Some(file.name.clone()),
                        &format!("正在解析 {}", file.name),
                    );
                    match crate::mods::list_pak_entries(paths, local) {
                        Ok(entries) => {
                            let entries_name = local
                                .file_name()
                                .map(|name| name.to_string_lossy().into_owned())
                                .unwrap_or_default();
                            let entries_local =
                                local.with_file_name(conflict_entries_cache_name(&entries_name));
                            write_conflict_entries_cache(&entries_local, &entries);
                            parsed.lock().unwrap().push((file.clone(), entries));
                        }
                        Err(_) => {
                            parse_failures.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                    let finished = parse_done.fetch_add(1, Ordering::Relaxed) + 1;
                    send_conflict_progress(
                        &progress,
                        "parsing",
                        finished,
                        total_files,
                        0,
                        total_bytes,
                        Some(file.name.clone()),
                        &format!("已解析 {}", file.name),
                    );
                }));
            }
            for handle in handles {
                handle
                    .join()
                    .map_err(|_| anyhow::anyhow!("PAK 解析线程异常退出"))?;
            }
            Ok(())
        })?;
    }
    skipped_mods += parse_failures.load(Ordering::Relaxed);
    let parsed = Arc::try_unwrap(parsed)
        .map_err(|_| anyhow::anyhow!("PAK 解析结果仍被占用"))?
        .into_inner()
        .unwrap();

    let mut owners: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut display_paths: BTreeMap<String, String> = BTreeMap::new();
    let mut owner_info: BTreeMap<String, SftpConflictOwner> = BTreeMap::new();
    for (file, entries) in &parsed {
        owner_info.insert(
            file.path.clone(),
            SftpConflictOwner {
                name: file.name.clone(),
                path: file.path.clone(),
                kind: "pak".to_string(),
            },
        );
        let mut seen = HashSet::new();
        for raw in entries {
            let Some(resource_path) = crate::mods::normalize_entry_path(raw) else {
                continue;
            };
            let key = resource_path.to_ascii_lowercase();
            if !seen.insert(key.clone()) {
                continue;
            }
            display_paths.entry(key.clone()).or_insert(resource_path);
            owners.entry(key).or_default().insert(file.path.clone());
        }
    }

    let mut groups = owners
        .into_iter()
        .filter(|(_, mod_paths)| mod_paths.len() > 1)
        .map(|(key, mod_paths)| SftpConflictGroup {
            resource_path: display_paths.remove(&key).unwrap_or(key),
            owners: mod_paths
                .into_iter()
                .filter_map(|path| owner_info.get(&path).cloned())
                .collect(),
        })
        .collect::<Vec<_>>();
    groups.sort_by(|left, right| {
        left.resource_path
            .to_ascii_lowercase()
            .cmp(&right.resource_path.to_ascii_lowercase())
            .then_with(|| left.resource_path.cmp(&right.resource_path))
    });
    let analyzed_mods = parsed.len();
    let message = if groups.is_empty() {
        format!(
            "已分析 {analyzed_mods} 个远端 PAK，未发现资源冲突{}",
            if skipped_mods > 0 {
                format!("；跳过 {skipped_mods} 个")
            } else {
                String::new()
            }
        )
    } else {
        format!(
            "已分析 {analyzed_mods} 个远端 PAK，发现 {} 组资源冲突{}",
            groups.len(),
            if skipped_mods > 0 {
                format!("；跳过 {skipped_mods} 个")
            } else {
                String::new()
            }
        )
    };
    prune_conflict_cache(cache_dir, &keep_names);
    Ok(SftpConflictReport {
        groups,
        analyzed_mods,
        skipped_mods,
        message,
    })
}

fn send_conflict_progress(
    progress: &SftpConflictProgressCallback,
    phase: &str,
    completed_files: usize,
    total_files: usize,
    completed_bytes: u64,
    total_bytes: u64,
    current_file: Option<String>,
    message: &str,
) {
    progress(SftpConflictProgress {
        phase: phase.to_string(),
        completed_files,
        total_files,
        completed_bytes,
        total_bytes,
        current_file,
        message: message.to_string(),
    });
}

fn conflict_cache_name(file: &RemoteFile) -> String {
    let mut hasher = Sha256::new();
    hasher.update(file.path.as_bytes());
    hasher.update(b"\0");
    hasher.update(file.size.to_le_bytes());
    hasher.update(b"\0");
    hasher.update(file.modified_at.as_deref().unwrap_or_default().as_bytes());
    format!("{}.pak", &hex::encode(hasher.finalize())[..32])
}

fn conflict_entries_cache_name(cache_name: &str) -> String {
    format!("{cache_name}.entries.json")
}

fn read_conflict_entries_cache(path: &Path) -> Option<Vec<String>> {
    let metadata = std::fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_CONFLICT_ENTRIES_CACHE_BYTES {
        return None;
    }
    let data = std::fs::read(path).ok()?;
    serde_json::from_slice(&data).ok()
}

fn write_conflict_entries_cache(path: &Path, entries: &[String]) {
    let Ok(data) = serde_json::to_vec(entries) else {
        return;
    };
    let partial = path.with_extension("json.part");
    if std::fs::write(&partial, data).is_ok() {
        let _ = std::fs::rename(&partial, path);
    } else {
        let _ = std::fs::remove_file(&partial);
    }
}

fn prune_conflict_cache(cache_dir: &Path, keep_names: &HashSet<String>) {
    let Ok(entries) = std::fs::read_dir(cache_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if keep_names.contains(&name) {
            continue;
        }
        let path = entry.path();
        if path.is_dir() {
            let _ = std::fs::remove_dir_all(path);
        } else {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn ensure_remote_operation_allowed(account: &SftpAccount, path: &str) -> Result<()> {
    if !is_clean_remote_path(path) {
        bail!("远端路径无效");
    }
    let roots = [&account.mods_path, &account.ue4ss_path]
        .into_iter()
        .filter(|root| !root.trim().is_empty())
        .collect::<Vec<_>>();
    if roots.is_empty() {
        bail!("尚未定位远端模组目录");
    }
    if roots.into_iter().any(|root| remote_path_within(root, path)) {
        return Ok(());
    }
    bail!("拒绝操作模组目录之外的远端路径：{path}")
}

fn is_clean_remote_path(path: &str) -> bool {
    let trimmed = path.trim();
    !trimmed.is_empty()
        && !trimmed.contains('\0')
        && !trimmed.contains('\\')
        && trimmed
            .split('/')
            .all(|component| component != ".." && component != ".")
}

fn remote_path_within(root: &str, path: &str) -> bool {
    let root = normalize_remote_path(root);
    let path = normalize_remote_path(path);
    if root == "/" {
        return path.starts_with('/');
    }
    path == root || path.starts_with(&format!("{root}/"))
}

fn validate_remote_name(name: &str) -> Result<String> {
    let name = name.trim();
    if name.is_empty() || name == "." || name == ".." {
        bail!("远端名称无效");
    }
    if name.len() > 255 || name.contains('/') || name.contains('\\') || name.contains('\0') {
        bail!("远端名称不能包含路径分隔符");
    }
    if name.chars().any(char::is_control) {
        bail!("远端名称包含控制字符");
    }
    Ok(name.to_string())
}

fn remote_parent(path: &str) -> Option<String> {
    let parent = Path::new(path).parent()?.to_string_lossy();
    let parent = normalize_remote_path(&parent);
    (!parent.is_empty()).then_some(parent)
}

fn remote_with_extension(path: &str, extension: &str) -> String {
    Path::new(path)
        .with_extension(extension)
        .to_string_lossy()
        .into_owned()
}

fn read_remote_files(sftp: &Sftp, path: &str) -> Vec<RemoteFile> {
    let Ok(entries) = sftp.readdir(Path::new(path)) else {
        return Vec::new();
    };
    let mut files = Vec::new();
    for (entry_path, stat) in entries {
        let name = entry_path
            .file_name()
            .map(|value| value.to_string_lossy().into_owned())
            .unwrap_or_else(|| entry_path.to_string_lossy().into_owned());
        if name == "." || name == ".." {
            continue;
        }
        files.push(RemoteFile {
            name,
            path: remote_join(path, &entry_path.to_string_lossy()),
            is_directory: stat.is_dir(),
            size: stat.size.unwrap_or(0),
            modified_at: stat.mtime.map(|seconds| {
                Utc.timestamp_opt(seconds as i64, 0)
                    .single()
                    .unwrap_or_else(Utc::now)
                    .to_rfc3339()
            }),
        });
    }
    files.sort_by(|left, right| {
        right.is_directory.cmp(&left.is_directory).then_with(|| {
            left.name
                .to_ascii_lowercase()
                .cmp(&right.name.to_ascii_lowercase())
        })
    });
    files
}

fn list_pak_mods(sftp: &Sftp, path: &str) -> Vec<RemoteFile> {
    read_remote_files(sftp, path)
        .into_iter()
        .filter(|file| {
            !file.is_directory
                && Path::new(&file.name)
                    .extension()
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("pak"))
        })
        .collect()
}

fn list_ue4ss_mods(sftp: &Sftp, path: &str) -> Vec<RemoteFile> {
    read_remote_files(sftp, path)
        .into_iter()
        .filter(|file| {
            file.is_directory
                || Path::new(&file.name).extension().is_some_and(|extension| {
                    extension.eq_ignore_ascii_case("dll") || extension.eq_ignore_ascii_case("lua")
                })
        })
        .collect()
}

fn entry_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn normalize_remote_path(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed == "/" {
        return "/".to_string();
    }
    trimmed.trim_end_matches('/').to_string()
}

fn remote_join(parent: &str, child: &str) -> String {
    if child.starts_with('/') {
        child.to_string()
    } else {
        format!(
            "{}/{}",
            parent.trim_end_matches('/'),
            child.trim_start_matches('/')
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{
        active_account, conflict_entries_cache_name, download_file,
        ensure_remote_operation_allowed, load_remote_notes, move_remote_notes, pak_path_candidates,
        read_conflict_entries_cache, remote_join, remove_remote_notes_under, root_from_pak_path,
        root_from_ue4ss_path, save_remote_notes, ue4ss_path_candidates, validate_remote_name,
        write_conflict_entries_cache, RemoteNotesFile,
    };
    use crate::models::{AppSettings, SftpAccount};
    use crate::test_support::TempRoot;

    fn account(id: &str) -> SftpAccount {
        SftpAccount {
            id: id.to_string(),
            name: id.to_string(),
            host: format!("{id}.example.test"),
            port: 22,
            username: "tester".to_string(),
            ..SftpAccount::default()
        }
    }

    #[test]
    fn selects_requested_or_active_or_first_sftp_account() {
        let settings = AppSettings {
            sftp_accounts: vec![account("first"), account("active"), account("requested")],
            active_sftp_account_id: Some("active".to_string()),
            ..AppSettings::default()
        };

        assert_eq!(
            active_account(&settings, Some("requested")).unwrap().id,
            "requested"
        );
        assert_eq!(active_account(&settings, None).unwrap().id, "active");
        let settings = AppSettings {
            active_sftp_account_id: Some("missing".to_string()),
            ..settings
        };
        assert_eq!(active_account(&settings, None).unwrap().id, "first");
        assert!(active_account(&settings, Some("missing")).is_err());
    }

    #[test]
    fn joins_remote_paths_without_dropping_the_parent() {
        assert_eq!(
            remote_join("/srv/scum/~mods/", "Mod.pak"),
            "/srv/scum/~mods/Mod.pak"
        );
        assert_eq!(
            remote_join("/srv/scum/~mods", "/absolute/Mod.pak"),
            "/absolute/Mod.pak"
        );
    }

    #[test]
    fn builds_server_mod_path_candidates_for_linux_and_windows_layouts() {
        let root = "/srv/scum/SCUM";
        assert_eq!(
            pak_path_candidates(root),
            vec![
                "/srv/scum/SCUM/Content/Paks/~mods",
                "/srv/scum/SCUM/SCUM/Content/Paks/~mods",
            ]
        );
        let ue4ss = ue4ss_path_candidates(root);
        assert!(ue4ss.contains(&"/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods".to_string()));
        assert!(ue4ss.contains(&"/srv/scum/SCUM/Binaries/Linux/UE4SS/Mods".to_string()));
        assert_eq!(
            pak_path_candidates("/"),
            vec!["/Content/Paks/~mods", "/SCUM/Content/Paks/~mods"]
        );
    }

    #[test]
    fn derives_game_root_from_configured_mod_paths() {
        assert_eq!(
            root_from_pak_path("/srv/scum/SCUM/Content/Paks/~mods"),
            Some("/srv/scum/SCUM".to_string())
        );
        assert_eq!(
            root_from_ue4ss_path("/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods"),
            Some("/srv/scum/SCUM".to_string())
        );
        assert_eq!(root_from_pak_path(""), None);
    }

    #[test]
    fn limits_remote_mutations_to_configured_mod_roots() {
        let mut account = account("server");
        account.mods_path = "/srv/scum/SCUM/Content/Paks/~mods".to_string();
        account.ue4ss_path = "/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods".to_string();

        assert!(ensure_remote_operation_allowed(
            &account,
            "/srv/scum/SCUM/Content/Paks/~mods/Test.pak"
        )
        .is_ok());
        assert!(ensure_remote_operation_allowed(
            &account,
            "/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods/TestMod/main.lua"
        )
        .is_ok());
        assert!(ensure_remote_operation_allowed(
            &account,
            "/srv/scum/SCUM/Config/ServerSettings.ini"
        )
        .is_err());
        assert!(ensure_remote_operation_allowed(
            &account,
            "/srv/scum/SCUM/Content/Paks/~mods/../x"
        )
        .is_err());
    }

    #[test]
    fn validates_remote_entry_names() {
        assert_eq!(validate_remote_name("NewMod.pak").unwrap(), "NewMod.pak");
        assert!(validate_remote_name("../escape.pak").is_err());
        assert!(validate_remote_name("bad/name.pak").is_err());
        assert!(validate_remote_name("bad\\name.pak").is_err());
        assert!(validate_remote_name("   ").is_err());
    }

    #[test]
    fn validates_download_paths_before_opening_a_connection() {
        let temp = TempRoot::new("sftp-download-validation");
        let paths = temp.paths();
        let settings = AppSettings {
            sftp_accounts: vec![account("server")],
            ..AppSettings::default()
        };
        assert!(
            download_file(&paths, &settings, "server", "../escape.pak", "download.pak").is_err()
        );
        assert!(download_file(
            &paths,
            &settings,
            "server",
            "/srv/scum/SCUM/Content/Paks/~mods/Test.pak",
            ""
        )
        .is_err());
    }

    #[test]
    fn round_trips_conflict_entry_cache() {
        let temp = TempRoot::new("sftp-conflict-entry-cache");
        let cache_name = conflict_entries_cache_name("abc.pak");
        let path = temp.path().join(&cache_name);
        let entries = vec![
            "SCUM/Content/Items/One".to_string(),
            "SCUM/Content/Items/Two".to_string(),
        ];
        write_conflict_entries_cache(&path, &entries);
        assert_eq!(read_conflict_entries_cache(&path).unwrap(), entries);
    }

    #[test]
    fn moves_and_removes_remote_notes_with_the_mod_entry() {
        let temp = TempRoot::new("sftp-remote-notes");
        let paths = temp.paths();
        let source = "/srv/scum/SCUM/Content/Paks/~mods/Old.pak";
        let target = "/srv/scum/SCUM/Content/Paks/~mods/New.pak";
        let mut file = RemoteNotesFile::default();
        file.accounts
            .entry("server".to_string())
            .or_default()
            .insert(source.to_string(), "keep this note".to_string());
        save_remote_notes(&paths, &file).unwrap();

        move_remote_notes(&paths, "server", source, target).unwrap();
        let moved = load_remote_notes(&paths).unwrap();
        assert_eq!(
            moved.accounts["server"][target],
            "keep this note".to_string()
        );
        assert!(!moved.accounts["server"].contains_key(source));

        remove_remote_notes_under(&paths, "server", target).unwrap();
        assert!(load_remote_notes(&paths).unwrap().accounts["server"].is_empty());
    }
}
