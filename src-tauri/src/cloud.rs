use crate::edition;
use crate::models::{AppSettings, RemoteMod};
use crate::mods::extract_zip_file;
use crate::paths::{safe_file_component, AppPaths};
use crate::secrets::RuntimeSecrets;
use anyhow::{bail, Context, Result};
use chrono::Utc;
use futures_util::StreamExt;
use percent_encoding::percent_decode_str;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::Path;
use tokio::io::AsyncWriteExt;
use url::Url;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloudAccess {
    Public,
    Server,
}

impl CloudAccess {
    pub fn current() -> Self {
        match edition::current() {
            edition::Edition::Public => Self::Public,
            edition::Edition::Server => Self::Server,
        }
    }
}

pub async fn fetch_catalog(
    paths: &AppPaths,
    settings: &mut AppSettings,
    secrets: &RuntimeSecrets,
    access: CloudAccess,
) -> Result<Vec<RemoteMod>> {
    let urls = ordered_urls(settings);
    if urls.is_empty() {
        bail!("尚未配置云源地址");
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(25))
        .user_agent(format!("SCUM-Mod-Desk/{}", env!("CARGO_PKG_VERSION")))
        .build()?;
    let mut errors = Vec::new();
    for base in urls {
        let url = format!("{}/mods", base.trim_end_matches('/'));
        let request = authorize_cloud_request(client.get(&url), secrets, access);
        match request.send().await {
            Ok(response) => {
                if !response.status().is_success() {
                    errors.push(format!("{url}: HTTP {}", response.status()));
                    continue;
                }
                match response.json::<Value>().await {
                    Ok(value) => {
                        settings.cloud.active_base_url = base.clone();
                        return parse_catalog(paths, &base, value);
                    }
                    Err(error) => errors.push(format!("{url}: {error}")),
                }
            }
            Err(error) => errors.push(format!("{url}: {error}")),
        }
    }
    bail!("所有云源线路均不可用：{}", errors.join("；"))
}

pub async fn download_remote(
    paths: &AppPaths,
    settings: &mut AppSettings,
    secrets: &RuntimeSecrets,
    access: CloudAccess,
    id: &str,
) -> Result<String> {
    let catalog = fetch_catalog(paths, settings, secrets, access).await?;
    let remote = catalog
        .iter()
        .find(|item| item.id == id)
        .with_context(|| format!("云端目录中不存在模组 {id}"))?;
    let filename = remote_filename(remote);
    let temp = paths
        .root
        .join("downloads")
        .join(format!("{}.part", safe_file_component(id)));
    if let Some(parent) = temp.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(600))
        .user_agent(format!("SCUM-Mod-Desk/{}", env!("CARGO_PKG_VERSION")))
        .build()?;
    let mut candidates = download_candidates(settings, remote);
    candidates.dedup();
    let mut errors = Vec::new();
    for url in candidates {
        let request = authorize_cloud_request(client.get(&url), secrets, access);
        let response = match request.send().await {
            Ok(response) if response.status().is_success() => response,
            Ok(response) => {
                errors.push(format!("{url}: HTTP {}", response.status()));
                continue;
            }
            Err(error) => {
                errors.push(format!("{url}: {error}"));
                continue;
            }
        };
        let mut file = tokio::fs::File::create(&temp).await?;
        let mut stream = response.bytes_stream();
        let mut hasher = Sha256::new();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            hasher.update(&chunk);
            file.write_all(&chunk).await?;
        }
        file.flush().await?;
        let digest = hex::encode(hasher.finalize());
        if !remote.sha256.trim().is_empty() && !digest.eq_ignore_ascii_case(remote.sha256.trim()) {
            let _ = tokio::fs::remove_file(&temp).await;
            errors.push(format!("{url}: SHA-256 校验失败"));
            continue;
        }

        if remote.mod_type == "ue4ssMod" {
            let destination = paths.ue4ss_mods.join(safe_file_component(&remote.name));
            tokio::fs::create_dir_all(&destination).await?;
            tokio::task::spawn_blocking({
                let temp = temp.clone();
                let destination = destination.clone();
                move || extract_zip_file(&temp, &destination)
            })
            .await
            .context("解压任务异常")??;
            let _ = tokio::fs::remove_file(&temp).await;
            return Ok(format!("{} 已下载并解压到 UE4SS 模组目录", remote.name));
        }

        tokio::fs::create_dir_all(&paths.local_mods).await?;
        let destination = paths.local_mods.join(filename);
        if tokio::fs::try_exists(&destination).await.unwrap_or(false) {
            let _ = tokio::fs::remove_file(&destination).await;
        }
        tokio::fs::rename(&temp, &destination).await?;
        return Ok(format!("{} 已下载并通过校验", remote.name));
    }
    let _ = tokio::fs::remove_file(&temp).await;
    bail!("下载失败：{}", errors.join("；"))
}

