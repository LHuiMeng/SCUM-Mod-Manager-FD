use anyhow::{Context, Result};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};
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
    pub locales_dir: PathBuf,
    pub deployment_manifest: PathBuf,
    pub logs_dir: PathBuf,
    pub sftp_known_hosts: PathBuf,
    pub sftp_remote_notes: PathBuf,
    pub backups_dir: PathBuf,
    resource_dir: PathBuf,
}

impl AppPaths {
    pub fn init(app: &AppHandle) -> Result<Self> {
        let exe_dir = std::env::current_exe()
            .context("无法定位当前程序")?
            .parent()
            .context("无法定位程序目录")?
            .to_path_buf();

        let root_override = if cfg!(debug_assertions) {
            std::env::var("SCUM_MM_ROOT").ok()
        } else {
            None
        };
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
            locales_dir: root.join("locales"),
            deployment_manifest: root.join("deployment_manifest.json"),
            logs_dir: root.join("logs"),
            sftp_known_hosts: root.join("secrets").join("sftp_known_hosts.json"),
            sftp_remote_notes: root.join("sftp_remote_notes.json"),
            backups_dir: root.join("backups"),
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
        std::fs::create_dir_all(&self.locales_dir)
            .with_context(|| format!("无法创建翻译目录 {}", self.locales_dir.display()))?;
        prune_stale_downloads(&self.root);
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
            locales_dir: root.join("locales"),
            deployment_manifest: root.join("deployment_manifest.json"),
            logs_dir: root.join("logs"),
            sftp_known_hosts: root.join("secrets").join("sftp_known_hosts.json"),
            sftp_remote_notes: root.join("sftp_remote_notes.json"),
            backups_dir: root.join("backups"),
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

const MAX_DISK_NAME_CHARS: usize = 80;
const WINDOWS_RESERVED_NAMES: [&str; 22] = [
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

/// 生成可安全落盘的单个路径组件。
///
/// 与 `safe_file_component` 不同，这里保留 Unicode：中文模组名不再被压成下划线，
/// 否则两个字数相同的中文模组会映射到同一个目录或文件名并互相覆盖。
/// 只替换 Windows 非法字符与控制字符，去掉前导/尾随的点与空格以拒绝路径穿越，
/// 并对设备保留名加前缀。
pub fn safe_disk_name(value: &str, fallback: &str) -> String {
    let sanitized: String = value
        .chars()
        .map(|ch| match ch {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            _ if ch.is_control() => '_',
            _ => ch,
        })
        .collect();
    let trimmed = sanitized.trim_matches(|ch: char| ch == '.' || ch == ' ');
    let mut truncated: String = trimmed.chars().take(MAX_DISK_NAME_CHARS).collect();
    while truncated.ends_with('.') || truncated.ends_with(' ') {
        truncated.pop();
    }
    if truncated.is_empty() {
        return fallback.to_string();
    }
    let stem = truncated
        .split('.')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_uppercase();
    if WINDOWS_RESERVED_NAMES.contains(&stem.as_str()) {
        return format!("_{truncated}");
    }
    truncated
}

pub fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// 原子写计数器，保证同一进程内并发写的临时文件名互不相同。
static ATOMIC_WRITE_SEQ: AtomicU64 = AtomicU64::new(0);

fn temp_path_for(path: &Path) -> PathBuf {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "state".to_string());
    let seq = ATOMIC_WRITE_SEQ.fetch_add(1, Ordering::Relaxed);
    parent.join(format!(".{name}.tmp-{}-{seq}", std::process::id()))
}

/// 原子写：先写同目录临时文件并 `sync_all`，再 `rename` 提交。
///
/// Windows 上 `std::fs::rename` 走 `MoveFileExW(MOVEFILE_REPLACE_EXISTING)`，可以直接
/// 覆盖已存在的目标，所以断电/崩溃只会留下一个临时文件，不会产生被截断的状态文件。
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("无法创建目录 {}", parent.display()))?;
    }
    let temp = temp_path_for(path);
    let result = (|| -> Result<()> {
        let mut file = std::fs::File::create(&temp)
            .with_context(|| format!("无法创建临时文件 {}", temp.display()))?;
        file.write_all(bytes)
            .with_context(|| format!("无法写入临时文件 {}", temp.display()))?;
        file.sync_all()
            .with_context(|| format!("无法同步临时文件 {}", temp.display()))?;
        drop(file);
        std::fs::rename(&temp, path)
            .with_context(|| format!("无法提交 {}", path.display()))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

/// 状态文件的上一版副本路径（`config.json` → `config.json.bak`）。
pub fn backup_path_of(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "state".to_string());
    path.with_file_name(format!("{name}.bak"))
}

/// 写状态文件：原子写 + 把上一版轮转成 `.bak`，供解析失败时回退。
pub fn write_state_file(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("无法创建目录 {}", parent.display()))?;
    }
    let temp = temp_path_for(path);
    let commit = (|| -> Result<()> {
        let mut file = std::fs::File::create(&temp)
            .with_context(|| format!("无法创建临时文件 {}", temp.display()))?;
        file.write_all(bytes)
            .with_context(|| format!("无法写入临时文件 {}", temp.display()))?;
        file.sync_all()
            .with_context(|| format!("无法同步临时文件 {}", temp.display()))?;
        drop(file);
        // 用上一版覆盖 `.bak`，再提交新版；两步 rename 之间失败时 `.bak` 仍可恢复。
        if path.exists() {
            let _ = std::fs::rename(path, backup_path_of(path));
        }
        std::fs::rename(&temp, path)
            .with_context(|| format!("无法提交 {}", path.display()))?;
        Ok(())
    })();
    if commit.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    commit
}

