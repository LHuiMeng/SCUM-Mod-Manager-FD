fn main() {
    let edition = std::env::var("SCUM_EDITION")
        .unwrap_or_else(|_| "server".to_string())
        .trim()
        .to_ascii_lowercase();
    if edition != "public" && edition != "server" {
        panic!("SCUM_EDITION must be either public or server");
    }
    println!("cargo:rustc-env=SCUM_EDITION={edition}");
    println!("cargo:rerun-if-env-changed=SCUM_EDITION");
    tauri_build::build()
}
