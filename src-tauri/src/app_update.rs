use crate::models::{AppUpdateInfo, AppUpdateProgress, InstallUpdateResult};
use crate::state::AppState;
use chrono::{DateTime, SecondsFormat, Utc};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter};
use tauri_plugin_updater::UpdaterExt;
use url::Url;

const PROGRESS_EVENT: &str = "app-update-progress";

#[derive(Debug, Clone)]
pub struct UpdateConfig {
    pub endpoint: String,
    pub public_key: String,
}

pub fn resolve_config(state: &AppState) -> Option<UpdateConfig> {
    let runtime_endpoint = state.secrets.update_endpoint.trim();
    let runtime_public_key = state.secrets.update_public_key.trim();
    let endpoint = compiled_or_runtime(option_env!("SCUM_UPDATE_ENDPOINT"), runtime_endpoint);
    let public_key = compiled_or_runtime(option_env!("SCUM_UPDATE_PUBLIC_KEY"), runtime_public_key);

    if endpoint.is_empty() || public_key.is_empty() {
        return None;
    }

    Some(UpdateConfig {
        endpoint: endpoint.to_string(),
        public_key: public_key.to_string(),
    })
}

fn compiled_or_runtime<'a>(compiled: Option<&'static str>, runtime: &'a str) -> &'a str {
    compiled
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(runtime)
}

pub async fn check(app: &AppHandle, config: Option<UpdateConfig>) -> Result<AppUpdateInfo, String> {
    let current_version = app.package_info().version.to_string();
    let Some(config) = config else {
        return Ok(AppUpdateInfo {
            configured: false,
            current_version,
            available: false,
            version: None,
            published_at: None,
            notes: None,
            size: None,
        });
    };

    let endpoint = parse_endpoint(&config.endpoint)?;
    let updater = app
        .updater_builder()
        .pubkey(config.public_key)
        .endpoints(vec![endpoint])
        .map_err(error_text)?
        .timeout(Duration::from_secs(25))
        .build()
        .map_err(error_text)?;
    let update = updater.check().await.map_err(error_text)?;

    let Some(update) = update else {
        return Ok(AppUpdateInfo {
            configured: true,
            current_version,
            available: false,
            version: None,
            published_at: None,
            notes: None,
            size: None,
        });
    };
    ensure_https_installer(&update.download_url)?;

    Ok(AppUpdateInfo {
        configured: true,
        current_version,
        available: true,
        version: Some(update.version.clone()),
        published_at: update
            .date
            .and_then(|date| rfc3339_from_unix(date.unix_timestamp())),
        notes: update.body.clone(),
        size: manifest_size(&update.raw_json, &update.target),
    })
}

pub async fn install(
    app: &AppHandle,
    config: Option<UpdateConfig>,
) -> Result<InstallUpdateResult, String> {
    let config = config.ok_or_else(|| "更新通道尚未配置".to_string())?;
    let endpoint = parse_endpoint(&config.endpoint)?;
    let updater = app
        .updater_builder()
        .pubkey(config.public_key)
        .endpoints(vec![endpoint])
        .map_err(error_text)?
        .timeout(Duration::from_secs(60 * 10))
        .build()
        .map_err(error_text)?;
    let update = updater
        .check()
        .await
        .map_err(error_text)?
        .ok_or_else(|| "当前已是最新版本".to_string())?;
    ensure_https_installer(&update.download_url)?;

    let downloaded = Arc::new(Mutex::new(0_u64));
    let chunk_handle = app.clone();
    let finish_handle = app.clone();
    let finish_downloaded = downloaded.clone();
    update
        .download_and_install(
            move |chunk_len, total| {
                let mut downloaded = downloaded.lock().unwrap();
                *downloaded += chunk_len as u64;
                let next = *downloaded;
                let _ = chunk_handle.emit(
                    PROGRESS_EVENT,
                    AppUpdateProgress {
                        phase: "downloading".to_string(),
                        downloaded: next,
                        total,
                    },
                );
            },
            move || {
                let _ = finish_handle.emit(
                    PROGRESS_EVENT,
                    AppUpdateProgress {
                        phase: "verifying".to_string(),
                        downloaded: *finish_downloaded.lock().unwrap(),
                        total: None,
                    },
                );
            },
        )
        .await
        .map_err(error_text)?;

    Ok(InstallUpdateResult {
        message: "安装器已启动，应用即将退出并自动重启".to_string(),
    })
}