/// 下载暂存目录的保留时长。超过这个时间的残留（进程崩溃、断电）在启动时清掉。
const STALE_DOWNLOAD_AGE: Duration = Duration::from_secs(24 * 60 * 60);

/// 清理 `{root}/downloads` 下过期的分片目录与临时文件，只动这一个目录。
pub fn prune_stale_downloads(root: &Path) {
    let downloads = root.join("downloads");
    let Ok(entries) = std::fs::read_dir(&downloads) else {
        return;
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        let Ok(modified) = metadata.modified() else {
            continue;
        };
        let Ok(age) = now.duration_since(modified) else {
            continue;
        };
        if age < STALE_DOWNLOAD_AGE {
            continue;
        }
        let path = entry.path();
        if metadata.is_dir() {
            let _ = std::fs::remove_dir_all(&path);
        } else {
            let _ = std::fs::remove_file(&path);
        }
    }
}

/// 目标路径所在卷的可用字节数。非 Windows 平台返回 `None`，调用方需容忍未知。
#[cfg(windows)]
pub fn free_space(path: &Path) -> Option<u64> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;

    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    let mut available = 0_u64;
    let ok = unsafe {
        GetDiskFreeSpaceExW(
            wide.as_ptr(),
            &mut available,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    (ok != 0).then_some(available)
}

#[cfg(not(windows))]
pub fn free_space(_path: &Path) -> Option<u64> {
    None
}

pub fn is_within(path: &Path, root: &Path) -> bool {
    let normalized_path = normalize_for_compare(path);
    let normalized_root = normalize_for_compare(root);
    normalized_path == normalized_root || normalized_path.starts_with(&(normalized_root + "\\"))
}

/// 解析重解析点（junction / 符号链接）后再判断包含关系。
///
/// `is_within` 是纯词法判断：`{root}/~mods/evil` 若是指向根外的 junction，
/// 词法检查仍然通过。删除、复制、回收这类会作用到链接目标的操作必须用这个版本。
pub fn is_within_resolved(path: &Path, root: &Path) -> bool {
    let (Ok(resolved_path), Ok(resolved_root)) = (path.canonicalize(), root.canonicalize()) else {
        return false;
    };
    let path_key = normalize_for_compare(&resolved_path);
    let root_key = normalize_for_compare(&resolved_root);
    path_key == root_key || path_key.starts_with(&(root_key + "\\"))
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
    use super::{
        backup_path_of, free_space, is_within, prune_stale_downloads, resolve_data_root,
        safe_disk_name, safe_file_component, write_atomic, write_state_file,
    };
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime};
    use uuid::Uuid;

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

    #[test]
    fn disk_name_keeps_chinese_and_rejects_separators() {
        assert_eq!(safe_disk_name("武器增强", "mod"), "武器增强");
        assert_eq!(safe_disk_name("高清材质包", "mod"), "高清材质包");
        assert_ne!(
            safe_disk_name("武器增强", "mod"),
            safe_disk_name("高清材质包", "mod")
        );
        assert_eq!(safe_disk_name("../evil", "mod"), "_evil");
        assert_eq!(
            safe_disk_name("a/b\\c:d*e?f\"g<h>i|j", "mod"),
            "a_b_c_d_e_f_g_h_i_j"
        );
        assert_eq!(safe_disk_name("  ..  ", "mod"), "mod");
        assert_eq!(safe_disk_name("CON", "mod"), "_CON");
        assert_eq!(safe_disk_name("nul.pak", "mod"), "_nul.pak");
        assert_eq!(safe_disk_name("SCUM_WeaponPack", "mod"), "SCUM_WeaponPack");
    }

    #[test]
    fn disk_name_truncates_long_unicode_names() {
        let long = "超长模组名称".repeat(30);
        let name = safe_disk_name(&long, "mod");
        assert_eq!(name.chars().count(), 80);
        assert!(name.starts_with("超长模组名称"));
    }

    #[test]
    fn prunes_only_stale_download_artifacts() {
        let root = std::env::temp_dir().join(format!("scum-mod-prune-{}", Uuid::new_v4()));
        let downloads = root.join("downloads");
        fs::create_dir_all(&downloads).unwrap();
        let stale = downloads.join("old.parts");
        fs::write(&stale, b"x").unwrap();
        let fresh = downloads.join("new.parts");
        fs::write(&fresh, b"x").unwrap();

        let aged = fs::OpenOptions::new().write(true).open(&stale).unwrap();
        let two_days_ago = SystemTime::now() - Duration::from_secs(48 * 60 * 60);
        aged.set_times(fs::FileTimes::new().set_modified(two_days_ago))
            .unwrap();
        drop(aged);

        prune_stale_downloads(&root);

        assert!(!stale.exists(), "48 小时前的残留应被清掉");
        assert!(fresh.exists(), "新文件不能被误删");
        let _ = fs::remove_dir_all(&root);
    }

    #[cfg(windows)]
    #[test]
    fn free_space_reads_the_volume_of_a_real_directory() {
        let available = free_space(&std::env::temp_dir()).expect("Windows 上应能读到卷可用空间");
        assert!(available > 0, "可用空间应为正数");
    }

    #[test]
    fn atomic_write_leaves_no_temp_file_behind() {
        let root = std::env::temp_dir().join(format!("scum-atomic-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let target = root.join("config.json");

        write_atomic(&target, b"first").unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"first");
        write_atomic(&target, b"second").unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"second");

        let leftovers = fs::read_dir(&root)
            .unwrap()
            .flatten()
            .filter(|entry| entry.file_name().to_string_lossy().contains(".tmp-"))
            .count();
        assert_eq!(leftovers, 0, "临时文件必须被清理");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn state_write_rotates_the_previous_version_into_a_backup() {
        let root = std::env::temp_dir().join(format!("scum-state-write-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let target = root.join("mods_meta.json");

        write_state_file(&target, b"v1").unwrap();
        write_state_file(&target, b"v2").unwrap();

        assert_eq!(fs::read(&target).unwrap(), b"v2");
        assert_eq!(fs::read(backup_path_of(&target)).unwrap(), b"v1");
        let _ = fs::remove_dir_all(&root);
    }
}
