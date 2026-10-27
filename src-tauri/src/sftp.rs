use crate::models::{AppSettings, RemoteFile, SftpAccount, SftpConnectionResult, UploadResult};
use crate::paths::AppPaths;
use anyhow::{bail, Context, Result};
use chrono::{TimeZone, Utc};
use ssh2::{Session, Sftp};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::time::Duration;

pub fn active_account<'a>(
    settings: &'a AppSettings,
    account_id: Option<&str>,
) -> Result<&'a SftpAccount> {
    let requested = account_id
        .map(ToString::to_string)
        .or_else(|| settings.active_sftp_account_id.clone());
    requested
        .as_deref()
        .and_then(|id| settings.sftp_accounts.iter().find(|item| item.id == id))
        .or_else(|| settings.sftp_accounts.first())
        .context("尚未保存 SFTP 服务器账户")
}

pub fn test_connection(
    paths: &AppPaths,
    settings: &AppSettings,
    account_id: &str,
) -> Result<SftpConnectionResult> {
    let account = active_account(settings, Some(account_id))?;
    let detected = with_sftp(paths, account, |sftp| Ok(detect_mods_path(sftp, account)))?;
    Ok(SftpConnectionResult {
        ok: true,
        message: detected
            .as_ref()
            .map(|path| format!("连接成功，已定位 {}", path))
            .unwrap_or_else(|| "连接成功，但未自动定位 ~mods 目录".to_string()),
        detected_mods_path: detected,
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
    session
        .userauth_password(account.username.trim(), &password)
        .context("SFTP 用户名或密码错误")?;
    if !session.authenticated() {
        bail!("SFTP 身份验证失败");
    }
    let sftp = session.sftp().context("无法建立 SFTP 通道")?;
    operation(&sftp)
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
