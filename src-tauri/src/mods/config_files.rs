use crate::models::{ModConfigFile, ModConfigFileContent};
use crate::paths::AppPaths;
use anyhow::{bail, Context, Result};
use std::path::{Component, Path, PathBuf};

const MAX_CONFIG_BYTES: u64 = 512 * 1024;
const MAX_CONFIG_FILES: usize = 200;
const MAX_CONFIG_DEPTH: usize = 4;
const CONFIG_BACKUP_KEEP: usize = 20;

/// 可编辑的文本类型。二进制、PAK、DLL 一律拒绝。
const EDITABLE_EXTENSIONS: &[&str] = &[
    "ini", "json", "txt", "lua", "cfg", "toml", "xml", "yaml", "yml", "csv", "md",
];

/// 启动器自己维护的文件：编辑会被下一次部署覆盖，只读展示。
const APP_MANAGED_NAMES: &[&str] = &["mods.txt", "mods.json", ".scum_mm_managed.txt"];

pub fn is_editable_extension(name: &str) -> bool {
    Path::new(name)
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|extension| {
            EDITABLE_EXTENSIONS
                .iter()
                .any(|item| item.eq_ignore_ascii_case(extension))
        })
}

pub fn is_app_managed(name: &str) -> bool {
    APP_MANAGED_NAMES
        .iter()
        .any(|item| item.eq_ignore_ascii_case(name))
}

/// 只接受相对路径 + 普通片段，挡掉 `..`、盘符、UNC。
pub fn sanitize_relative(relative: &str) -> Result<PathBuf> {
    let path = Path::new(relative);
    if path.is_absolute() {
        bail!("配置文件路径必须是模组目录内的相对路径");
    }
    let mut clean = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(value) => clean.push(value),
            Component::CurDir => {}
            _ => bail!("配置文件路径包含非法片段：{relative}"),
        }
    }
    if clean.as_os_str().is_empty() {
        bail!("配置文件路径为空");
    }
    Ok(clean)
}

/// 规范化后必须仍在模组根目录内（防 junction / 符号链接逃逸）。
pub fn resolve_config_path(mod_root: &Path, relative: &str) -> Result<PathBuf> {
    let clean = sanitize_relative(relative)?;
    let root = std::fs::canonicalize(mod_root)
        .with_context(|| format!("无法定位模组目录 {}", mod_root.display()))?;
    let target = std::fs::canonicalize(root.join(&clean))
        .with_context(|| format!("配置文件不存在：{relative}"))?;
    if !target.starts_with(&root) {
        bail!("拒绝访问模组目录之外的路径：{relative}");
    }
    if !target.is_file() {
        bail!("不是普通文件：{relative}");
    }
    Ok(target)
}

pub fn list_config_files(mod_root: &Path) -> Result<Vec<ModConfigFile>> {
    let root = std::fs::canonicalize(mod_root)
        .with_context(|| format!("无法定位模组目录 {}", mod_root.display()))?;
    let mut found = Vec::new();
    collect(&root, &root, 0, &mut found)?;
    found.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    found.truncate(MAX_CONFIG_FILES);
    Ok(found)
}