fn authorize_cloud_request(
    mut request: reqwest::RequestBuilder,
    secrets: &RuntimeSecrets,
    access: CloudAccess,
) -> reqwest::RequestBuilder {
    if access != CloudAccess::Server {
        return request;
    }
    let token = secrets.cloud_auth_token.trim();
    if !token.is_empty() {
        request = request.bearer_auth(token).header("X-Scum-Gate", token);
    }
    request
}

fn ordered_urls(settings: &AppSettings) -> Vec<String> {
    let mut urls = Vec::new();
    if !settings.cloud.active_base_url.trim().is_empty() {
        urls.push(settings.cloud.active_base_url.trim().to_string());
    }
    urls.extend(settings.cloud.base_urls.iter().cloned());
    let mut seen = HashSet::new();
    urls.into_iter()
        .map(|url| url.trim_end_matches('/').to_string())
        .filter(|url| !url.is_empty() && seen.insert(url.clone()))
        .collect()
}

fn parse_catalog(paths: &AppPaths, base: &str, value: Value) -> Result<Vec<RemoteMod>> {
    let items = value
        .get("mods")
        .or_else(|| value.get("items"))
        .or_else(|| value.get("catalog"))
        .and_then(Value::as_array)
        .cloned()
        .or_else(|| value.as_array().cloned())
        .unwrap_or_default();
    let installed = installed_names(paths);
    let mut mods = Vec::new();
    for item in items {
        let Some(object) = item.as_object() else {
            continue;
        };
        let name = text(object.get("name")).unwrap_or_else(|| "未命名模组".to_string());
        let id = text(object.get("id"))
            .or_else(|| text(object.get("slug")))
            .unwrap_or_else(|| safe_file_component(&name));
        let mut download_url = text(object.get("download_url"))
            .or_else(|| text(object.get("downloadUrl")))
            .unwrap_or_default();
        if download_url.is_empty() {
            download_url = format!("{}/mods/{}/download", base.trim_end_matches('/'), id);
        }
        let tags = object
            .get("tags")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(ToString::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let file_size = number(object.get("file_size"))
            .or_else(|| number(object.get("fileSize")))
            .or_else(|| number(object.get("size")))
            .unwrap_or(0);
        let mod_type = text(object.get("type"))
            .or_else(|| text(object.get("mod_type")))
            .unwrap_or_else(|| "clientPak".to_string());
        mods.push(RemoteMod {
            installed: installed.contains(&id.to_ascii_lowercase())
                || installed.contains(&name.to_ascii_lowercase()),
            id,
            name,
            author: text(object.get("author")).unwrap_or_else(|| "未知作者".to_string()),
            version: text(object.get("version")).unwrap_or_else(|| "1.0.0".to_string()),
            description: text(object.get("description")).unwrap_or_default(),
            file_size,
            download_url,
            sha256: text(object.get("sha256")).unwrap_or_default(),
            tags,
            updated_at: text(object.get("updated_at"))
                .or_else(|| text(object.get("updatedAt")))
                .unwrap_or_else(|| Utc::now().to_rfc3339()),
            mod_type,
        });
    }
    Ok(mods)
}

fn installed_names(paths: &AppPaths) -> HashSet<String> {
    let mut names = HashSet::new();
    if let Ok(entries) = std::fs::read_dir(&paths.local_mods) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            names.insert(name.to_ascii_lowercase());
            if let Some(stem) = Path::new(&name).file_stem() {
                names.insert(stem.to_string_lossy().to_ascii_lowercase());
            }
        }
    }
    if let Ok(entries) = std::fs::read_dir(&paths.ue4ss_mods) {
        for entry in entries.flatten() {
            names.insert(entry.file_name().to_string_lossy().to_ascii_lowercase());
        }
    }
    names
}

