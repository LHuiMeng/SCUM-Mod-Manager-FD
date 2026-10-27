use crate::edition::Edition;
use crate::paths::AppPaths;
use anyhow::{Context, Result};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

const PACKAGED_CLOUD_BASE_URLS_JSON: &str = env!("SCUM_PACKAGED_CLOUD_BASE_URLS_JSON");

#[derive(Debug, Clone, Default)]
pub struct RuntimeSecrets {
    pub cloud_base_urls: Vec<String>,
    pub cloud_auth_token: String,
    pub update_endpoint: String,
    pub update_public_key: String,
}

pub fn load_runtime_secrets(paths: &AppPaths, edition: Edition) -> RuntimeSecrets {
    let text = secret_candidates(paths)
        .into_iter()
        .find_map(|path| std::fs::read_to_string(path).ok());
    parse_runtime_secrets(text.as_deref(), edition, packaged_cloud_base_urls())
}

fn parse_runtime_secrets(
    text: Option<&str>,
    edition: Edition,
    packaged_cloud_base_urls: Vec<String>,
) -> RuntimeSecrets {
    let value = text.and_then(|text| text.parse::<toml::Value>().ok());
    let cloud = value.as_ref().and_then(|value| value.get("cloud"));
    let update = value.as_ref().and_then(|value| value.get("update"));
    let cloud_base_urls = cloud
        .and_then(cloud_base_urls_from_toml)
        .unwrap_or_else(|| normalize_cloud_base_urls(packaged_cloud_base_urls));
    let mut cloud_auth_token = ["auth_token", "catalog_token", "gate_token"]
        .into_iter()
        .find_map(|key| {
            cloud
                .and_then(|item| item.get(key))
                .and_then(toml::Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
        })
        .unwrap_or_default()
        .to_string();
    if edition == Edition::Public {
        cloud_auth_token.clear();
    }
    RuntimeSecrets {
        cloud_base_urls,
        cloud_auth_token,
        update_endpoint: update
            .and_then(|item| item.get("endpoint"))
            .and_then(toml::Value::as_str)
            .unwrap_or_default()
            .to_string(),
        update_public_key: update
            .and_then(|item| item.get("public_key"))
            .and_then(toml::Value::as_str)
            .unwrap_or_default()
            .to_string(),
    }
}

fn packaged_cloud_base_urls() -> Vec<String> {
    serde_json::from_str::<Vec<String>>(PACKAGED_CLOUD_BASE_URLS_JSON).unwrap_or_default()
}

fn cloud_base_urls_from_toml(cloud: &toml::Value) -> Option<Vec<String>> {
    if let Some(items) = cloud.get("base_urls").and_then(toml::Value::as_array) {
        let urls = normalize_cloud_base_urls(
            items
                .iter()
                .filter_map(toml::Value::as_str)
                .map(ToString::to_string),
        );
        return (!urls.is_empty()).then_some(urls);
    }
    cloud
        .get("base_url")
        .and_then(toml::Value::as_str)
        .map(|url| normalize_cloud_base_urls([url.to_string()]))
        .filter(|urls| !urls.is_empty())
}

fn normalize_cloud_base_urls(urls: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut seen = HashSet::new();
    urls.into_iter()
        .filter_map(|url| crate::config::normalize_cloud_url(&url))
        .filter(|url| seen.insert(url.to_ascii_lowercase()))
        .collect()
}

fn secret_candidates(paths: &AppPaths) -> Vec<PathBuf> {
    let mut candidates = vec![
        paths.secrets.join("runtime.toml"),
        paths.bundled_runtime_secret(),
    ];
    if cfg!(debug_assertions) {
        candidates.push(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("..")
                .join("secrets")
                .join("runtime.toml"),
        );
    }
    candidates
}

pub fn write_secret(path: &Path, plaintext: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let encrypted = protect(plaintext.as_bytes())?;
    std::fs::write(path, encrypted)
        .with_context(|| format!("无法写入密钥文件 {}", path.display()))?;
    Ok(())
}

pub fn read_secret(path: &Path) -> Result<String> {
    let encrypted =
        std::fs::read(path).with_context(|| format!("无法读取密钥文件 {}", path.display()))?;
    let plaintext = unprotect(&encrypted)?;
    String::from_utf8(plaintext).context("解密后的凭据不是有效 UTF-8")
}

#[cfg(windows)]
pub fn unprotect_for_migration(input: &[u8]) -> Result<Vec<u8>> {
    unprotect(input)
}

#[cfg(windows)]
fn protect(input: &[u8]) -> Result<Vec<u8>> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    let in_blob = CRYPT_INTEGER_BLOB {
        cbData: input.len() as u32,
        pbData: input.as_ptr() as *mut u8,
    };
    let mut out_blob = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptProtectData(
            &in_blob,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out_blob,
        )
    };
    if ok == 0 {
        return Err(std::io::Error::last_os_error()).context("Windows DPAPI 加密失败");
    }
    let result =
        unsafe { std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize) }.to_vec();
    unsafe {
        LocalFree(out_blob.pbData as _);
    }
    Ok(result)
}