fn parse_endpoint(value: &str) -> Result<Url, String> {
    let url = Url::parse(value).map_err(|error| format!("更新地址无效：{error}"))?;
    if url.scheme() != "https" {
        return Err("更新地址必须使用 HTTPS".to_string());
    }
    Ok(url)
}

fn ensure_https_installer(url: &Url) -> Result<(), String> {
    if url.scheme() != "https" {
        return Err("安装包下载地址必须使用 HTTPS".to_string());
    }
    Ok(())
}

fn manifest_size(raw_json: &serde_json::Value, target: &str) -> Option<u64> {
    let platforms = raw_json.get("platforms")?.as_object()?;
    let portable_target = target.strip_suffix("-nsis").unwrap_or(target);
    let candidates = [
        target,
        portable_target,
        "windows-x86_64-nsis",
        "windows-x86_64",
        "windows",
    ];

    candidates
        .into_iter()
        .find_map(|key| platforms.get(key))
        .or_else(|| platforms.values().find(|entry| entry.get("size").is_some()))
        .and_then(|entry| entry.get("size"))
        .and_then(serde_json::Value::as_u64)
}

fn rfc3339_from_unix(timestamp: i64) -> Option<String> {
    DateTime::<Utc>::from_timestamp(timestamp, 0)
        .map(|date| date.to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn error_text(error: impl std::fmt::Display) -> String {
    error.to_string()
}

#[cfg(test)]
mod tests {
    use super::{
        compiled_or_runtime, ensure_https_installer, manifest_size, parse_endpoint,
        rfc3339_from_unix,
    };
    use serde_json::json;

    #[test]
    fn release_configuration_takes_precedence_over_runtime_values() {
        assert_eq!(
            compiled_or_runtime(
                Some(" https://release.example/latest.json "),
                "https://local"
            ),
            "https://release.example/latest.json"
        );
        assert_eq!(
            compiled_or_runtime(Some(""), "https://local/latest.json"),
            "https://local/latest.json"
        );
    }

    #[test]
    fn reads_optional_size_from_static_manifest() {
        let manifest = json!({
            "platforms": {
                "windows-x86_64-nsis": { "size": 1234 },
                "windows-x86_64": { "size": 5678 }
            }
        });
        assert_eq!(manifest_size(&manifest, "windows-x86_64-nsis"), Some(1234));
        assert_eq!(manifest_size(&manifest, "windows-x86_64"), Some(5678));
        assert_eq!(manifest_size(&manifest, "windows"), Some(1234));
    }

    #[test]
    fn falls_back_to_the_first_platform_size() {
        let manifest = json!({
            "platforms": {
                "custom-installer": { "size": 4321 }
            }
        });
        assert_eq!(manifest_size(&manifest, "windows"), Some(4321));
    }

    #[test]
    fn formats_publish_time_as_rfc3339() {
        assert_eq!(
            rfc3339_from_unix(1_793_016_000),
            Some("2026-10-26T12:00:00Z".to_string())
        );
    }

    #[test]
    fn rejects_non_https_update_endpoints_and_installers() {
        assert!(parse_endpoint("http://updates.example.test/latest.json").is_err());
        assert!(parse_endpoint("https://updates.example.test/latest.json").is_ok());
        assert!(ensure_https_installer(
            &url::Url::parse("http://downloads.example.test/setup.exe").unwrap()
        )
        .is_err());
        assert!(ensure_https_installer(
            &url::Url::parse("https://downloads.example.test/setup.exe").unwrap()
        )
        .is_ok());
    }
}