fn download_candidates(settings: &AppSettings, remote: &RemoteMod) -> Vec<String> {
    let mut candidates = Vec::new();
    if !remote.download_url.trim().is_empty() {
        candidates.push(remote.download_url.trim().to_string());
    }
    for base in ordered_urls(settings) {
        candidates.push(format!(
            "{}/mods/{}/download",
            base.trim_end_matches('/'),
            remote.id
        ));
    }
    candidates
}

fn remote_filename(remote: &RemoteMod) -> String {
    if let Ok(url) = Url::parse(&remote.download_url) {
        if let Some(encoded_name) = url
            .path_segments()
            .and_then(|mut segments| segments.next_back())
        {
            let decoded = percent_decode_str(encoded_name).decode_utf8_lossy();
            if decoded.contains('.') {
                if let Some(name) = safe_download_filename(&decoded) {
                    return name;
                }
            }
        }
    }
    let extension = if remote.mod_type == "ue4ssMod" {
        "zip"
    } else {
        "pak"
    };
    format!("{}.{}", safe_file_component(&remote.name), extension)
}

fn safe_download_filename(value: &str) -> Option<String> {
    let file_name = Path::new(value).file_name()?.to_string_lossy();
    let path = Path::new(file_name.as_ref());
    let stem = path.file_stem()?.to_string_lossy();
    let safe_stem = safe_file_component(&stem);
    match path.extension() {
        Some(extension) if !extension.is_empty() => Some(format!(
            "{safe_stem}.{}",
            safe_file_component(&extension.to_string_lossy()).to_ascii_lowercase()
        )),
        _ => Some(safe_stem),
    }
}