#[cfg(windows)]
fn unprotect(input: &[u8]) -> Result<Vec<u8>> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    let in_blob = CRYPT_INTEGER_BLOB {
        cbData: input.len() as u32,
        pbData: input.as_ptr() as *mut u8,
    };
    let mut out_blob = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptUnprotectData(
            &in_blob,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out_blob,
        )
    };
    if ok == 0 {
        return Err(std::io::Error::last_os_error()).context("Windows DPAPI 解密失败");
    }
    let result =
        unsafe { std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize) }.to_vec();
    unsafe {
        LocalFree(out_blob.pbData as _);
    }
    Ok(result)
}

#[cfg(not(windows))]
fn protect(_input: &[u8]) -> Result<Vec<u8>> {
    anyhow::bail!("当前平台不支持 Windows DPAPI")
}

#[cfg(not(windows))]
fn unprotect(_input: &[u8]) -> Result<Vec<u8>> {
    anyhow::bail!("当前平台不支持 Windows DPAPI")
}

#[cfg(test)]
mod tests {
    use super::{load_runtime_secrets, parse_runtime_secrets, read_secret, write_secret};
    use crate::edition::Edition;
    use crate::test_support::TempRoot;
    use std::fs;

    #[test]
    fn loads_runtime_configuration_from_the_isolated_secrets_directory() {
        let temp = TempRoot::new("runtime-secrets");
        let paths = temp.paths();
        fs::write(
            paths.secrets.join("runtime.toml"),
            concat!(
                "[cloud]\n",
                "base_urls = [\"https://catalog.example.test/\", \"ftp://invalid.example.test\"]\n",
                "auth_token = \"unit-test-auth-token\"\n",
                "catalog_token = \"unit-test-catalog-token\"\n",
                "gate_token = \"unit-test-gate-token\"\n",
                "[update]\n",
                "endpoint = \"https://updates.example.test/latest.json\"\n",
                "public_key = \"unit-test-public-key\"\n"
            ),
        )
        .unwrap();

        let secrets = load_runtime_secrets(&paths, Edition::Server);

        assert_eq!(
            secrets.cloud_base_urls,
            vec!["https://catalog.example.test"]
        );
        assert_eq!(secrets.cloud_auth_token, "unit-test-auth-token");
        assert_eq!(
            secrets.update_endpoint,
            "https://updates.example.test/latest.json"
        );
        assert_eq!(secrets.update_public_key, "unit-test-public-key");
    }

    #[test]
    fn reads_the_legacy_gate_token_when_auth_token_is_absent() {
        let temp = TempRoot::new("runtime-legacy-secrets");
        let paths = temp.paths();
        fs::write(
            paths.secrets.join("runtime.toml"),
            "[cloud]\ngate_token = \"unit-test-legacy-token\"\n",
        )
        .unwrap();

        let secrets = load_runtime_secrets(&paths, Edition::Server);

        assert_eq!(secrets.cloud_auth_token, "unit-test-legacy-token");
    }

    #[test]
    fn public_edition_never_loads_the_cloud_shared_key() {
        let temp = TempRoot::new("runtime-public-secrets");
        let paths = temp.paths();
        fs::write(
            paths.secrets.join("runtime.toml"),
            concat!(
                "[cloud]\n",
                "auth_token = \"unit-test-private-token\"\n",
                "[update]\n",
                "endpoint = \"https://updates.example.test/latest.json\"\n"
            ),
        )
        .unwrap();

        let secrets = load_runtime_secrets(&paths, Edition::Public);

        assert!(secrets.cloud_auth_token.is_empty());
        assert_eq!(
            secrets.update_endpoint,
            "https://updates.example.test/latest.json"
        );
    }

    #[test]
    fn packaged_cloud_sources_are_used_when_runtime_config_omits_them() {
        let secrets = parse_runtime_secrets(
            Some("[cloud]\nauth_token = \"unit-test-token\"\n"),
            Edition::Public,
            vec![
                "https://primary.example.test/".to_string(),
                "https://primary.example.test".to_string(),
                "http://insecure.example.test".to_string(),
            ],
        );

        assert_eq!(
            secrets.cloud_base_urls,
            vec!["https://primary.example.test"]
        );
        assert!(secrets.cloud_auth_token.is_empty());
    }

    #[test]
    fn packaged_cloud_sources_are_used_when_runtime_source_list_is_empty() {
        let secrets = parse_runtime_secrets(
            Some("[cloud]\nbase_urls = []\n"),
            Edition::Public,
            vec!["https://packaged.example.test".to_string()],
        );

        assert_eq!(
            secrets.cloud_base_urls,
            vec!["https://packaged.example.test"]
        );
    }

    #[test]
    fn runtime_cloud_sources_override_packaged_defaults() {
        let secrets = parse_runtime_secrets(
            Some("[cloud]\nbase_urls = [\"https://runtime.example.test\"]\n"),
            Edition::Server,
            vec!["https://packaged.example.test".to_string()],
        );

        assert_eq!(
            secrets.cloud_base_urls,
            vec!["https://runtime.example.test"]
        );
    }

    #[cfg(windows)]
    #[test]
    fn dpapi_round_trip_keeps_plaintext_out_of_the_secret_file() {
        let temp = TempRoot::new("dpapi-round-trip");
        let paths = temp.paths();
        let secret = paths.sftp_secret("test-account");
        let plaintext = "unit-test-dpapi-password";

        write_secret(&secret, plaintext).unwrap();

        assert_eq!(read_secret(&secret).unwrap(), plaintext);
        let encrypted = fs::read(&secret).unwrap();
        assert!(!encrypted
            .windows(plaintext.len())
            .any(|window| window == plaintext.as_bytes()));
    }
}
