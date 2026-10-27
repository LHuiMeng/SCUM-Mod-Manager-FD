use std::path::Path;

fn main() {
    let edition = std::env::var("SCUM_EDITION")
        .unwrap_or_else(|_| "public".to_string())
        .trim()
        .to_ascii_lowercase();
    if edition != "public" && edition != "server" {
        panic!("SCUM_EDITION must be either public or server");
    }
    println!("cargo:rustc-env=SCUM_EDITION={edition}");
    println!("cargo:rerun-if-env-changed=SCUM_EDITION");

    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is required");
    let runtime_secrets = Path::new(&manifest_dir)
        .join("..")
        .join("secrets")
        .join("runtime.toml");
    println!("cargo:rerun-if-changed={}", runtime_secrets.display());
    let cloud_base_urls = read_cloud_base_urls(&runtime_secrets);
    println!(
        "cargo:rustc-env=SCUM_PACKAGED_CLOUD_BASE_URLS_JSON={}",
        serde_json::to_string(&cloud_base_urls).expect("cloud source list should serialize")
    );

    tauri_build::build()
}

fn read_cloud_base_urls(path: &Path) -> Vec<String> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let value: toml::Value = text
        .parse()
        .unwrap_or_else(|error| panic!("无法解析 {}: {error}", path.display()));
    let Some(cloud) = value.get("cloud") else {
        return Vec::new();
    };
    if let Some(items) = cloud.get("base_urls").and_then(toml::Value::as_array) {
        return items
            .iter()
            .filter_map(toml::Value::as_str)
            .map(str::trim)
            .filter(|url| !url.is_empty())
            .map(ToString::to_string)
            .collect();
    }
    cloud
        .get("base_url")
        .and_then(toml::Value::as_str)
        .map(str::trim)
        .filter(|url| !url.is_empty())
        .map(|url| vec![url.to_string()])
        .unwrap_or_default()
}