fn text(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn number(value: Option<&Value>) -> Option<u64> {
    value.and_then(|value| {
        value
            .as_u64()
            .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
    })
}

#[cfg(test)]
mod tests {
    use super::{
        download_remote, ordered_urls, parse_catalog, remote_filename, AppSettings, CloudAccess,
        RuntimeSecrets,
    };
    use crate::models::RemoteMod;
    use crate::test_support::TempRoot;
    use serde_json::json;
    use sha2::{Digest, Sha256};
    use std::collections::HashMap;
    use std::fs;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;
    use std::time::Duration;

    #[derive(Debug)]
    struct CapturedRequest {
        path: String,
        headers: HashMap<String, String>,
    }

    struct MockServer {
        base_url: String,
        handle: Option<thread::JoinHandle<Vec<CapturedRequest>>>,
    }

    impl MockServer {
        fn new(expected_sha256: String, download_status: u16) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let base_url = format!("http://{address}");
            let catalog = serde_json::to_vec(&json!({
                "mods": [{
                    "id": "demo",
                    "name": "Demo",
                    "type": "clientPak",
                    "sha256": expected_sha256
                }]
            }))
            .unwrap();
            let file_body = b"mock-pak-content".to_vec();
            let handle = thread::spawn(move || {
                let mut captured = Vec::new();
                for _ in 0..2 {
                    let (mut stream, _) = listener.accept().unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut request = Vec::new();
                    let mut buffer = [0_u8; 4096];
                    loop {
                        match stream.read(&mut buffer) {
                            Ok(0) => break,
                            Ok(read) => {
                                request.extend_from_slice(&buffer[..read]);
                                if request.windows(4).any(|window| window == b"\r\n\r\n") {
                                    break;
                                }
                            }
                            Err(_) => break,
                        }
                    }
                    let request_text = String::from_utf8_lossy(&request);
                    let mut lines = request_text.lines();
                    let path = lines
                        .next()
                        .and_then(|line| line.split_whitespace().nth(1))
                        .unwrap_or_default()
                        .to_string();
                    let headers = lines
                        .take_while(|line| !line.trim().is_empty())
                        .filter_map(|line| line.split_once(':'))
                        .map(|(name, value)| {
                            (name.trim().to_ascii_lowercase(), value.trim().to_string())
                        })
                        .collect::<HashMap<_, _>>();
                    captured.push(CapturedRequest {
                        path: path.clone(),
                        headers,
                    });

                    let (status, content_type, body) = if path == "/mods" {
                        (200_u16, "application/json", catalog.as_slice())
                    } else if download_status == 200 {
                        (200_u16, "application/octet-stream", file_body.as_slice())
                    } else {
                        (download_status, "text/plain", b"forbidden".as_slice())
                    };
                    let header = format!(
                        "HTTP/1.1 {status} {}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        if status == 200 { "OK" } else { "Forbidden" },
                        body.len()
                    );
                    stream.write_all(header.as_bytes()).unwrap();
                    stream.write_all(body).unwrap();
                }
                captured
            });
            Self {
                base_url,
                handle: Some(handle),
            }
        }

        fn finish(mut self) -> Vec<CapturedRequest> {
            self.handle.take().unwrap().join().unwrap()
        }
    }

    fn file_sha256() -> String {
        hex::encode(Sha256::digest(b"mock-pak-content"))
    }

    #[test]
    fn parses_catalog_aliases_defaults_and_installed_state() {
        let temp = TempRoot::new("cloud-catalog");
        let paths = temp.paths();
        fs::write(paths.local_mods.join("InstalledWeapon.pak"), b"pak").unwrap();
        fs::create_dir_all(paths.ue4ss_mods.join("ScriptPack")).unwrap();
        let value = json!({
            "items": [{
                "name": "InstalledWeapon",
                "slug": "installed-weapon",
                "author": "Tester",
                "version": "2.0.0",
                "fileSize": "4096",
                "sha256": "ABC123",
                "tags": ["weapon", 7],
                "updatedAt": "2026-10-26T00:00:00Z",
                "type": "clientPak"
            }, {
                "id": "script-pack",
                "name": "ScriptPack",
                "mod_type": "ue4ssMod"
            }]
        });

        let mods = parse_catalog(&paths, "https://mods.example.test/", value).unwrap();

        assert_eq!(mods.len(), 2);
        assert_eq!(mods[0].id, "installed-weapon");
        assert!(mods[0].installed);
        assert_eq!(mods[0].file_size, 4096);
        assert_eq!(mods[0].tags, vec!["weapon"]);
        assert_eq!(
            mods[0].download_url,
            "https://mods.example.test/mods/installed-weapon/download"
        );
        assert!(mods[1].installed);
        assert_eq!(mods[1].mod_type, "ue4ssMod");
    }

    #[test]
    fn orders_active_cloud_source_first_and_removes_duplicates() {
        let settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![
                    "https://backup.example/".to_string(),
                    "https://primary.example/".to_string(),
                ],
                active_base_url: "https://primary.example".to_string(),
            },
            ..AppSettings::default()
        };

        assert_eq!(
            ordered_urls(&settings),
            vec!["https://primary.example", "https://backup.example"]
        );
    }

    #[test]
    fn derives_a_safe_filename_from_remote_metadata() {
        let remote = RemoteMod {
            id: "demo".to_string(),
            name: "../Unsafe Demo".to_string(),
            author: String::new(),
            version: String::new(),
            description: String::new(),
            file_size: 0,
            download_url: "https://mods.example.test/files/Unsafe%20Demo.pak?token=redacted"
                .to_string(),
            sha256: String::new(),
            tags: Vec::new(),
            updated_at: String::new(),
            mod_type: "clientPak".to_string(),
            installed: false,
        };

        assert_eq!(remote_filename(&remote), "Unsafe_Demo.pak");
    }

    #[test]
    fn downloads_and_verifies_sha256_through_the_cloud_catalog() {
        let temp = TempRoot::new("cloud-download-success");
        let paths = temp.paths();
        let server = MockServer::new(file_sha256(), 200);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
            },
            ..AppSettings::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        let result = runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &RuntimeSecrets::default(),
                CloudAccess::Server,
                "demo",
            ))
            .unwrap();

        assert!(result.contains("通过校验"));
        assert_eq!(
            fs::read(paths.local_mods.join("Demo.pak")).unwrap(),
            b"mock-pak-content"
        );
        assert_eq!(settings.cloud.active_base_url, server.base_url);
        assert_eq!(server.finish().len(), 2);
    }

    #[test]
    fn rejects_a_remote_file_with_the_wrong_sha256() {
        let temp = TempRoot::new("cloud-download-sha-mismatch");
        let paths = temp.paths();
        let server = MockServer::new("00".to_string(), 200);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
            },
            ..AppSettings::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        let error = runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &RuntimeSecrets::default(),
                CloudAccess::Server,
                "demo",
            ))
            .unwrap_err();

        assert!(
            error.to_string().contains("SHA-256"),
            "unexpected download error: {error:#}"
        );
        assert!(!paths.local_mods.join("Demo.pak").exists());
        assert_eq!(server.finish().len(), 2);
    }

    #[test]
    fn server_edition_sends_the_same_shared_key_in_both_headers() {
        let temp = TempRoot::new("cloud-server-auth");
        let paths = temp.paths();
        let server = MockServer::new(file_sha256(), 200);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
            },
            ..AppSettings::default()
        };
        let secrets = RuntimeSecrets {
            cloud_auth_token: "unit-test-shared-key".to_string(),
            ..RuntimeSecrets::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &secrets,
                CloudAccess::Server,
                "demo",
            ))
            .unwrap();

        let requests = server.finish();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0].path, "/mods");
        assert!(requests[1].path.ends_with("/mods/demo/download"));
        for request in requests {
            assert_eq!(
                request.headers.get("authorization").map(String::as_str),
                Some("Bearer unit-test-shared-key")
            );
            assert_eq!(
                request.headers.get("x-scum-gate").map(String::as_str),
                Some("unit-test-shared-key")
            );
        }
    }

    #[test]
    fn public_edition_never_sends_cloud_credentials() {
        let temp = TempRoot::new("cloud-public-auth");
        let paths = temp.paths();
        let server = MockServer::new(file_sha256(), 200);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
            },
            ..AppSettings::default()
        };
        let secrets = RuntimeSecrets {
            cloud_auth_token: "must-not-leak".to_string(),
            ..RuntimeSecrets::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &secrets,
                CloudAccess::Public,
                "demo",
            ))
            .unwrap();

        for request in server.finish() {
            assert!(!request.headers.contains_key("authorization"));
            assert!(!request.headers.contains_key("x-scum-gate"));
        }
    }

    #[test]
    fn reports_a_private_download_http_error_without_overwriting_it() {
        let temp = TempRoot::new("cloud-download-forbidden");
        let paths = temp.paths();
        let server = MockServer::new(file_sha256(), 403);
        let mut settings = AppSettings {
            cloud: crate::models::CloudSettings {
                base_urls: vec![server.base_url.clone()],
                active_base_url: String::new(),
            },
            ..AppSettings::default()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        let error = runtime
            .block_on(download_remote(
                &paths,
                &mut settings,
                &RuntimeSecrets {
                    cloud_auth_token: "wrong-key".to_string(),
                    ..RuntimeSecrets::default()
                },
                CloudAccess::Server,
                "demo",
            ))
            .unwrap_err()
            .to_string();

        assert!(error.contains("HTTP 403"), "unexpected error: {error}");
        assert!(!error.contains("SHA-256"), "unexpected error: {error}");
        assert!(!paths.local_mods.join("Demo.pak").exists());
        assert_eq!(server.finish().len(), 2);
    }
}
