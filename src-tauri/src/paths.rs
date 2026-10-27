use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

#[derive(Debug, Clone)]
pub struct AppPaths {
    pub root: PathBuf,
    pub secrets: PathBuf,
    pub local_mods: PathBuf,
    pub ue4ss_runtime: PathBuf,
    pub ue4ss_mods: PathBuf,
    pub config_file: PathBuf,
    pub metadata_file: PathBuf,
    pub deployment_manifest: PathBuf,
    pub logs_dir: PathBuf,
    resource_dir: PathBuf,
}

impl AppPaths {
    pub fn init(app: &AppHandle) -> Result<Self> {
        let exe_dir = std::env::current_exe()
            .context("无法定位当前程序")?
            .parent()
            .context("无法定位程序目录")?
            .to_path_buf();

        let root_override = std::env::var("SCUM_MM_ROOT").ok();
        let root = resolve_data_root(&exe_dir, root_override.as_deref());

        let resource_dir = app
            .path()
            .resource_dir()
            .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")));

        let paths = Self {
            secrets: root.join("secrets"),
            local_mods: root.join("~mods"),
            ue4ss_runtime: root.join("ue4ss_runtime"),
            ue4ss_mods: root.join("ue4ss_runtime").join("ue4ss").join("Mods"),
            config_file: root.join("config.json"),
            metadata_file: root.join("mods_meta.json"),
            deployment_manifest: root.join("deployment_manifest.json"),
            logs_dir: root.join("logs"),
            resource_dir,
            root,
        };
        paths.ensure()?;
        Ok(paths)
    }

    fn ensure(&self) -> Result<()> {
        std::fs::create_dir_all(&self.root).with_context(|| {
            format!(
                "无法创建数据目录 {}。请将程序放在非 C 盘的可写目录，例如 R:\\SCUM Mod Desk，而不是 Program Files。",
                self.root.display()
            )
        })?;
        let probe = self
            .root
            .join(format!(".write-probe-{}", std::process::id()));
        std::fs::write(&probe, b"ok").with_context(|| {
            format!(
                "数据目录不可写：{}。请将程序移动到非 C 盘的可写目录。",
                self.root.display()
            )
        })?;
        let _ = std::fs::remove_file(probe);
        std::fs::create_dir_all(&self.secrets)
            .with_context(|| format!("无法创建凭据目录 {}", self.secrets.display()))?;
        std::fs::create_dir_all(&self.local_mods)
            .with_context(|| format!("无法创建模组目录 {}", self.local_mods.display()))?;
        std::fs::create_dir_all(&self.ue4ss_mods)
            .with_context(|| format!("无法创建 UE4SS 目录 {}", self.ue4ss_mods.display()))?;
        std::fs::create_dir_all(&self.logs_dir)
            .with_context(|| format!("无法创建日志目录 {}", self.logs_dir.display()))?;
        Ok(())
    }

    pub fn resource(&self, name: &str) -> PathBuf {
        let bundled = self.resource_dir.join("resources").join(name);
        if bundled.exists() {
            return bundled;
        }
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join(name)
    }

    pub fn sftp_secret(&self, account_id: &str) -> PathBuf {
        self.secrets
            .join("sftp")
            .join(format!("{}.bin", safe_file_component(account_id)))
    }

    pub fn bundled_runtime_secret(&self) -> PathBuf {
        self.resource_dir
            .join("runtime-secrets")
            .join("runtime.toml")
    }
}

fn resolve_data_root(exe_dir: &Path, override_value: Option<&str>) -> PathBuf {
    override_value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| exe_dir.join("app-data"))
}

#[cfg(test)]
impl AppPaths {
    pub(crate) fn for_test(root: PathBuf) -> Self {
        Self {
            secrets: root.join("secrets"),
            local_mods: root.join("~mods"),
            ue4ss_runtime: root.join("ue4ss_runtime"),
            ue4ss_mods: root.join("ue4ss_runtime").join("ue4ss").join("Mods"),
            config_file: root.join("config.json"),
            metadata_file: root.join("mods_meta.json"),
            deployment_manifest: root.join("deployment_manifest.json"),
            logs_dir: root.join("logs"),
            resource_dir: root.clone(),
            root,
        }
    }
}

pub fn safe_file_component(value: &str) -> String {
    let cleaned: String = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "item".to_string()
    } else {
        cleaned
    }
}

pub fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

pub fn is_within(path: &Path, root: &Path) -> bool {
    let normalized_path = normalize_for_compare(path);
    let normalized_root = normalize_for_compare(root);
    normalized_path == normalized_root || normalized_path.starts_with(&(normalized_root + "\\"))
}

fn normalize_for_compare(path: &Path) -> String {
    std::path::absolute(path)
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .replace('/', "\\")
        .trim_end_matches('\\')
        .to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::{is_within, resolve_data_root, safe_file_component};
    use std::path::{Path, PathBuf};

    #[test]
    fn default_data_root_stays_next_to_the_program() {
        let exe_dir = Path::new(r"R:\SCUM Mod Desk");
        assert_eq!(
            resolve_data_root(exe_dir, None),
            PathBuf::from(r"R:\SCUM Mod Desk\app-data")
        );
        assert_eq!(
            resolve_data_root(exe_dir, Some("  ")),
            PathBuf::from(r"R:\SCUM Mod Desk\app-data")
        );
    }

    #[test]
    fn data_root_override_is_respected() {
        assert_eq!(
            resolve_data_root(Path::new(r"R:\SCUM Mod Desk"), Some(r"W:\portable-data")),
            PathBuf::from(r"W:\portable-data")
        );
    }

    #[test]
    fn sanitizes_untrusted_file_components() {
        assert_eq!(safe_file_component("../evil name.pak"), "___evil_name_pak");
        assert_eq!(safe_file_component(""), "item");
    }

    #[test]
    fn containment_check_handles_windows_separators() {
        assert!(is_within(
            Path::new(r"W:\SCUM\Paks\mod.pak"),
            Path::new(r"W:\SCUM")
        ));
        assert!(!is_within(
            Path::new(r"W:\SCUM2\Paks\mod.pak"),
            Path::new(r"W:\SCUM")
        ));
    }

    #[test]
    fn containment_check_rejects_parent_directory_escape() {
        assert!(!is_within(
            Path::new(r"W:\SCUM\..\Outside\mod.pak"),
            Path::new(r"W:\SCUM")
        ));
    }
}
