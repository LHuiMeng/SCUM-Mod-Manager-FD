use crate::models::{AppSettings, SftpAccount};
use crate::paths::{path_string, AppPaths};
use anyhow::{Context, Result};
use base64::Engine;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::Path;
use uuid::Uuid;

pub fn load_settings(paths: &AppPaths) -> Result<AppSettings> {
    migrate_legacy_files(paths);
    if !paths.config_file.exists() {
        let settings = AppSettings::default();
        save_settings(paths, &settings)?;
        return Ok(settings);
    }

    let raw = std::fs::read_to_string(&paths.config_file)
        .with_context(|| format!("无法读取 {}", paths.config_file.display()))?;
    let value: Value = serde_json::from_str(&raw).context("config.json 格式无效")?;
    let mut settings: AppSettings =
        serde_json::from_value(value.clone()).context("config.json 字段无法解析")?;
    normalize_settings(paths, &mut settings, Some(&value));
    save_settings(paths, &settings)?;
    Ok(settings)
}

pub fn save_settings(paths: &AppPaths, settings: &AppSettings) -> Result<()> {
    let mut normalized = settings.clone();
    normalize_settings(paths, &mut normalized, None);
    let json = serde_json::to_string_pretty(&normalized)?;
    std::fs::write(&paths.config_file, format!("{json}\n"))
        .with_context(|| format!("无法写入 {}", paths.config_file.display()))?;
    Ok(())
}

fn normalize_settings(paths: &AppPaths, settings: &mut AppSettings, raw: Option<&Value>) {
    if settings.theme != "dark" && settings.theme != "light" {
        settings.theme = "light".to_string();
    }
    settings.cloud.base_urls = settings
        .cloud
        .base_urls
        .iter()
        .filter_map(|url| normalize_cloud_url(url))
        .collect();
    let mut seen = HashSet::new();
    settings
        .cloud
        .base_urls
        .retain(|url| seen.insert(url.to_ascii_lowercase()));

    settings.cloud.active_base_url =
        normalize_cloud_url(&settings.cloud.active_base_url).unwrap_or_default();
    if !settings.cloud.active_base_url.is_empty() {
        match settings
            .cloud
            .base_urls
            .iter()
            .find(|url| url.eq_ignore_ascii_case(&settings.cloud.active_base_url))
            .cloned()
        {
            Some(url) => settings.cloud.active_base_url = url,
            None => settings
                .cloud
                .base_urls
                .insert(0, settings.cloud.active_base_url.clone()),
        }
    }
    if settings.cloud.active_base_url.is_empty() {
        settings.cloud.active_base_url = settings
            .cloud
            .base_urls
            .first()
            .cloned()
            .unwrap_or_default();
    }

    let raw_accounts = raw
        .and_then(|value| {
            value
                .get("sftp_accounts")
                .or_else(|| value.get("sftpAccounts"))
        })
        .and_then(Value::as_array);

    for (index, account) in settings.sftp_accounts.iter_mut().enumerate() {
        if account.name.trim().is_empty() {
            account.name = if account.host.trim().is_empty() {
                format!("服务器 {}", index + 1)
            } else {
                account.host.clone()
            };
        }
        if account.port == 0 {
            account.port = 22;
        }
        if account.id.trim().is_empty() {
            account.id = account_id(account);
        }
        account.has_password = paths.sftp_secret(&account.id).exists();

        if let Some(raw_account) = raw_accounts.and_then(|items| items.get(index)) {
            migrate_legacy_password(paths, account, raw_account);
        }
    }

    let active_exists = settings.active_sftp_account_id.as_ref().is_some_and(|id| {
        settings
            .sftp_accounts
            .iter()
            .any(|account| &account.id == id)
    });
    if !active_exists {
        settings.active_sftp_account_id = settings
            .sftp_accounts
            .first()
            .map(|account| account.id.clone());
    }
}

