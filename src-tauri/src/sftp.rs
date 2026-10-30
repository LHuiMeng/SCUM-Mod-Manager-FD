use crate::metadata::MetadataFile;
use crate::models::{
    AppSettings, ModEntry, RemoteFile, SftpAccount, SftpApplyResult, SftpConflictGroup,
    SftpConflictOwner, SftpConflictProgress, SftpConflictReport, SftpConnectionResult,
    SftpManagedBackup, SftpManagedManifest, SftpManagedRename, SftpManagedSource,
    SftpOperationResult, UploadResult,
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
const REMOTE_MERGED_FILE: &str = "999_SCUM_Mod_Desk_Merged.pak";
const REMOTE_MERGED_MANIFEST: &str = "999_SCUM_Mod_Desk_Merged.sources.json";
const REMOTE_BACKUP_DIRECTORY: &str = "_SCUM_Mod_Desk_Backups";
const MAX_REMOTE_MANIFEST_BYTES: u64 = 4 * 1024 * 1024;
const MAX_REMOTE_UE4SS_CONFIG_BYTES: u64 = 1024 * 1024;

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
                managed_manifest: None,
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
    let managed_manifest = detected.pak_mods_path.as_deref().and_then(|path| {
        let ue4ss_path = detected
            .ue4ss_mods_path
            .as_deref()
            .unwrap_or(&account.ue4ss_path);
        read_managed_manifest(&sftp, path, ue4ss_path)
            .ok()
            .flatten()
    });
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
        managed_manifest,
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
        managed_manifest: None,
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
    if normalize_remote_path(&account.mods_path) == "/" {
        bail!("无法在服务器根目录分析模组冲突，请先定位具体的 ~mods 目录");
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

struct RemoteUe4ssConfigPlan {
    path: String,
    existing_file: Option<RemoteFile>,
    desired: String,
}

fn plan_remote_ue4ss_config(
    paths: &AppPaths,
    account: &SftpAccount,
    order: &[String],
    disabled: &HashSet<String>,
) -> Result<Option<RemoteUe4ssConfigPlan>> {
    if account.ue4ss_path.trim().is_empty() {
        return Ok(None);
    }
    with_sftp(paths, account, |sftp| {
        let files = list_ue4ss_mods(sftp, &account.ue4ss_path);
        if !files.iter().any(|file| file.is_directory) {
            return Ok(None);
        }
        let path = remote_join(&account.ue4ss_path, "mods.txt");
        let existing = read_remote_text_file(sftp, &path, MAX_REMOTE_UE4SS_CONFIG_BYTES)?;
        let existing_content = existing
            .as_ref()
            .map(|(_, content)| content.as_str())
            .unwrap_or_default();
        let built = build_remote_ue4ss_mods_txt(&files, order, disabled, existing_content);
        let desired = if built.trim().is_empty() {
            String::new()
        } else {
            format!("{}\n", built.trim_end_matches(['\r', '\n']))
        };
        if existing_content.trim_end_matches(['\r', '\n']) == desired.trim_end_matches(['\r', '\n'])
        {
            return Ok(None);
        }
        Ok(Some(RemoteUe4ssConfigPlan {
            path,
            existing_file: existing.map(|(file, _)| file),
            desired,
        }))
    })
}

pub fn apply_remote_layout(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
    order: &[String],
    disabled: &[String],
    winners: &BTreeMap<String, String>,
    progress: SftpConflictProgressCallback,
) -> Result<SftpApplyResult> {
    let account = active_account(settings, Some(account_id))?;
    if account.mods_path.trim().is_empty() {
        bail!("尚未定位远端 PAK 模组目录");
    }
    if normalize_remote_path(&account.mods_path) == "/" {
        bail!("拒绝在服务器根目录应用模组布局，请先定位具体的 ~mods 目录");
    }
    send_conflict_progress(
        &progress,
        "preparing",
        0,
        0,
        0,
        0,
        None,
        "正在检查服务器现有托管状态",
    );
    if let Some(existing) = with_sftp(paths, account, |sftp| {
        read_managed_manifest(sftp, &account.mods_path, &account.ue4ss_path)
    })? {
        with_sftp(paths, account, |sftp| {
            restore_managed_manifest(sftp, &account.mods_path, &existing)
        })?;
    }

    let cache_dir = paths
        .root
        .join("cache")
        .join("sftp_conflicts")
        .join(safe_file_component(account_id));
    std::fs::create_dir_all(&cache_dir)
        .with_context(|| format!("无法创建冲突分析缓存 {}", cache_dir.display()))?;
    // The conflict scan fills the local cache and verifies every PAK before any
    // server mutation. Existing managed backups were restored above.
    analyze_remote_conflicts_inner(paths, account, &cache_dir, &progress)?;

    let pak_files = with_sftp(paths, account, |sftp| {
        Ok(list_pak_mods(sftp, &account.mods_path))
    })?;
    let order_index = order
        .iter()
        .enumerate()
        .map(|(index, path)| (path.clone(), index))
        .collect::<BTreeMap<_, _>>();
    let disabled = disabled.iter().cloned().collect::<HashSet<_>>();
    let mut sorted_paks = pak_files;
    sorted_paks.sort_by(|left, right| {
        order_index
            .get(&left.path)
            .copied()
            .unwrap_or(usize::MAX)
            .cmp(&order_index.get(&right.path).copied().unwrap_or(usize::MAX))
            .then_with(|| {
                left.name
                    .to_ascii_lowercase()
                    .cmp(&right.name.to_ascii_lowercase())
            })
            .then_with(|| left.path.cmp(&right.path))
    });

    let mut metadata = MetadataFile::default();
    let mut mods = Vec::new();
    let mut files_by_path = BTreeMap::new();
    for (load_order, file) in sorted_paks.iter().enumerate() {
        files_by_path.insert(file.path.clone(), file.clone());
        if disabled.contains(&file.path) || is_managed_merged_name(&file.name) {
            continue;
        }
        let cache_name = conflict_cache_name(file);
        let local = cache_dir.join(&cache_name);
        if !local.is_file() {
            bail!("远端 PAK 尚未完成缓存，无法应用布局：{}", file.name);
        }
        let entries_path = cache_dir.join(conflict_entries_cache_name(&cache_name));
        let entries = match read_conflict_entries_cache(&entries_path) {
            Some(entries) => entries,
            None => crate::mods::list_pak_entries(paths, &local)?,
        };
        metadata.entry_mut(&file.path).pak_entries = entries;
        mods.push(ModEntry {
            id: file.path.clone(),
            name: file.name.clone(),
            file_name: file.name.clone(),
            file_path: local.to_string_lossy().into_owned(),
            file_size: file.size,
            last_modified: file.modified_at.clone().unwrap_or_default(),
            enabled: true,
            mod_type: "clientPak".to_string(),
            load_order,
            description: String::new(),
            origin_source: "local".to_string(),
            ..ModEntry::default()
        });
    }

    let mut valid_winners = BTreeMap::new();
    let mut analysis = crate::mods::analyze_conflicts(&metadata, &mods);
    for (key, winner) in winners {
        if analysis
            .groups
            .iter()
            .any(|group| group.key == *key && group.owners.iter().any(|owner| owner.id == *winner))
        {
            valid_winners.insert(key.clone(), winner.clone());
        }
    }
    metadata.conflict_winners = valid_winners.clone();
    analysis = crate::mods::analyze_conflicts(&metadata, &mods);
    crate::mods::validate_conflict_winners(&analysis.groups, &valid_winners)?;

    let conflicting_paths = analysis
        .groups
        .iter()
        .flat_map(|group| group.owners.iter().map(|owner| owner.id.clone()))
        .collect::<BTreeSet<_>>();
    let mut to_backup = BTreeMap::<String, String>::new();
    for path in &disabled {
        if files_by_path.contains_key(path) {
            to_backup.insert(path.clone(), "disabled".to_string());
        }
    }
    for path in &conflicting_paths {
        if files_by_path.contains_key(path) {
            to_backup.insert(path.clone(), "merged".to_string());
        }
    }
    if let Some(previous) = files_by_path
        .values()
        .find(|file| is_managed_merged_name(&file.name))
    {
        to_backup
            .entry(previous.path.clone())
            .or_insert_with(|| "previous-merged".to_string());
    }
    let prefix_width = remote_deployment_prefix_width(sorted_paks.len());
    let merged_remote_name = if prefix_width == 3 {
        REMOTE_MERGED_FILE.to_string()
    } else {
        format!("{}_SCUM_Mod_Desk_Merged.pak", "9".repeat(prefix_width))
    };
    let rename_candidates = plan_remote_pak_renames(
        &sorted_paks,
        &disabled,
        &conflicting_paths,
        &account.mods_path,
        prefix_width,
    );
    let ue4ss_plan = plan_remote_ue4ss_config(paths, account, order, &disabled)?;
    let ue4ss_changed = ue4ss_plan.is_some();
    if to_backup.is_empty()
        && conflicting_paths.is_empty()
        && rename_candidates.is_empty()
        && !ue4ss_changed
    {
        let message = "服务器模组没有冲突、启停或排序变化，无需应用变更".to_string();
        send_conflict_progress(&progress, "completed", 1, 1, 0, 0, None, &message);
        return Ok(SftpApplyResult {
            message,
            manifest: SftpManagedManifest::default(),
        });
    }

    let stage_root = paths
        .root
        .join("~remote-merge")
        .join(Uuid::new_v4().to_string());
    std::fs::create_dir_all(&stage_root)?;
    let merged_local = stage_root.join(REMOTE_MERGED_FILE);
    let build_merged = (|| -> Result<bool> {
        if conflicting_paths.is_empty() {
            return Ok(false);
        }
        build_remote_merged_pak(paths, &mods, &analysis, &metadata, &merged_local)
    })();
    let merged_created = match build_merged {
        Ok(value) => value,
        Err(error) => {
            let _ = std::fs::remove_dir_all(&stage_root);
            return Err(error);
        }
    };
    if !conflicting_paths.is_empty() && !merged_created {
        let _ = std::fs::remove_dir_all(&stage_root);
        bail!("冲突分析完成，但未能生成合并 PAK");
    }

    let created_at = Utc::now().to_rfc3339();
    let sources = conflicting_paths
        .iter()
        .filter_map(|path| {
            files_by_path.get(path).map(|file| SftpManagedSource {
                name: file.name.clone(),
                path: path.clone(),
            })
        })
        .collect::<Vec<_>>();
    let backup_files = to_backup
        .keys()
        .filter_map(|path| files_by_path.get(path).cloned())
        .collect::<Vec<_>>();
    let manifest = with_sftp(paths, account, |sftp| {
        let mut planned_renames = Vec::new();
        for (file, target_path) in &rename_candidates {
            if sftp.lstat(Path::new(target_path)).is_ok() {
                bail!("服务器排序目标已存在，拒绝覆盖：{target_path}");
            }
            let source_signature = remote_with_extension(&file.path, "sig");
            let target_signature = remote_with_extension(target_path, "sig");
            let has_signature = sftp
                .lstat(Path::new(&source_signature))
                .map(|stat| !stat.is_dir())
                .unwrap_or(false);
            if has_signature && sftp.lstat(Path::new(&target_signature)).is_ok() {
                bail!("服务器排序签名目标已存在，拒绝覆盖：{target_signature}");
            }
            planned_renames.push((
                file.clone(),
                target_path.clone(),
                source_signature,
                target_signature,
                has_signature,
            ));
        }
        let backup_name = format!(
            "{REMOTE_BACKUP_DIRECTORY}/{}",
            Utc::now().format("%Y%m%d-%H%M%S-%3f")
        );
        let backup_dir = remote_join(&account.mods_path, &backup_name);
        let ue4ss_backup_dir = remote_join(&account.ue4ss_path, &backup_name);
        if !backup_files.is_empty() {
            ensure_remote_dir(sftp, &backup_dir)?;
        }
        if ue4ss_plan
            .as_ref()
            .is_some_and(|plan| plan.existing_file.is_some())
        {
            ensure_remote_dir(sftp, &ue4ss_backup_dir)?;
        }
        let mut manifest = SftpManagedManifest {
            version: 1,
            created_at: created_at.clone(),
            merged_path: merged_created
                .then(|| remote_join(&account.mods_path, &merged_remote_name)),
            merged_name: merged_created.then(|| merged_remote_name.clone()),
            sources,
            backups: Vec::new(),
            renames: Vec::new(),
            created_paths: Vec::new(),
            winners: valid_winners.clone(),
        };
        let mutation = (|| -> Result<()> {
            for file in &backup_files {
                let reason = to_backup
                    .get(&file.path)
                    .cloned()
                    .unwrap_or_else(|| "disabled".to_string());
                manifest
                    .backups
                    .push(backup_remote_file(sftp, file, &backup_dir, &reason)?);
                if file.name.to_ascii_lowercase().ends_with(".pak") {
                    let signature = remote_with_extension(&file.path, "sig");
                    if let Ok(stat) = sftp.lstat(Path::new(&signature)) {
                        if !stat.is_dir() {
                            let signature_file = RemoteFile {
                                name: entry_name(&signature),
                                path: signature,
                                is_directory: false,
                                size: stat.size.unwrap_or(0),
                                modified_at: None,
                            };
                            manifest.backups.push(backup_remote_file(
                                sftp,
                                &signature_file,
                                &backup_dir,
                                "signature",
                            )?);
                        }
                    }
                }
            }
            for (file, target_path, source_signature, target_signature, has_signature) in
                &planned_renames
            {
                manifest.renames.push(SftpManagedRename {
                    name: file.name.clone(),
                    original_path: file.path.clone(),
                    deployed_path: target_path.clone(),
                    has_signature: *has_signature,
                });
                sftp.rename(Path::new(&file.path), Path::new(target_path), None)
                    .with_context(|| {
                        format!("无法调整服务器 PAK 顺序 {} -> {target_path}", file.path)
                    })?;
                if *has_signature {
                    sftp.rename(
                        Path::new(source_signature),
                        Path::new(target_signature),
                        None,
                    )
                    .with_context(|| {
                        format!(
                            "无法调整服务器签名顺序 {} -> {target_signature}",
                            source_signature
                        )
                    })?;
                }
            }
            if let Some(plan) = &ue4ss_plan {
                if let Some(file) = &plan.existing_file {
                    manifest.backups.push(backup_remote_file(
                        sftp,
                        file,
                        &ue4ss_backup_dir,
                        "ue4ss-config",
                    )?);
                } else {
                    manifest.created_paths.push(plan.path.clone());
                }
                write_remote_text_file(sftp, &plan.path, &plan.desired)?;
            }
            if merged_created {
                let merged_path = remote_join(&account.mods_path, &merged_remote_name);
                if sftp.lstat(Path::new(&merged_path)).is_ok() {
                    bail!("服务器合并包目标已存在，拒绝覆盖：{merged_path}");
                }
                upload_local_file(sftp, &merged_local, &merged_path)?;
            }
            write_managed_manifest(sftp, &account.mods_path, &manifest)?;
            Ok(())
        })();
        if let Err(error) = mutation {
            let _ = restore_managed_manifest(sftp, &account.mods_path, &manifest);
            return Err(error);
        }
        Ok(manifest)
    });
    let _ = std::fs::remove_dir_all(&stage_root);
    let manifest = manifest?;

    let merged_backup_count = manifest
        .backups
        .iter()
        .filter(|item| item.reason == "merged")
        .count();
    let disabled_backup_count = manifest
        .backups
        .iter()
        .filter(|item| item.reason == "disabled")
        .count();
    let mut actions = Vec::new();
    if merged_created {
        actions.push(format!(
            "已备份 {merged_backup_count} 个冲突 PAK 并上传合并包（来源 {} 个）",
            manifest.sources.len()
        ));
    }
    if disabled_backup_count > 0 {
        actions.push(format!("已备份 {disabled_backup_count} 个禁用 PAK"));
    }
    if !manifest.renames.is_empty() {
        actions.push(format!(
            "已调整 {} 个 PAK 的加载顺序",
            manifest.renames.len()
        ));
    }
    if ue4ss_changed {
        actions.push("已更新 UE4SS 模组启停与加载顺序".to_string());
    }
    let message = if actions.is_empty() {
        "服务器托管布局已更新".to_string()
    } else {
        actions.join("；")
    };
    send_conflict_progress(&progress, "completed", 1, 1, 0, 0, None, &message);
    Ok(SftpApplyResult { message, manifest })
}

pub fn restore_remote_layout(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
) -> Result<SftpOperationResult> {
    let account = active_account(settings, Some(account_id))?;
    if account.mods_path.trim().is_empty() {
        bail!("尚未定位远端 PAK 模组目录");
    }
    if normalize_remote_path(&account.mods_path) == "/" {
        bail!("拒绝在服务器根目录恢复模组布局，请先定位具体的 ~mods 目录");
    }
    let restored = with_sftp(paths, account, |sftp| {
        let Some(manifest) = read_managed_manifest(sftp, &account.mods_path, &account.ue4ss_path)?
        else {
            bail!("服务器上没有可恢复的托管备份");
        };
        let count = manifest.backups.len() + manifest.renames.len() + manifest.created_paths.len();
        restore_managed_manifest(sftp, &account.mods_path, &manifest)?;
        Ok(count)
    })?;
    Ok(SftpOperationResult {
        message: format!("已恢复 {restored} 项服务器托管文件变更"),
        path: account.mods_path.clone(),
    })
}

fn read_managed_manifest(
    sftp: &Sftp,
    mods_path: &str,
    ue4ss_path: &str,
) -> Result<Option<SftpManagedManifest>> {
    let manifest_path = remote_join(mods_path, REMOTE_MERGED_MANIFEST);
    let Ok(stat) = sftp.stat(Path::new(&manifest_path)) else {
        return Ok(None);
    };
    if stat.is_dir() || stat.size.unwrap_or(0) > MAX_REMOTE_MANIFEST_BYTES {
        return Ok(None);
    }
    let file = sftp
        .open(Path::new(&manifest_path))
        .with_context(|| format!("无法读取服务器托管清单 {manifest_path}"))?;
    let mut bytes = Vec::new();
    file.take(MAX_REMOTE_MANIFEST_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_REMOTE_MANIFEST_BYTES {
        return Ok(None);
    }
    let manifest = serde_json::from_slice::<SftpManagedManifest>(&bytes).ok();
    if let Some(manifest) = &manifest {
        validate_managed_manifest_paths(mods_path, ue4ss_path, manifest)?;
    }
    Ok(manifest)
}

fn read_remote_text_file(
    sftp: &Sftp,
    path: &str,
    max_bytes: u64,
) -> Result<Option<(RemoteFile, String)>> {
    let Ok(stat) = sftp.lstat(Path::new(path)) else {
        return Ok(None);
    };
    if !stat.is_file() {
        bail!("远端配置路径不是文件：{path}");
    }
    if stat.size.unwrap_or(0) > max_bytes {
        bail!("远端配置文件超过大小限制：{path}");
    }
    let file = sftp
        .open(Path::new(path))
        .with_context(|| format!("无法读取远端配置文件 {path}"))?;
    let mut bytes = Vec::new();
    file.take(max_bytes + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max_bytes {
        bail!("远端配置文件超过大小限制：{path}");
    }
    let content =
        String::from_utf8(bytes).with_context(|| format!("远端配置文件不是 UTF-8：{path}"))?;
    Ok(Some((
        RemoteFile {
            name: entry_name(path),
            path: path.to_string(),
            is_directory: false,
            size: stat.size.unwrap_or(content.len() as u64),
            modified_at: stat.mtime.map(|seconds| {
                Utc.timestamp_opt(seconds as i64, 0)
                    .single()
                    .unwrap_or_else(Utc::now)
                    .to_rfc3339()
            }),
        },
        content,
    )))
}

fn write_remote_text_file(sftp: &Sftp, path: &str, content: &str) -> Result<()> {
    if let Ok(stat) = sftp.lstat(Path::new(path)) {
        if !stat.is_file() {
            bail!("拒绝写入非普通远端配置文件：{path}");
        }
    }
    let mut remote = sftp
        .create(Path::new(path))
        .with_context(|| format!("无法创建远端配置文件 {path}"))?;
    remote.write_all(content.as_bytes())?;
    remote.flush()?;
    Ok(())
}

fn write_managed_manifest(
    sftp: &Sftp,
    mods_path: &str,
    manifest: &SftpManagedManifest,
) -> Result<()> {
    let bytes = serde_json::to_vec_pretty(manifest)?;
    let path = remote_join(mods_path, REMOTE_MERGED_MANIFEST);
    if let Ok(stat) = sftp.lstat(Path::new(&path)) {
        if !stat.is_file() {
            bail!("服务器托管清单路径不是普通文件：{path}");
        }
    }
    let mut remote = sftp
        .create(Path::new(&path))
        .with_context(|| format!("无法创建服务器托管清单 {path}"))?;
    remote.write_all(&bytes)?;
    remote.write_all(b"\n")?;
    remote.flush()?;
    Ok(())
}

fn backup_remote_file(
    sftp: &Sftp,
    file: &RemoteFile,
    backup_dir: &str,
    reason: &str,
) -> Result<SftpManagedBackup> {
    let name = validate_remote_name(&file.name)?;
    let backup_path = remote_join(backup_dir, &format!("{name}.bak"));
    if sftp.lstat(Path::new(&backup_path)).is_ok() {
        bail!("服务器备份目标已存在：{backup_path}");
    }
    sftp.rename(Path::new(&file.path), Path::new(&backup_path), None)
        .with_context(|| format!("无法备份远端文件 {} -> {backup_path}", file.path))?;
    Ok(SftpManagedBackup {
        name,
        original_path: file.path.clone(),
        backup_path,
        reason: reason.to_string(),
    })
}

fn restore_managed_manifest(
    sftp: &Sftp,
    mods_path: &str,
    manifest: &SftpManagedManifest,
) -> Result<()> {
    for rename in manifest.renames.iter().rev() {
        if rename.has_signature {
            let original_signature = remote_with_extension(&rename.original_path, "sig");
            let deployed_signature = remote_with_extension(&rename.deployed_path, "sig");
            if let Ok(stat) = sftp.lstat(Path::new(&deployed_signature)) {
                if stat.is_dir() {
                    bail!("托管排序签名路径不是文件：{deployed_signature}");
                }
                if sftp.lstat(Path::new(&original_signature)).is_ok() {
                    bail!("恢复排序签名时发现原路径已存在：{original_signature}");
                }
                sftp.rename(
                    Path::new(&deployed_signature),
                    Path::new(&original_signature),
                    None,
                )
                .with_context(|| {
                    format!("无法恢复排序签名 {deployed_signature} -> {original_signature}")
                })?;
            }
        }
        if let Ok(stat) = sftp.lstat(Path::new(&rename.deployed_path)) {
            if stat.is_dir() {
                bail!("托管排序路径不是文件：{}", rename.deployed_path);
            }
            if sftp.lstat(Path::new(&rename.original_path)).is_ok() {
                bail!("恢复排序文件名时发现原路径已存在：{}", rename.original_path);
            }
            sftp.rename(
                Path::new(&rename.deployed_path),
                Path::new(&rename.original_path),
                None,
            )
            .with_context(|| {
                format!(
                    "无法恢复排序文件名 {} -> {}",
                    rename.deployed_path, rename.original_path
                )
            })?;
        }
    }
    for backup in manifest.backups.iter().rev() {
        let Ok(stat) = sftp.lstat(Path::new(&backup.backup_path)) else {
            continue;
        };
        if stat.is_dir() {
            bail!("服务器托管备份路径不是文件：{}", backup.backup_path);
        }
        if sftp.lstat(Path::new(&backup.original_path)).is_ok() {
            bail!("恢复备份时发现原路径已存在：{}", backup.original_path);
        }
        sftp.rename(
            Path::new(&backup.backup_path),
            Path::new(&backup.original_path),
            None,
        )
        .with_context(|| {
            format!(
                "无法恢复服务器备份 {} -> {}",
                backup.backup_path, backup.original_path
            )
        })?;
    }
    for path in manifest.created_paths.iter().rev() {
        if let Ok(stat) = sftp.lstat(Path::new(path)) {
            if stat.is_dir() {
                bail!("托管创建路径不是文件：{path}");
            }
            sftp.unlink(Path::new(path))
                .with_context(|| format!("无法删除托管创建的配置文件 {path}"))?;
        }
    }
    if let Some(merged_path) = &manifest.merged_path {
        if let Ok(stat) = sftp.lstat(Path::new(merged_path)) {
            if stat.is_dir() {
                bail!("合并包路径不是文件：{merged_path}");
            }
            sftp.unlink(Path::new(merged_path))
                .with_context(|| format!("无法删除合并包 {merged_path}"))?;
        }
    }
    let manifest_path = remote_join(mods_path, REMOTE_MERGED_MANIFEST);
    if let Ok(stat) = sftp.lstat(Path::new(&manifest_path)) {
        if stat.is_dir() {
            bail!("服务器托管清单路径不是文件：{manifest_path}");
        }
        sftp.unlink(Path::new(&manifest_path))
            .with_context(|| format!("无法删除服务器托管清单 {manifest_path}"))?;
    }
    Ok(())
}

fn build_remote_merged_pak(
    paths: &AppPaths,
    mods: &[ModEntry],
    analysis: &crate::mods::ConflictAnalysis,
    metadata: &MetadataFile,
    output: &Path,
) -> Result<bool> {
    let conflicting_ids = analysis
        .groups
        .iter()
        .flat_map(|group| group.owners.iter().map(|owner| owner.id.as_str()))
        .collect::<HashSet<_>>();
    if conflicting_ids.is_empty() {
        return Ok(false);
    }
    let mods_by_id = mods
        .iter()
        .map(|item| (item.id.as_str(), item))
        .collect::<BTreeMap<_, _>>();
    let mut selected_entries = BTreeMap::<String, (String, PathBuf)>::new();
    for group in &analysis.groups {
        let winner = mods_by_id
            .get(group.winner_id.as_str())
            .with_context(|| format!("找不到冲突合并胜者：{}", group.winner_id))?;
        let pak_path = PathBuf::from(&winner.file_path);
        if !pak_path.is_file() {
            bail!("冲突合并胜者缓存不存在：{}", pak_path.display());
        }
        let available = metadata
            .entries
            .get(&winner.id)
            .into_iter()
            .flat_map(|entry| entry.pak_entries.iter())
            .filter_map(|entry| crate::mods::normalize_entry_path(entry))
            .map(|entry| entry.to_ascii_lowercase())
            .collect::<BTreeSet<_>>();
        for resource in &group.paths {
            if !available.contains(&resource.to_ascii_lowercase()) {
                bail!("冲突合并失败：{} 缺少资源 {}", winner.name, resource);
            }
            let key = resource.to_ascii_lowercase();
            if let Some((existing, _)) = selected_entries.get(&key) {
                if !existing.eq_ignore_ascii_case(&winner.file_path) {
                    bail!("资源 {resource} 同时被多个冲突胜者选中");
                }
            } else {
                selected_entries.insert(key, (resource.clone(), pak_path.clone()));
            }
        }
    }
    let mut conflicting_mods = mods
        .iter()
        .filter(|item| conflicting_ids.contains(item.id.as_str()))
        .collect::<Vec<_>>();
    conflicting_mods.sort_by(|left, right| {
        left.load_order
            .cmp(&right.load_order)
            .then_with(|| left.id.cmp(&right.id))
    });
    for item in conflicting_mods {
        let pak_path = PathBuf::from(&item.file_path);
        let Some(entry) = metadata.entries.get(&item.id) else {
            bail!("参与合并的模组缺少资源清单：{}", item.name);
        };
        for raw in &entry.pak_entries {
            let Some(resource) = crate::mods::normalize_entry_path(raw) else {
                continue;
            };
            selected_entries
                .entry(resource.to_ascii_lowercase())
                .or_insert((resource, pak_path.clone()));
        }
    }
    if selected_entries.is_empty() {
        return Ok(false);
    }

    let stage = output
        .parent()
        .context("合并包输出缺少父目录")?
        .join("tree");
    std::fs::create_dir_all(&stage)?;
    let result = (|| -> Result<()> {
        let mut expected = BTreeSet::new();
        for (_, (resource, pak_path)) in &selected_entries {
            let destination = stage.join(safe_pak_relative_path(resource)?);
            if !destination.starts_with(&stage) {
                bail!("合并暂存路径越界：{resource}");
            }
            crate::mods::extract_pak_entry(paths, pak_path, resource, &destination)?;
            expected.insert(resource.to_ascii_lowercase());
        }
        crate::mods::pack_pak(paths, &stage, output)?;
        let packed = crate::mods::list_pak_entries(paths, output)?
            .into_iter()
            .map(|entry| entry.to_ascii_lowercase())
            .collect::<BTreeSet<_>>();
        if !expected.is_subset(&packed) {
            bail!("合并包校验失败：输出缺少预期资源");
        }
        Ok(())
    })();
    let _ = std::fs::remove_dir_all(&stage);
    result?;
    Ok(true)
}

fn safe_pak_relative_path(resource: &str) -> Result<PathBuf> {
    let mut relative = PathBuf::new();
    for component in Path::new(resource).components() {
        let Component::Normal(name) = component else {
            bail!("拒绝不安全的 PAK 资源路径：{resource}");
        };
        let name = name.to_string_lossy();
        if name.is_empty() || name.contains(':') || name.chars().any(char::is_control) {
            bail!("拒绝不安全的 PAK 资源路径：{resource}");
        }
        relative.push(name.as_ref());
    }
    if relative.as_os_str().is_empty() {
        bail!("PAK 资源路径为空");
    }
    Ok(relative)
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

fn is_managed_merged_name(name: &str) -> bool {
    name.to_ascii_lowercase()
        .ends_with("_scum_mod_desk_merged.pak")
}

fn remote_deployment_prefix_width(pak_count: usize) -> usize {
    pak_count.to_string().len().max(3)
}

fn numbered_remote_pak_file_name(index: usize, original: &str, width: usize) -> String {
    format!("{index:0width$}_{original}")
}

fn plan_remote_pak_renames(
    sorted_paks: &[RemoteFile],
    disabled: &HashSet<String>,
    conflicting_paths: &BTreeSet<String>,
    mods_path: &str,
    prefix_width: usize,
) -> Vec<(RemoteFile, String)> {
    sorted_paks
        .iter()
        .enumerate()
        .filter(|(_, file)| {
            !disabled.contains(&file.path)
                && !conflicting_paths.contains(&file.path)
                && !is_managed_merged_name(&file.name)
        })
        .filter_map(|(load_order, file)| {
            let target_name = numbered_remote_pak_file_name(load_order, &file.name, prefix_width);
            (target_name != file.name).then(|| (file.clone(), remote_join(mods_path, &target_name)))
        })
        .collect()
}

fn build_remote_ue4ss_mods_txt(
    files: &[RemoteFile],
    order: &[String],
    disabled: &HashSet<String>,
    existing: &str,
) -> String {
    let order_index = order
        .iter()
        .enumerate()
        .map(|(index, path)| (path.as_str(), index))
        .collect::<BTreeMap<_, _>>();
    let mut mods = files
        .iter()
        .filter(|file| file.is_directory)
        .collect::<Vec<_>>();
    mods.sort_by(|left, right| {
        order_index
            .get(left.path.as_str())
            .copied()
            .unwrap_or(usize::MAX)
            .cmp(
                &order_index
                    .get(right.path.as_str())
                    .copied()
                    .unwrap_or(usize::MAX),
            )
            .then_with(|| {
                left.name
                    .to_ascii_lowercase()
                    .cmp(&right.name.to_ascii_lowercase())
            })
            .then_with(|| left.name.cmp(&right.name))
    });
    let managed_names = mods
        .iter()
        .map(|file| file.name.as_str())
        .collect::<HashSet<_>>();
    let mut kept = existing
        .lines()
        .filter(|line| {
            let name = line.split(':').next().unwrap_or_default().trim();
            !managed_names.contains(name)
        })
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    let managed_lines = mods
        .iter()
        .map(|file| {
            let enabled = usize::from(!disabled.contains(&file.path));
            format!("{} : {enabled}", file.name)
        })
        .collect::<Vec<_>>();
    let insert_at = kept
        .iter()
        .position(|line| line.to_ascii_lowercase().starts_with("keybinds"))
        .unwrap_or(kept.len());
    let tail = kept.split_off(insert_at);
    kept.extend(managed_lines);
    kept.extend(tail);
    kept.join("\n")
}

fn validate_managed_manifest_paths(
    mods_path: &str,
    ue4ss_path: &str,
    manifest: &SftpManagedManifest,
) -> Result<()> {
    if manifest.version != 1 {
        bail!("不支持的服务器托管清单版本：{}", manifest.version);
    }
    let roots = [mods_path, ue4ss_path]
        .into_iter()
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .collect::<Vec<_>>();
    if roots.is_empty() {
        bail!("服务器托管清单缺少可用的模组根目录");
    }
    let mods_root = normalize_remote_path(mods_path);
    let backup_roots = roots
        .iter()
        .map(|root| normalize_remote_path(root))
        .filter(|root| root != "/")
        .map(|root| remote_join(&root, REMOTE_BACKUP_DIRECTORY))
        .collect::<Vec<_>>();

    let require_file_in_root = |path: &str| -> Result<()> {
        if !is_clean_remote_path(path) || !roots.iter().any(|root| remote_path_within(root, path)) {
            bail!("服务器托管清单包含越界文件路径：{path}");
        }
        Ok(())
    };
    let require_backup_path = |path: &str| -> Result<()> {
        if !is_clean_remote_path(path)
            || !backup_roots
                .iter()
                .any(|root| remote_path_within(root, path))
            || backup_roots
                .iter()
                .any(|root| normalize_remote_path(path) == *root)
        {
            bail!("服务器托管清单包含越界备份路径：{path}");
        }
        Ok(())
    };

    if let Some(merged_path) = &manifest.merged_path {
        if !is_clean_remote_path(merged_path)
            || !remote_path_within(&mods_root, merged_path)
            || normalize_remote_path(merged_path) == mods_root
        {
            bail!("服务器托管清单包含越界合并包路径：{merged_path}");
        }
    }
    for source in &manifest.sources {
        if !is_clean_remote_path(&source.path) || !remote_path_within(&mods_root, &source.path) {
            bail!("服务器托管清单包含越界合并来源：{}", source.path);
        }
    }

    let mut originals = HashSet::new();
    let mut backups = HashSet::new();
    for backup in &manifest.backups {
        require_file_in_root(&backup.original_path)?;
        require_backup_path(&backup.backup_path)?;
        if !originals.insert(backup.original_path.clone())
            || !backups.insert(backup.backup_path.clone())
        {
            bail!("服务器托管清单包含重复文件或备份路径");
        }
        if entry_name(&backup.original_path) != backup.name {
            bail!("服务器托管清单中的文件名与原始路径不一致：{}", backup.name);
        }
    }

    let mut deployed_paths = HashSet::new();
    for rename in &manifest.renames {
        require_file_in_root(&rename.original_path)?;
        require_file_in_root(&rename.deployed_path)?;
        if !originals.insert(rename.original_path.clone()) {
            bail!("服务器托管清单包含重复原始路径：{}", rename.original_path);
        }
        if !deployed_paths.insert(rename.deployed_path.clone()) {
            bail!("服务器托管清单包含重复排序目标：{}", rename.deployed_path);
        }
        if remote_parent(&rename.original_path) != remote_parent(&rename.deployed_path) {
            bail!("服务器排序重命名不能跨目录：{}", rename.deployed_path);
        }
        if entry_name(&rename.original_path) != rename.name {
            bail!("服务器托管清单中的文件名与排序路径不一致：{}", rename.name);
        }
        validate_remote_name(&entry_name(&rename.deployed_path))?;
    }
    let mut created_paths = HashSet::new();
    for path in &manifest.created_paths {
        require_file_in_root(path)?;
        if roots
            .iter()
            .any(|root| normalize_remote_path(root) == normalize_remote_path(path))
        {
            bail!("服务器托管清单不能把模组根目录标记为创建文件：{path}");
        }
        if !created_paths.insert(path.clone()) {
            bail!("服务器托管清单包含重复创建路径：{path}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        active_account, build_remote_merged_pak, build_remote_ue4ss_mods_txt,
        conflict_entries_cache_name, download_file, ensure_remote_operation_allowed,
        load_remote_notes, move_remote_notes, numbered_remote_pak_file_name, pak_path_candidates,
        plan_remote_pak_renames, read_conflict_entries_cache, remote_deployment_prefix_width,
        remote_join, remove_remote_notes_under, root_from_pak_path, root_from_ue4ss_path,
        safe_pak_relative_path, save_remote_notes, ue4ss_path_candidates,
        validate_managed_manifest_paths, validate_remote_name, write_conflict_entries_cache,
        RemoteNotesFile,
    };
    use crate::metadata::MetadataFile;
    use crate::models::{
        AppSettings, ModEntry, RemoteFile, SftpAccount, SftpManagedBackup, SftpManagedManifest,
        SftpManagedRename,
    };
    use crate::test_support::TempRoot;
    use std::collections::{BTreeSet, HashSet};
    use std::path::Path;
    use std::process::Command;

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
    fn creates_stable_remote_pak_order_prefixes() {
        assert_eq!(remote_deployment_prefix_width(1), 3);
        assert_eq!(remote_deployment_prefix_width(1_250), 4);
        assert_eq!(
            numbered_remote_pak_file_name(12, "Weapons.pak", 3),
            "012_Weapons.pak"
        );
    }

    #[test]
    fn plans_remote_pak_renames_in_the_requested_order() {
        let mods_root = "/srv/scum/SCUM/Content/Paks/~mods";
        let file = |name: &str| RemoteFile {
            name: name.to_string(),
            path: remote_join(mods_root, name),
            is_directory: false,
            size: 1,
            modified_at: None,
        };
        let files = vec![
            file("Alpha.pak"),
            file("Beta.pak"),
            file("Gamma.pak"),
            file("Delta.pak"),
            file("999_SCUM_Mod_Desk_Merged.pak"),
        ];
        let disabled = HashSet::from([remote_join(mods_root, "Beta.pak")]);
        let conflicting = BTreeSet::from([remote_join(mods_root, "Delta.pak")]);
        let planned = plan_remote_pak_renames(
            &files,
            &disabled,
            &conflicting,
            mods_root,
            remote_deployment_prefix_width(files.len()),
        );
        assert_eq!(
            planned
                .iter()
                .map(|(file, target)| (file.name.as_str(), target.as_str()))
                .collect::<Vec<_>>(),
            vec![
                (
                    "Alpha.pak",
                    "/srv/scum/SCUM/Content/Paks/~mods/000_Alpha.pak"
                ),
                (
                    "Gamma.pak",
                    "/srv/scum/SCUM/Content/Paks/~mods/002_Gamma.pak"
                ),
            ]
        );
    }

    #[test]
    fn builds_remote_ue4ss_enable_and_order_config() {
        let ue4ss_root = "/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods";
        let file = |name: &str, is_directory: bool| RemoteFile {
            name: name.to_string(),
            path: remote_join(ue4ss_root, name),
            is_directory,
            size: 0,
            modified_at: None,
        };
        let files = vec![
            file("BPModLoaderMod", true),
            file("SCUMTweaks", true),
            file("loose.lua", false),
        ];
        let order = vec![
            "/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods/SCUMTweaks".to_string(),
            "/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods/BPModLoaderMod".to_string(),
        ];
        let disabled = HashSet::from([remote_join(ue4ss_root, "BPModLoaderMod")]);
        let output = build_remote_ue4ss_mods_txt(
            &files,
            &order,
            &disabled,
            "OtherMod : 1\nBPModLoaderMod : 1\nKeybinds : 1\n",
        );
        assert_eq!(
            output,
            "OtherMod : 1\nSCUMTweaks : 1\nBPModLoaderMod : 0\nKeybinds : 1"
        );
    }

    #[test]
    fn rejects_managed_manifest_paths_outside_mod_roots() {
        let mods_root = "/srv/scum/SCUM/Content/Paks/~mods";
        let ue4ss_root = "/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods";
        let valid = SftpManagedManifest {
            version: 1,
            merged_path: Some(remote_join(mods_root, "999_SCUM_Mod_Desk_Merged.pak")),
            backups: vec![SftpManagedBackup {
                name: "Alpha.pak".to_string(),
                original_path: remote_join(mods_root, "Alpha.pak"),
                backup_path: remote_join(
                    mods_root,
                    "_SCUM_Mod_Desk_Backups/20260101-000000-000/Alpha.pak.bak",
                ),
                reason: "merged".to_string(),
            }],
            renames: vec![SftpManagedRename {
                name: "Beta.pak".to_string(),
                original_path: remote_join(mods_root, "Beta.pak"),
                deployed_path: remote_join(mods_root, "001_Beta.pak"),
                has_signature: false,
            }],
            ..SftpManagedManifest::default()
        };
        assert!(validate_managed_manifest_paths(mods_root, ue4ss_root, &valid).is_ok());

        let mut escaped_backup = valid.clone();
        escaped_backup.backups[0].backup_path = "/srv/scum/outside/Alpha.pak.bak".to_string();
        assert!(validate_managed_manifest_paths(mods_root, ue4ss_root, &escaped_backup).is_err());

        let mut escaped_restore = valid;
        escaped_restore.renames[0].original_path =
            "/srv/scum/SCUM/Config/ServerSettings.ini".to_string();
        assert!(validate_managed_manifest_paths(mods_root, ue4ss_root, &escaped_restore).is_err());

        let mut escaped_created = SftpManagedManifest {
            created_paths: vec!["/srv/scum/SCUM/Config/ServerSettings.ini".to_string()],
            ..SftpManagedManifest::default()
        };
        escaped_created.version = 1;
        assert!(validate_managed_manifest_paths(mods_root, ue4ss_root, &escaped_created).is_err());
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
    fn builds_a_merged_pak_with_selected_winner_and_unique_files() {
        let temp = TempRoot::new("sftp-merged-pak");
        let paths = temp.paths();
        let alpha = build_test_pak(
            temp.path(),
            &paths,
            "Alpha",
            &[
                ("SCUM/Content/Assets/Shared.uasset", b"alpha"),
                ("SCUM/Content/Assets/AlphaOnly.uexp", b"alpha-only"),
            ],
        );
        let beta = build_test_pak(
            temp.path(),
            &paths,
            "Beta",
            &[
                ("SCUM/Content/Assets/Shared.uasset", b"beta"),
                ("SCUM/Content/Assets/BetaOnly.uexp", b"beta-only"),
            ],
        );
        let alpha_entries = crate::mods::list_pak_entries(&paths, &alpha).unwrap();
        let beta_entries = crate::mods::list_pak_entries(&paths, &beta).unwrap();
        let mut metadata = MetadataFile::default();
        metadata.entry_mut("alpha").pak_entries = alpha_entries;
        metadata.entry_mut("beta").pak_entries = beta_entries;
        metadata.conflict_winners.insert(
            "scum/content/assets/shared".to_string(),
            "alpha".to_string(),
        );
        let mods = vec![
            ModEntry {
                id: "alpha".to_string(),
                name: "Alpha.pak".to_string(),
                file_name: "Alpha.pak".to_string(),
                file_path: alpha.to_string_lossy().into_owned(),
                enabled: true,
                mod_type: "clientPak".to_string(),
                load_order: 0,
                ..ModEntry::default()
            },
            ModEntry {
                id: "beta".to_string(),
                name: "Beta.pak".to_string(),
                file_name: "Beta.pak".to_string(),
                file_path: beta.to_string_lossy().into_owned(),
                enabled: true,
                mod_type: "clientPak".to_string(),
                load_order: 1,
                ..ModEntry::default()
            },
        ];
        let analysis = crate::mods::analyze_conflicts(&metadata, &mods);
        let output = temp.path().join("Merged.pak");

        assert!(build_remote_merged_pak(&paths, &mods, &analysis, &metadata, &output).unwrap());
        let entries = crate::mods::list_pak_entries(&paths, &output).unwrap();
        assert!(entries
            .iter()
            .any(|entry| entry.ends_with("AlphaOnly.uexp")));
        assert!(entries.iter().any(|entry| entry.ends_with("BetaOnly.uexp")));
        let extracted = temp.path().join("Shared.uasset");
        crate::mods::extract_pak_entry(
            &paths,
            &output,
            "SCUM/Content/Assets/Shared.uasset",
            &extracted,
        )
        .unwrap();
        assert_eq!(std::fs::read(extracted).unwrap(), b"alpha");
    }

    #[test]
    fn rejects_unsafe_merged_pak_paths() {
        assert!(safe_pak_relative_path("SCUM/Content/Shared.uasset").is_ok());
        assert!(safe_pak_relative_path("../escape.uasset").is_err());
        assert!(safe_pak_relative_path("SCUM/Content/C:escape.uasset").is_err());
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

    fn build_test_pak(
        root: &Path,
        paths: &crate::paths::AppPaths,
        label: &str,
        entries: &[(&str, &[u8])],
    ) -> std::path::PathBuf {
        let input = root.join(format!("{label}-input"));
        for (relative, body) in entries {
            let path = input.join(relative.replace('/', std::path::MAIN_SEPARATOR_STR));
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, body).unwrap();
        }
        let pak = root.join(format!("{label}.pak"));
        let output = Command::new(paths.resource("repak.exe"))
            .arg("pack")
            .arg("-m")
            .arg("../../../")
            .arg(&input)
            .arg(&pak)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "repak pack failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        pak
    }
}
