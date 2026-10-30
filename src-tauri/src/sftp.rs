use crate::models::{AppSettings, RemoteFile, SftpAccount, SftpConnectionResult, UploadResult};
use crate::paths::AppPaths;
use anyhow::{bail, Context, Result};
use base64::Engine;
use chrono::{TimeZone, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use ssh2::{Session, Sftp};
use std::collections::{BTreeMap, HashSet, VecDeque};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::time::Duration;

const MAX_REMOTE_SCAN_DIRECTORIES: usize = 96;
const MAX_REMOTE_SCAN_DEPTH: usize = 7;
const MAX_REMOTE_SCAN_ENTRIES_PER_DIRECTORY: usize = 300;

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
                host_key_fingerprint: Some(fingerprint),
                requires_trust: true,
            });
        }
    }
    authenticate_session(paths, &session, account)?;
    let sftp = session.sftp().context("无法建立 SFTP 通道")?;
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

pub fn upload_files(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
    local_paths: &[String],
) -> Result<UploadResult> {
    let account = active_account(settings, Some(account_id))?;
    if account.mods_path.trim().is_empty() {
        bail!("尚未设置服务器远端 ~mods 路径");
    }
    let uploaded = with_sftp(paths, account, |sftp| {
        let mut uploaded = 0;
        for local in local_paths {
            let local = Path::new(local);
            if !local.is_file() {
                continue;
            }
            let name = local
                .file_name()
                .context("上传文件缺少文件名")?
                .to_string_lossy();
            let remote = remote_join(&account.mods_path, &name);
            let mut source = std::fs::File::open(local)
                .with_context(|| format!("无法读取 {}", local.display()))?;
            let mut target = sftp
                .create(Path::new(&remote))
                .with_context(|| format!("无法创建远端文件 {remote}"))?;
            std::io::copy(&mut source, &mut target)?;
            uploaded += 1;
        }
        Ok(uploaded)
    })?;
    Ok(UploadResult {
        uploaded,
        message: format!("已上传 {uploaded} 个文件到 {}", account.mods_path),
    })
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
        active_account, pak_path_candidates, remote_join, root_from_pak_path, root_from_ue4ss_path,
        ue4ss_path_candidates,
    };
    use crate::models::{AppSettings, SftpAccount};

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
}