fn collect(root: &Path, dir: &Path, depth: usize, out: &mut Vec<ModConfigFile>) -> Result<()> {
    if depth > MAX_CONFIG_DEPTH || out.len() >= MAX_CONFIG_FILES {
        return Ok(());
    }
    for entry in std::fs::read_dir(dir)?.flatten() {
        let path = entry.path();
        let metadata = match entry.metadata() {
            Ok(value) => value,
            Err(_) => continue,
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            collect(root, &path, depth + 1, out)?;
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if !is_editable_extension(&name) {
            continue;
        }
        let relative = path
            .strip_prefix(root)
            .map(|value| value.to_string_lossy().replace('\\', "/"))
            .unwrap_or_else(|_| name.clone());
        out.push(ModConfigFile {
            name: name.clone(),
            relative_path: relative,
            size: metadata.len(),
            editable: !is_app_managed(&name) && metadata.len() <= MAX_CONFIG_BYTES,
            managed_by_app: is_app_managed(&name),
        });
        if out.len() >= MAX_CONFIG_FILES {
            return Ok(());
        }
    }
    Ok(())
}

pub fn read_config_file(mod_root: &Path, relative: &str) -> Result<ModConfigFileContent> {
    let target = resolve_config_path(mod_root, relative)?;
    let name = target
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    if !is_editable_extension(&name) {
        bail!("不支持编辑该类型的配置文件：{name}");
    }
    let metadata = std::fs::metadata(&target)?;
    if metadata.len() > MAX_CONFIG_BYTES {
        bail!("配置文件超过 512 KB，不能在这里编辑：{relative}");
    }
    let bytes = std::fs::read(&target)?;
    let content =
        String::from_utf8(bytes).with_context(|| format!("配置文件不是 UTF-8：{relative}"))?;
    Ok(ModConfigFileContent {
        relative_path: relative.to_string(),
        content,
        size: metadata.len(),
        modified_at: metadata
            .modified()
            .ok()
            .map(|time| chrono::DateTime::<chrono::Utc>::from(time).to_rfc3339()),
        editable: !is_app_managed(&name),
    })
}

pub fn write_config_file(
    paths: &AppPaths,
    mod_id: &str,
    mod_root: &Path,
    relative: &str,
    content: &str,
) -> Result<ModConfigFile> {
    let target = resolve_config_path(mod_root, relative)?;
    let name = target
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    if is_app_managed(&name) {
        bail!("{name} 由启动器维护，不能在这里修改");
    }
    if !is_editable_extension(&name) {
        bail!("不支持编辑该类型的配置文件：{name}");
    }
    if content.len() as u64 > MAX_CONFIG_BYTES {
        bail!("配置内容超过 512 KB 上限");
    }
    if name.to_ascii_lowercase().ends_with(".json") {
        serde_json::from_str::<serde_json::Value>(content)
            .with_context(|| format!("{name} 不是合法 JSON，已拒绝保存"))?;
    }

    // 写前备份：{root}/config_backups/<mod_id>/<时间戳>-<文件名>
    let backup_dir = paths.root.join("config_backups").join(sanitize_file(mod_id));
    std::fs::create_dir_all(&backup_dir)?;
    let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S-%3f");
    let backup = backup_dir.join(format!("{stamp}-{}", sanitize_file(&name)));
    std::fs::copy(&target, &backup)
        .with_context(|| format!("无法备份配置文件 {}", target.display()))?;
    prune_backups(&backup_dir)?;

    // 原子写：同目录临时文件 + rename，避免留下半截文件。
    let temp = target.with_extension(format!("{name}.tmp"));
    std::fs::write(&temp, content.as_bytes())?;
    std::fs::rename(&temp, &target)?;
    let metadata = std::fs::metadata(&target)?;
    Ok(ModConfigFile {
        name,
        relative_path: relative.to_string(),
        size: metadata.len(),
        editable: true,
        managed_by_app: false,
    })
}

fn sanitize_file(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_alphanumeric() || ch == '-' || ch == '_' || ch == '.' {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

fn prune_backups(dir: &Path) -> Result<()> {
    let mut entries = std::fs::read_dir(dir)?
        .flatten()
        .filter_map(|entry| {
            entry
                .metadata()
                .ok()
                .and_then(|meta| meta.modified().ok())
                .map(|modified| (modified, entry.path()))
        })
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| right.0.cmp(&left.0));
    for (_, path) in entries.into_iter().skip(CONFIG_BACKUP_KEEP) {
        let _ = std::fs::remove_file(path);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{list_config_files, read_config_file, sanitize_relative, write_config_file};
    use crate::test_support::TempRoot;

    #[test]
    fn rejects_parent_traversal() {
        assert!(sanitize_relative("../secret.ini").is_err());
        assert!(sanitize_relative("/etc/passwd").is_err());
        assert!(sanitize_relative("scripts/config.ini").is_ok());
    }

    #[test]
    fn writes_content_and_keeps_a_backup() {
        let temp = TempRoot::new("config-files");
        let paths = temp.paths();
        let module = paths.ue4ss_mods.join("BetterAI");
        std::fs::create_dir_all(&module).unwrap();
        std::fs::write(module.join("config.ini"), "a=1").unwrap();

        let files = list_config_files(&module).unwrap();
        assert_eq!(files.len(), 1);
        assert!(files[0].editable);

        write_config_file(&paths, "mod-1", &module, "config.ini", "a=2").unwrap();
        assert_eq!(
            std::fs::read_to_string(module.join("config.ini")).unwrap(),
            "a=2"
        );

        let backups = std::fs::read_dir(paths.root.join("config_backups").join("mod-1"))
            .unwrap()
            .count();
        assert_eq!(backups, 1);
        assert_eq!(read_config_file(&module, "config.ini").unwrap().content, "a=2");
    }

    #[test]
    fn refuses_to_edit_launcher_managed_files() {
        let temp = TempRoot::new("config-managed");
        let paths = temp.paths();
        let mods_dir = paths.ue4ss_mods.clone();
        std::fs::write(mods_dir.join("mods.txt"), "BetterAI : 1").unwrap();
        assert!(write_config_file(&paths, "root", &mods_dir, "mods.txt", "x").is_err());
        let listed = list_config_files(&mods_dir).unwrap();
        assert!(listed[0].managed_by_app);
        assert!(!listed[0].editable);
    }

    #[test]
    fn rejects_invalid_json() {
        let temp = TempRoot::new("config-json");
        let paths = temp.paths();
        let module = paths.ue4ss_mods.join("BetterAI");
        std::fs::create_dir_all(&module).unwrap();
        std::fs::write(module.join("settings.json"), "{}").unwrap();
        assert!(write_config_file(&paths, "mod-1", &module, "settings.json", "{oops").is_err());
        assert_eq!(
            std::fs::read_to_string(module.join("settings.json")).unwrap(),
            "{}"
        );
    }
}