fn migrate_legacy_password(paths: &AppPaths, account: &mut SftpAccount, raw: &Value) {
    if account.has_password || account.id.is_empty() {
        return;
    }
    let plain = raw
        .get("password")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let encrypted = raw
        .get("password_enc")
        .or_else(|| raw.get("passwordEnc"))
        .and_then(Value::as_str)
        .unwrap_or_default();

    let password = if !encrypted.is_empty() {
        base64::engine::general_purpose::STANDARD
            .decode(encrypted)
            .ok()
            .and_then(|bytes| crate::secrets::unprotect_for_migration(&bytes).ok())
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .filter(|value| !value.is_empty())
    } else if !plain.is_empty() {
        Some(plain.to_string())
    } else {
        None
    };

    if let Some(password) = password {
        if crate::secrets::write_secret(&paths.sftp_secret(&account.id), &password).is_ok() {
            account.has_password = true;
        }
    }
}

fn account_id(account: &SftpAccount) -> String {
    let mut hasher = Sha256::new();
    hasher.update(account.host.trim().to_ascii_lowercase());
    hasher.update(b"@");
    hasher.update(account.username.trim());
    let hash = hex::encode(hasher.finalize());
    if hash.is_empty() {
        Uuid::new_v4().to_string()
    } else {
        hash[..16].to_string()
    }
}

fn normalize_cloud_url(value: &str) -> Option<String> {
    let trimmed = value.trim().trim_end_matches('/');
    let parsed = url::Url::parse(trimmed).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return None;
    }
    Some(trimmed.to_string())
}

fn migrate_legacy_files(paths: &AppPaths) {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(exe_dir) = exe.parent() else {
        return;
    };
    if same_path(exe_dir, &paths.root) {
        return;
    }
    for name in ["config.json", "mods_meta.json"] {
        let source = exe_dir.join(name);
        let destination = paths.root.join(name);
        if source.exists() && !destination.exists() {
            let _ = std::fs::copy(source, destination);
        }
    }
}

fn same_path(left: &Path, right: &Path) -> bool {
    path_string(left)
        .replace('/', "\\")
        .eq_ignore_ascii_case(&path_string(right).replace('/', "\\"))
}

#[cfg(test)]
mod tests {
    use super::load_settings;
    use crate::test_support::TempRoot;
    use serde_json::json;
    use std::fs;

    #[test]
    fn normalizes_theme_and_cloud_source_urls() {
        let temp = TempRoot::new("config-normalize");
        let paths = temp.paths();
        fs::write(
            &paths.config_file,
            serde_json::to_vec_pretty(&json!({
                "theme": "neon",
                "cloud": {
                    "baseUrls": [
                        " https://Mods.Example/ ",
                        "https://Mods.Example",
                        "ftp://invalid.example",
                        "http://backup.example/"
                    ],
                    "activeBaseUrl": "javascript:alert(1)"
                }
            }))
            .unwrap(),
        )
        .unwrap();

        let settings = load_settings(&paths).unwrap();

        assert_eq!(settings.theme, "light");
        assert_eq!(
            settings.cloud.base_urls,
            vec!["https://Mods.Example", "http://backup.example"]
        );
        assert_eq!(settings.cloud.active_base_url, "https://Mods.Example");
    }

    #[test]
    fn migrates_legacy_sftp_password_without_serializing_it() {
        let temp = TempRoot::new("config-password-migration");
        let paths = temp.paths();
        let password = "unit-test-password-sentinel";
        fs::write(
            &paths.config_file,
            serde_json::to_vec_pretty(&json!({
                "theme": "dark",
                "sftpAccounts": [{
                    "name": "Test Server",
                    "host": "sftp.example.test",
                    "port": 0,
                    "username": "tester",
                    "password": password
                }]
            }))
            .unwrap(),
        )
        .unwrap();

        let settings = load_settings(&paths).unwrap();

        let account = settings.sftp_accounts.first().unwrap();
        assert_eq!(account.port, 22);
        assert!(account.has_password);
        assert!(!account.id.is_empty());
        assert!(paths.sftp_secret(&account.id).exists());
        let saved = fs::read_to_string(&paths.config_file).unwrap();
        assert!(!saved.contains(password));
        assert!(!saved.contains("\"password\""));
    }
}
