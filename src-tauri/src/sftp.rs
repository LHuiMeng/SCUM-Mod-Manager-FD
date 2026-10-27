use crate::models::{AppSettings, RemoteFile, SftpAccount, SftpConnectionResult, UploadResult};
use crate::paths::AppPaths;
use anyhow::{bail, Context, Result};
use base64::Engine;
use chrono::{TimeZone, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use ssh2::{Session, Sftp};
use std::collections::BTreeMap;
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::time::Duration;

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
                host_key_fingerprint: Some(fingerprint),
                requires_trust: true,
            });
        }
    }
    authenticate_session(paths, &session, account)?;
    let sftp = session.sftp().context("无法建立 SFTP 通道")?;
    let detected = detect_mods_path(&sftp, account);
    Ok(SftpConnectionResult {
        ok: true,
        message: detected
            .as_ref()
            .map(|path| format!("连接成功，已定位 {}", path))
            .unwrap_or_else(|| "连接成功，但未自动定位 ~mods 目录".to_string()),
        detected_mods_path: detected,
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
    with_sftp(paths, account, |sftp| {
        let entries = sftp
            .readdir(Path::new(path))
            .with_context(|| format!("无法读取远端目录 {path}"))?;
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
        Ok(files)
    })
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

fn detect_mods_path(sftp: &Sftp, account: &SftpAccount) -> Option<String> {
    if !account.mods_path.trim().is_empty() && sftp.stat(Path::new(&account.mods_path)).is_ok() {
        return Some(account.mods_path.clone());
    }
    let user = account.username.trim();
    let mut candidates = vec![
        "/srv/scum/SCUM/Content/Paks/~mods".to_string(),
        "/opt/scum/SCUM/Content/Paks/~mods".to_string(),
        "/scum/SCUM/Content/Paks/~mods".to_string(),
        format!("/home/{user}/scum/SCUM/Content/Paks/~mods"),
        format!("/home/{user}/SCUM/Content/Paks/~mods"),
        format!("/home/{user}/.steam/steam/steamapps/common/SCUM/SCUM/Content/Paks/~mods"),
    ];
    candidates.dedup();
    candidates
        .into_iter()
        .find(|candidate| sftp.stat(Path::new(candidate)).is_ok())
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
    use super::{active_account, remote_join};
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
}
