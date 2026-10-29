use super::extract_zip_file;
use crate::metadata::MetadataFile;
use crate::models::{AppSettings, ModEntry};
use crate::mods::pak_scan;
use crate::paths::{is_within, path_string, safe_file_component, AppPaths};
use anyhow::{bail, Context, Result};
use base64::Engine;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::{Component, Path, PathBuf};
use walkdir::WalkDir;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeployedManifest {
    pub deployed_at: String,
    pub roots: Vec<String>,
    pub files: Vec<String>,
    pub directories: Vec<String>,
    #[serde(default)]
    pub created_directories: Vec<String>,
    #[serde(default)]
    pub backups: Vec<DeployedBackup>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeployedBackup {
    pub target: String,
    pub backup: String,
}

pub fn read_manifest(paths: &AppPaths) -> Option<DeployedManifest> {
    let text = std::fs::read_to_string(&paths.deployment_manifest).ok()?;
    serde_json::from_str(&text).ok()
}

pub fn deployed_file_names(paths: &AppPaths) -> HashSet<String> {
    let Some(manifest) = read_manifest(paths) else {
        return HashSet::new();
    };
    let mut names = HashSet::new();
    for path in manifest.files.iter().chain(manifest.directories.iter()) {
        let path = Path::new(path);
        names.insert(path.to_string_lossy().to_ascii_lowercase());
        let Some(file_name) = path.file_name() else {
            continue;
        };
        let file_name = file_name.to_string_lossy().to_ascii_lowercase();
        // Deployment adds game-order prefixes without renaming the local library.
        if let Some(original) = strip_deployed_pak_prefix(&file_name) {
            names.insert(original.to_string());
        }
        names.insert(file_name);
    }
    names
}

fn strip_deployed_pak_prefix(file_name: &str) -> Option<&str> {
    let (prefix, original) = file_name.split_once('_')?;
    if prefix.len() < 3 || !prefix.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let (_, extension) = original.rsplit_once('.')?;
    extension.eq_ignore_ascii_case("pak").then_some(original)
}

pub fn reclaim_mods(paths: &AppPaths) -> Result<usize> {
    let Some(manifest) = read_manifest(paths) else {
        return Ok(0);
    };
    let roots: Vec<PathBuf> = manifest.roots.iter().map(PathBuf::from).collect();
    let created_directories = manifest
        .created_directories
        .iter()
        .map(|path| path_key(Path::new(path)))
        .collect::<HashSet<_>>();
    let mut removed = 0;
    let mut failures = Vec::new();
    let mut remaining_files = Vec::new();
    for file in manifest.files.iter().rev() {
        let file = PathBuf::from(file);
        if !roots.iter().any(|root| is_within(&file, root)) {
            continue;
        }
        if file.exists() {
            match std::fs::remove_file(&file) {
                Ok(()) => removed += 1,
                Err(error) => {
                    failures.push(format!("无法删除 {}：{error}", file.display()));
                    remaining_files.push(path_string(&file));
                }
            }
        }
    }

    let mut remaining_backups = Vec::new();
    for backup in manifest.backups {
        let target = PathBuf::from(&backup.target);
        let backup_path = PathBuf::from(&backup.backup);
        if !roots.iter().any(|root| is_within(&target, root))
            || !is_within(&backup_path, &paths.backups_dir)
        {
            continue;
        }
        if target.exists() {
            // A failed deployment-file removal must not overwrite the live game file.
            remaining_backups.push(backup);
            continue;
        }
        if !backup_path.is_file() {
            failures.push(format!("备份文件不存在：{}", backup_path.display()));
            remaining_backups.push(backup);
            continue;
        }
        let restore = (|| -> Result<()> {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::copy(&backup_path, &target).with_context(|| {
                format!(
                    "无法恢复备份 {} 到 {}",
                    backup_path.display(),
                    target.display()
                )
            })?;
            Ok(())
        })();
        match restore {
            Ok(()) => {
                let _ = std::fs::remove_file(&backup_path);
            }
            Err(error) => {
                failures.push(error.to_string());
                remaining_backups.push(backup);
            }
        }
    }

    if failures.is_empty() {
        let mut directories = manifest.directories.clone();
        directories.sort_by_key(|path| std::cmp::Reverse(path.len()));
        for directory in directories {
            let directory = PathBuf::from(directory);
            if !roots.iter().any(|root| is_within(&directory, root)) {
                continue;
            }
            if roots.iter().any(|root| same_path(&directory, root)) {
                continue;
            }
            if !directory.exists() {
                continue;
            }
            if !directory.is_dir() {
                failures.push(format!("部署目录位置已被文件占用：{}", directory.display()));
                continue;
            }
            if directory
                .file_name()
                .is_some_and(|name| name.to_string_lossy().eq_ignore_ascii_case("ue4ss"))
            {
                if let Err(error) = remove_ue4ss_runtime_artifacts(&directory) {
                    failures.push(error.to_string());
                    continue;
                }
            }
            if created_directories.contains(&path_key(&directory)) {
                if let Err(error) = std::fs::remove_dir_all(&directory) {
                    failures.push(format!("无法删除部署目录 {}：{error}", directory.display()));
                }
            } else if let Err(error) = remove_empty_directory(&directory) {
                failures.push(error);
            }
        }
    }

    if failures.is_empty() {
        let _ = std::fs::remove_file(&paths.deployment_manifest);
        return Ok(removed);
    }

    let remaining = DeployedManifest {
        deployed_at: manifest.deployed_at,
        roots: manifest.roots,
        files: remaining_files,
        directories: manifest.directories,
        created_directories: manifest.created_directories,
        backups: remaining_backups,
    };
    write_manifest(paths, &remaining)?;
    bail!(
        "部署文件回收未完成：{}。剩余清单已保留，可修复权限或关闭占用后重试。",
        failures.join("；")
    )
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RescueSummary {
    pub rescued: usize,
    pub skipped: usize,
}

pub fn rescue_mods_from_game(paths: &AppPaths, settings: &AppSettings) -> Result<RescueSummary> {
    let mut summary = RescueSummary::default();
    let managed_targets = read_manifest(paths)
        .map(|manifest| manifest.files)
        .unwrap_or_default();
    for install in [&settings.scum_install_path, &settings.server_install_path] {
        if install.trim().is_empty() {
            continue;
        }
        let Some(pak_dir) = find_pak_dir(Path::new(install)) else {
            continue;
        };
        let Ok(entries) = std::fs::read_dir(pak_dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let source = entry.path();
            if source.is_file() && super::is_pak(&source) {
                // Managed prefixed targets are reclaimed, not imported back as new local mods.
                if managed_targets
                    .iter()
                    .any(|target| same_path(Path::new(target), &source))
                {
                    continue;
                }
                let destination = paths.local_mods.join(entry.file_name());
                std::fs::create_dir_all(&paths.local_mods)?;
                if destination.exists() {
                    summary.skipped += 1;
                    continue;
                }
                std::fs::copy(&source, destination)?;
                summary.rescued += 1;
            }
        }
    }
    Ok(summary)
}

pub fn deploy_local_mods(
    paths: &AppPaths,
    settings: &AppSettings,
    mods: &[ModEntry],
    is_server: bool,
) -> Result<Option<String>> {
    reclaim_mods(paths)?;
    let metadata = crate::metadata::load_metadata(paths)?;
    let install = if is_server {
        settings.server_install_path.trim()
    } else {
        settings.scum_install_path.trim()
    };
    if install.is_empty() {
        bail!(
            "尚未设置 SCUM {}安装路径",
            if is_server { "服务端" } else { "客户端" }
        );
    }
    let install = Path::new(install);
    let pak_dir = find_pak_dir(install).unwrap_or_else(|| {
        install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods")
    });
    std::fs::create_dir_all(&pak_dir)
        .with_context(|| format!("无法创建游戏模组目录 {}", pak_dir.display()))?;

    let canonical_mods = super::duplicates::collapse_identical_mods(
        mods.to_vec(),
        &crate::metadata::MetadataFile::default(),
    );
    let enabled: Vec<&ModEntry> = canonical_mods.iter().filter(|item| item.enabled).collect();
    if enabled.is_empty() {
        return Ok(None);
    }

    let mut manifest = DeployedManifest {
        deployed_at: Utc::now().to_rfc3339(),
        roots: vec![path_string(install), path_string(&pak_dir)],
        ..DeployedManifest::default()
    };
    let backup_root = paths
        .backups_dir
        .join("deploy")
        .join(uuid::Uuid::new_v4().to_string());

    let deploy_result = (|| -> Result<()> {
        let mut client_paks = enabled
            .iter()
            .copied()
            .filter(|item| item.mod_type == "clientPak")
            .collect::<Vec<_>>();
        client_paks.sort_by(|left, right| {
            left.load_order
                .cmp(&right.load_order)
                .then_with(|| {
                    left.file_name
                        .to_ascii_lowercase()
                        .cmp(&right.file_name.to_ascii_lowercase())
                })
                .then_with(|| left.file_name.cmp(&right.file_name))
                .then_with(|| left.id.cmp(&right.id))
        });
        let conflict_analysis = pak_scan::analyze_conflicts(&metadata, &canonical_mods);
        let conflicting_ids = conflict_analysis
            .groups
            .iter()
            .flat_map(|group| group.owners.iter().map(|owner| owner.id.as_str()))
            .collect::<HashSet<_>>();
        let pak_prefix_width = deployment_prefix_width(client_paks.len());
        for (index, item) in client_paks.iter().enumerate() {
            if conflicting_ids.contains(item.id.as_str()) {
                continue;
            }
            let source = PathBuf::from(&item.file_path);
            if !source.is_file() {
                continue;
            }
            let target = pak_dir.join(numbered_pak_file_name(
                index,
                &item.file_name,
                pak_prefix_width,
            ));
            copy_file_record(&source, &target, &backup_root, &mut manifest)?;
        }
        let merged_file_name = conflict_merged_file_name(client_paks.len());
        deploy_merged_conflict_paks(
            paths,
            &canonical_mods,
            &conflict_analysis,
            &metadata,
            &pak_dir,
            &backup_root,
            &mut manifest,
            &merged_file_name,
        )?;

        let ue4ss_enabled: Vec<&&ModEntry> = enabled
            .iter()
            .filter(|item| item.mod_type == "ue4ssMod")
            .collect();
        if !ue4ss_enabled.is_empty() {
            if let Some(binaries) = find_binaries_dir(install) {
                ensure_runtime_framework(paths)?;
                sync_ue4ss_mods_txt(paths, &canonical_mods)?;
                deploy_framework(paths, &binaries, &backup_root, &mut manifest)?;
                for item in ue4ss_enabled {
                    deploy_ue4ss_mod(item, &binaries, &backup_root, &mut manifest)?;
                }
            }
        }

        if manifest.files.is_empty() {
            bail!("没有可部署的模组文件，请检查本地 ~mods 目录");
        }
        Ok(())
    })();

    if let Err(error) = deploy_result {
        if !manifest.files.is_empty() || !manifest.backups.is_empty() {
            if let Err(manifest_error) = write_manifest(paths, &manifest) {
                return Err(anyhow::anyhow!(
                    "{error:#}；同时无法保存回滚清单：{manifest_error:#}"
                ));
            }
            if let Err(cleanup_error) = reclaim_mods(paths) {
                return Err(anyhow::anyhow!(
                    "{error:#}；部署失败后的自动回收也未完成：{cleanup_error:#}"
                ));
            }
        }
        return Err(error);
    }

    write_manifest(paths, &manifest)?;
    Ok(Some(manifest.deployed_at))
}

const CONFLICT_MERGED_FILE: &str = "999_SCUM_Mod_Desk_Merged.pak";

fn deployment_prefix_width(client_pak_count: usize) -> usize {
    client_pak_count.to_string().len().max(3)
}

fn numbered_pak_file_name(index: usize, original: &str, width: usize) -> String {
    format!("{index:0width$}_{original}")
}

fn conflict_merged_file_name(client_pak_count: usize) -> String {
    let width = deployment_prefix_width(client_pak_count);
    if width == 3 {
        return CONFLICT_MERGED_FILE.to_string();
    }
    format!("{}_SCUM_Mod_Desk_Merged.pak", "9".repeat(width))
}

fn deploy_merged_conflict_paks(
    paths: &AppPaths,
    mods: &[ModEntry],
    analysis: &pak_scan::ConflictAnalysis,
    metadata: &MetadataFile,
    pak_dir: &Path,
    backup_root: &Path,
    manifest: &mut DeployedManifest,
    merged_file_name: &str,
) -> Result<()> {
    let conflicting_ids = analysis
        .groups
        .iter()
        .flat_map(|group| group.owners.iter().map(|owner| owner.id.as_str()))
        .collect::<HashSet<_>>();
    if conflicting_ids.is_empty() {
        return Ok(());
    }

    let mods_by_id = mods
        .iter()
        .map(|item| (item.id.as_str(), item))
        .collect::<std::collections::HashMap<_, _>>();
    let mut selected_entries: BTreeMap<String, (String, PathBuf)> = BTreeMap::new();
    for group in &analysis.groups {
        let winner = mods_by_id
            .get(group.winner_id.as_str())
            .with_context(|| format!("找不到冲突组的合并胜者：{}", group.winner_id))?;
        if !winner.enabled || winner.mod_type != "clientPak" {
            bail!("冲突组的合并胜者当前不可部署：{}", winner.name);
        }
        let pak_path = PathBuf::from(&winner.file_path);
        if !pak_path.is_file() {
            bail!("合并胜者的 PAK 文件不存在：{}", pak_path.display());
        }
        let available = metadata
            .entries
            .get(&winner.id)
            .into_iter()
            .flat_map(|entry| entry.pak_entries.iter())
            .filter_map(|entry| pak_scan::normalize_entry_path(entry))
            .map(|entry| entry.to_ascii_lowercase())
            .collect::<BTreeSet<_>>();
        for resource in &group.paths {
            if !available.contains(&resource.to_ascii_lowercase()) {
                bail!(
                    "冲突合并无法完成：{} 缺少资源 {}，请选择包含完整资源的版本",
                    winner.name,
                    resource
                );
            }
            let key = resource.to_ascii_lowercase();
            if let Some((existing, _)) = selected_entries.get(&key) {
                if !existing.eq_ignore_ascii_case(&winner.file_path) {
                    bail!("资源 {resource} 同时被多个冲突胜者选中");
                }
            } else {
                selected_entries.insert(key, (resource.clone(), pak_path.clone()));
            }
        }
    }

    let mut conflicting_mods = mods
        .iter()
        .filter(|item| conflicting_ids.contains(item.id.as_str()))
        .collect::<Vec<_>>();
    conflicting_mods.sort_by(|left, right| {
        left.load_order
            .cmp(&right.load_order)
            .then_with(|| left.id.cmp(&right.id))
    });
    for item in conflicting_mods {
        if !item.enabled || item.mod_type != "clientPak" {
            continue;
        }
        let pak_path = PathBuf::from(&item.file_path);
        if !pak_path.is_file() {
            bail!("参与冲突合并的 PAK 文件不存在：{}", pak_path.display());
        }
        let Some(entry) = metadata.entries.get(&item.id) else {
            bail!("参与冲突合并的模组缺少资源清单：{}", item.name);
        };
        for raw in &entry.pak_entries {
            let Some(resource) = pak_scan::normalize_entry_path(raw) else {
                continue;
            };
            let key = resource.to_ascii_lowercase();
            if selected_entries.contains_key(&key) {
                continue;
            }
            selected_entries.insert(key, (resource, pak_path.clone()));
        }
    }
    if selected_entries.is_empty() {
        return Ok(());
    }

    let merged_root = paths.root.join("~merged");
    let stage_root = merged_root.join(uuid::Uuid::new_v4().to_string());
    let tree = stage_root.join("tree");
    let output = stage_root.join(merged_file_name);
    let result = (|| -> Result<()> {
        std::fs::create_dir_all(&tree)
            .with_context(|| format!("无法创建合并暂存目录 {}", tree.display()))?;
        let mut expected = BTreeSet::new();
        for (_, (resource, pak_path)) in &selected_entries {
            let relative = safe_pak_relative_path(resource)?;
            let destination = tree.join(relative);
            if !is_within(&destination, &tree) {
                bail!("合并暂存路径越界：{resource}");
            }
            pak_scan::extract_pak_entry(paths, pak_path, resource, &destination)?;
            expected.insert(resource.to_ascii_lowercase());
        }
        pak_scan::pack_pak(paths, &tree, &output)?;
        let packed = pak_scan::list_pak_entries(paths, &output)?
            .into_iter()
            .map(|entry| entry.to_ascii_lowercase())
            .collect::<BTreeSet<_>>();
        if !expected.is_subset(&packed) {
            bail!("冲突合并 PAK 校验失败：打包结果缺少预期资源");
        }
        copy_file_record(
            &output,
            &pak_dir.join(merged_file_name),
            backup_root,
            manifest,
        )?;
        Ok(())
    })();
    let _ = std::fs::remove_dir_all(&stage_root);
    let _ = std::fs::remove_dir(&merged_root);
    result
}

fn safe_pak_relative_path(resource: &str) -> Result<PathBuf> {
    let mut relative = PathBuf::new();
    for component in Path::new(resource).components() {
        let Component::Normal(name) = component else {
            bail!("拒绝不安全的 PAK 资源路径：{resource}");
        };
        let name = name.to_string_lossy();
        if name.is_empty() || name.contains(':') || name.chars().any(char::is_control) {
            bail!("拒绝不安全的 PAK 资源路径：{resource}");
        }
        relative.push(name.as_ref());
    }
    if relative.as_os_str().is_empty() {
        bail!("PAK 资源路径为空");
    }
    Ok(relative)
}

pub fn find_pak_dir(install: &Path) -> Option<PathBuf> {
    candidate_paths(install, ["SCUM/Content/Paks/~mods", "Content/Paks/~mods"])
        .into_iter()
        .find(|path| path.exists())
}

pub fn find_binaries_dir(install: &Path) -> Option<PathBuf> {
    candidate_paths(install, ["SCUM/Binaries/Win64", "Binaries/Win64"])
        .into_iter()
        .find(|path| path.exists())
}

pub fn find_executable(install: &Path, executable: &str) -> Option<PathBuf> {
    let nested = format!("SCUM/Binaries/Win64/{executable}");
    let flat = format!("Binaries/Win64/{executable}");
    candidate_paths(install, [nested.as_str(), executable, flat.as_str()])
        .into_iter()
        .find(|path| path.is_file())
}

fn candidate_paths<const N: usize>(install: &Path, relatives: [&str; N]) -> Vec<PathBuf> {
    relatives
        .into_iter()
        .filter(|relative| !relative.is_empty())
        .map(|relative| install.join(relative.replace('/', std::path::MAIN_SEPARATOR_STR)))
        .collect()
}

fn ensure_runtime_framework(paths: &AppPaths) -> Result<()> {
    let framework = paths.ue4ss_runtime.join("ue4ss");
    if framework.join("UE4SS.dll").exists() && paths.ue4ss_runtime.join("dwmapi.dll").exists() {
        return Ok(());
    }
    let archive = paths.resource("ue4ss_framework.zip");
    if !archive.exists() {
        bail!("内置 UE4SS 框架资源不存在");
    }
    extract_zip_file(&archive, &paths.ue4ss_runtime)?;
    Ok(())
}

fn deploy_framework(
    paths: &AppPaths,
    binaries: &Path,
    backup_root: &Path,
    manifest: &mut DeployedManifest,
) -> Result<()> {
    let dll = paths.ue4ss_runtime.join("dwmapi.dll");
    if dll.is_file() {
        copy_file_record(&dll, &binaries.join("dwmapi.dll"), backup_root, manifest)?;
    }
    let source_root = paths.ue4ss_runtime.join("ue4ss");
    let target_root = binaries.join("ue4ss");
    for entry in WalkDir::new(&source_root).follow_links(false) {
        let entry = entry?;
        let relative = entry.path().strip_prefix(&source_root)?;
        if relative.as_os_str().is_empty() {
            continue;
        }
        if relative.starts_with("Mods") {
            continue;
        }
        let target = target_root.join(relative);
        if entry.file_type().is_dir() {
            create_directory_recorded(&target, manifest)?;
        } else if entry.file_type().is_file() {
            copy_file_record(entry.path(), &target, backup_root, manifest)?;
        }
    }
    for file_name in ["mods.json", "mods.txt"] {
        let source = source_root.join("Mods").join(file_name);
        if source.is_file() {
            copy_file_record(
                &source,
                &target_root.join("Mods").join(file_name),
                backup_root,
                manifest,
            )?;
        }
    }
    Ok(())
}

fn deploy_ue4ss_mod(
    item: &ModEntry,
    binaries: &Path,
    backup_root: &Path,
    manifest: &mut DeployedManifest,
) -> Result<()> {
    let source = PathBuf::from(&item.file_path);
    let target = binaries.join("ue4ss").join("Mods").join(&item.name);
    create_directory_recorded(&target, manifest)?;
    for entry in WalkDir::new(&source).follow_links(false) {
        let entry = entry?;
        let relative = entry.path().strip_prefix(&source)?;
        if relative.as_os_str().is_empty() {
            continue;
        }
        let destination = target.join(relative);
        if entry.file_type().is_dir() {
            create_directory_recorded(&destination, manifest)?;
        } else if entry.file_type().is_file() {
            copy_file_record(entry.path(), &destination, backup_root, manifest)?;
        }
    }
    Ok(())
}

fn copy_file_record(
    source: &Path,
    target: &Path,
    backup_root: &Path,
    manifest: &mut DeployedManifest,
) -> Result<()> {
    if let Some(parent) = target.parent() {
        create_directory_recorded(parent, manifest)?;
    }
    if target.exists()
        && !manifest
            .backups
            .iter()
            .any(|backup| same_path(Path::new(&backup.target), target))
    {
        if !target.is_file() {
            bail!("部署目标已存在且不是文件：{}", target.display());
        }
        std::fs::create_dir_all(backup_root)?;
        let file_name = target
            .file_name()
            .map(|name| safe_file_component(&name.to_string_lossy()))
            .unwrap_or_else(|| "file".to_string());
        let backup = backup_root.join(format!("{:04}-{file_name}", manifest.backups.len()));
        std::fs::copy(target, &backup)
            .with_context(|| format!("无法备份原文件 {}", target.display()))?;
        manifest.backups.push(DeployedBackup {
            target: path_string(target),
            backup: path_string(&backup),
        });
    }
    if !manifest
        .files
        .iter()
        .any(|path| same_path(Path::new(path), target))
    {
        manifest.files.push(path_string(target));
    }
    std::fs::copy(source, target)
        .with_context(|| format!("无法复制 {} 到 {}", source.display(), target.display()))?;
    Ok(())
}

fn write_manifest(paths: &AppPaths, manifest: &DeployedManifest) -> Result<()> {
    let json = serde_json::to_string_pretty(manifest)?;
    std::fs::write(&paths.deployment_manifest, format!("{json}\n"))
        .with_context(|| format!("无法写入 {}", paths.deployment_manifest.display()))
}

fn same_path(left: &Path, right: &Path) -> bool {
    path_key(left) == path_key(right)
}

fn path_key(path: &Path) -> String {
    path_string(path)
        .replace('/', "\\")
        .trim_end_matches('\\')
        .to_ascii_lowercase()
}

fn create_directory_recorded(path: &Path, manifest: &mut DeployedManifest) -> Result<()> {
    let mut missing = Vec::new();
    let mut current = Some(path);
    while let Some(directory) = current {
        if directory.exists() {
            break;
        }
        missing.push(directory.to_path_buf());
        current = directory.parent();
    }
    std::fs::create_dir_all(path)
        .with_context(|| format!("无法创建部署目录 {}", path.display()))?;
    for directory in missing.into_iter().rev() {
        if !manifest
            .created_directories
            .iter()
            .any(|item| same_path(Path::new(item), &directory))
        {
            manifest.created_directories.push(path_string(&directory));
        }
    }
    if !manifest
        .directories
        .iter()
        .any(|item| same_path(Path::new(item), path))
    {
        manifest.directories.push(path_string(path));
    }
    Ok(())
}

fn remove_ue4ss_runtime_artifacts(root: &Path) -> Result<()> {
    for entry in WalkDir::new(root).follow_links(false) {
        let entry = entry?;
        if !entry.file_type().is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy();
        let generated_log = name.eq_ignore_ascii_case("UE4SS.log")
            || name
                .get(..9)
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case("UE4SS.log"))
                && name.get(9..).is_some_and(|suffix| suffix.starts_with('.'));
        if generated_log {
            std::fs::remove_file(entry.path())
                .with_context(|| format!("无法删除 UE4SS 运行时日志 {}", entry.path().display()))?;
        }
    }
    Ok(())
}

fn remove_empty_directory(directory: &Path) -> std::result::Result<(), String> {
    let mut entries = std::fs::read_dir(directory)
        .map_err(|error| format!("无法读取部署目录 {}：{error}", directory.display()))?;
    if entries.next().is_some() {
        return Ok(());
    }
    std::fs::remove_dir(directory)
        .map_err(|error| format!("无法删除空目录 {}：{error}", directory.display()))
}

fn sync_ue4ss_mods_txt(paths: &AppPaths, mods: &[ModEntry]) -> Result<()> {
    let mods_txt = paths.ue4ss_mods.join("mods.txt");
    let managed_path = paths.ue4ss_mods.join(".scum_mm_managed.txt");
    let previously_managed: HashSet<String> = std::fs::read_to_string(&managed_path)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            base64::engine::general_purpose::STANDARD
                .decode(line.trim())
                .ok()
                .and_then(|bytes| String::from_utf8(bytes).ok())
                .or_else(|| (!line.trim().is_empty()).then(|| line.trim().to_string()))
        })
        .collect();
    let existing = std::fs::read_to_string(&mods_txt).unwrap_or_default();
    let mut kept: Vec<String> = existing
        .lines()
        .filter(|line| {
            let name = line.split(':').next().unwrap_or_default().trim();
            !previously_managed.contains(name)
        })
        .map(ToString::to_string)
        .collect();
    let ue4ss_mods: Vec<&ModEntry> = mods
        .iter()
        .filter(|item| item.mod_type == "ue4ssMod")
        .collect();
    let our_lines: Vec<String> = ue4ss_mods
        .iter()
        .map(|item| format!("{} : {}", item.name, usize::from(item.enabled)))
        .collect();
    let insert_at = kept
        .iter()
        .position(|line| line.to_ascii_lowercase().starts_with("keybinds"))
        .unwrap_or(kept.len());
    let tail = kept.split_off(insert_at);
    kept.extend(our_lines);
    kept.extend(tail);
    std::fs::write(&mods_txt, format!("{}\n", kept.join("\n")))?;
    let encoded = ue4ss_mods
        .iter()
        .map(|item| base64::engine::general_purpose::STANDARD.encode(item.name.as_bytes()))
        .collect::<Vec<_>>()
        .join("\n");
    std::fs::write(managed_path, encoded)?;
    Ok(())
}

pub fn sync_ue4ss_state(paths: &AppPaths, mods: &[ModEntry]) -> Result<()> {
    sync_ue4ss_mods_txt(paths, mods)
}

#[cfg(test)]
mod tests {
    use super::{
        deploy_local_mods, read_manifest, reclaim_mods, rescue_mods_from_game, sync_ue4ss_state,
        DeployedManifest,
    };
    use crate::metadata::{save_metadata, MetadataFile};
    use crate::models::{AppSettings, ModEntry};
    use crate::paths::path_string;
    use crate::test_support::TempRoot;
    use base64::Engine;
    use std::fs::{self, File};
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use zip::write::SimpleFileOptions;
    use zip::{CompressionMethod, ZipWriter};

    fn mod_entry(path: &Path, enabled: bool, mod_type: &str) -> ModEntry {
        let name = path
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let file_name = path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        ModEntry {
            id: name.to_ascii_lowercase(),
            name,
            author: String::new(),
            file_name,
            file_path: path_string(path),
            file_size: path.metadata().map(|item| item.len()).unwrap_or(0),
            last_modified: "2026-01-01T00:00:00Z".to_string(),
            enabled,
            mod_type: mod_type.to_string(),
            load_order: 0,
            tags: Vec::new(),
            notes: String::new(),
            sha256: String::new(),
            origin_source: "local".to_string(),
            deployed: false,
            description: String::new(),
            conflict_count: 0,
            file_count: 0,
            overridden_file_count: 0,
            overriding_file_count: 0,
            fully_overridden: false,
            update_version: None,
            cover_url: None,
            duplicate_count: 0,
            duplicate_aliases: Vec::new(),
        }
    }

    fn write_framework_archive(paths: &crate::paths::AppPaths) {
        fs::create_dir_all(paths.root.join("resources")).unwrap();
        let archive_path = paths.root.join("resources").join("ue4ss_framework.zip");
        assert!(
            archive_path.starts_with(&paths.root),
            "tests must never write into the bundled resource directory: {}",
            archive_path.display()
        );
        let file = File::create(archive_path).unwrap();
        let mut writer = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        for (name, contents) in [
            ("ue4ss/UE4SS.dll", b"loader".as_slice()),
            ("ue4ss/UE4SS-settings.ini", b"[General]\n".as_slice()),
            ("ue4ss/Mods/mods.json", b"[]".as_slice()),
            ("ue4ss/Mods/mods.txt", b"".as_slice()),
            ("dwmapi.dll", b"proxy".as_slice()),
        ] {
            writer.start_file(name, options).unwrap();
            writer.write_all(contents).unwrap();
        }
        writer.finish().unwrap();
    }

    #[test]
    fn deploys_and_reclaims_one_pak_in_an_isolated_install() {
        let temp = TempRoot::new("deploy-reclaim");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let pak_dir = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods");
        fs::create_dir_all(&pak_dir).unwrap();
        let source = paths.local_mods.join("TestWeapon.pak");
        fs::write(&source, b"pak-content").unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };
        let mods = vec![mod_entry(&source, true, "clientPak")];

        let deployed_at = deploy_local_mods(&paths, &settings, &mods, false)
            .unwrap()
            .expect("PAK should be deployed");

        let target = pak_dir.join("000_TestWeapon.pak");
        assert_eq!(fs::read(&target).unwrap(), b"pak-content");
        let manifest = read_manifest(&paths).expect("deployment manifest should exist");
        assert_eq!(manifest.deployed_at, deployed_at);
        assert!(manifest.files.contains(&path_string(&target)));
        let deployed_names = super::deployed_file_names(&paths);
        assert!(deployed_names.contains("testweapon.pak"));
        assert!(deployed_names.contains("000_testweapon.pak"));

        assert_eq!(reclaim_mods(&paths).unwrap(), 1);
        assert!(!target.exists());
        assert!(!paths.deployment_manifest.exists());
        assert!(source.exists());
    }

    #[test]
    fn redeploys_after_reclaiming_when_retention_is_enabled() {
        let temp = TempRoot::new("deploy-retained-redeploy");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let pak_dir = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods");
        fs::create_dir_all(&pak_dir).unwrap();
        let first = paths.local_mods.join("First.pak");
        let second = paths.local_mods.join("Second.pak");
        fs::write(&first, b"first").unwrap();
        fs::write(&second, b"second").unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            keep_deployed_mods_on_exit: true,
            ..AppSettings::default()
        };

        deploy_local_mods(
            &paths,
            &settings,
            &[mod_entry(&first, true, "clientPak")],
            false,
        )
        .unwrap()
        .expect("first deployment should be created");
        let first_target = pak_dir.join("000_First.pak");
        assert!(first_target.exists());

        deploy_local_mods(
            &paths,
            &settings,
            &[mod_entry(&second, true, "clientPak")],
            false,
        )
        .unwrap()
        .expect("second deployment should be created");

        assert!(!first_target.exists());
        assert_eq!(fs::read(pak_dir.join("000_Second.pak")).unwrap(), b"second");
        let manifest = read_manifest(&paths).unwrap();
        assert!(!manifest
            .files
            .iter()
            .any(|path| path.ends_with("000_First.pak")));
    }

    #[test]
    fn deploys_only_the_canonical_entry_for_identical_pak_hashes() {
        let temp = TempRoot::new("deploy-duplicate-paks");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let pak_dir = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods");
        fs::create_dir_all(&pak_dir).unwrap();
        let alpha = paths.local_mods.join("Alpha.pak");
        let zeta = paths.local_mods.join("Zeta.pak");
        fs::write(&alpha, b"same-pak-content").unwrap();
        fs::write(&zeta, b"same-pak-content").unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };
        let hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let mut alpha_entry = mod_entry(&alpha, true, "clientPak");
        alpha_entry.sha256 = hash.to_string();
        let mut zeta_entry = mod_entry(&zeta, true, "clientPak");
        zeta_entry.sha256 = hash.to_string();

        deploy_local_mods(&paths, &settings, &[alpha_entry, zeta_entry], false).unwrap();

        assert!(pak_dir.join("000_Alpha.pak").is_file());
        assert!(!pak_dir.join("001_Zeta.pak").exists());
        let manifest = read_manifest(&paths).unwrap();
        assert_eq!(manifest.files.len(), 1);
        assert!(manifest.files[0].ends_with("000_Alpha.pak"));
    }

    #[test]
    fn deploys_client_paks_with_load_order_prefixes() {
        let temp = TempRoot::new("deploy-load-order-prefixes");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let pak_dir = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods");
        fs::create_dir_all(&pak_dir).unwrap();
        let alpha = paths.local_mods.join("Alpha.pak");
        let beta = paths.local_mods.join("Beta.pak");
        let gamma = paths.local_mods.join("Gamma.pak");
        fs::write(&alpha, b"alpha").unwrap();
        fs::write(&beta, b"beta").unwrap();
        fs::write(&gamma, b"gamma").unwrap();
        let mut alpha_mod = mod_entry(&alpha, true, "clientPak");
        alpha_mod.load_order = 2;
        let mut beta_mod = mod_entry(&beta, true, "clientPak");
        beta_mod.load_order = 0;
        let mut gamma_mod = mod_entry(&gamma, true, "clientPak");
        gamma_mod.load_order = 1;
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };

        deploy_local_mods(&paths, &settings, &[alpha_mod, gamma_mod, beta_mod], false).unwrap();

        assert_eq!(fs::read(pak_dir.join("000_Beta.pak")).unwrap(), b"beta");
        assert_eq!(fs::read(pak_dir.join("001_Gamma.pak")).unwrap(), b"gamma");
        assert_eq!(fs::read(pak_dir.join("002_Alpha.pak")).unwrap(), b"alpha");
        assert_eq!(fs::read(&alpha).unwrap(), b"alpha");
        assert_eq!(fs::read(&beta).unwrap(), b"beta");
        assert_eq!(fs::read(&gamma).unwrap(), b"gamma");
        assert!(super::deployed_file_names(&paths).contains("alpha.pak"));
        assert!(super::deployed_file_names(&paths).contains("beta.pak"));
        assert!(super::deployed_file_names(&paths).contains("gamma.pak"));
    }

    #[test]
    fn merges_conflicting_paks_into_one_deployed_file() {
        let temp = TempRoot::new("deploy-conflict-merge");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let pak_dir = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods");
        fs::create_dir_all(&pak_dir).unwrap();
        let alpha = build_test_pak(
            temp.path(),
            &paths,
            "Alpha",
            &[
                ("SCUM/Content/Assets/Shared.uasset", b"alpha-uasset"),
                ("SCUM/Content/Assets/Shared.uexp", b"alpha-uexp"),
                ("SCUM/Content/Assets/AlphaOnly.txt", b"alpha-only"),
            ],
        );
        let beta = build_test_pak(
            temp.path(),
            &paths,
            "Beta",
            &[
                ("SCUM/Content/Assets/Shared.uasset", b"beta-uasset"),
                ("SCUM/Content/Assets/Shared.uexp", b"beta-uexp"),
                ("SCUM/Content/Assets/BetaOnly.txt", b"beta-only"),
            ],
        );
        let mut alpha_mod = mod_entry(&alpha, true, "clientPak");
        alpha_mod.load_order = 0;
        let mut beta_mod = mod_entry(&beta, true, "clientPak");
        beta_mod.load_order = 1;
        let mut metadata = MetadataFile::default();
        metadata.entry_mut(&alpha_mod.id).pak_entries = vec![
            "SCUM/Content/Assets/Shared.uasset".to_string(),
            "SCUM/Content/Assets/Shared.uexp".to_string(),
            "SCUM/Content/Assets/AlphaOnly.txt".to_string(),
        ];
        metadata.entry_mut(&beta_mod.id).pak_entries = vec![
            "SCUM/Content/Assets/Shared.uasset".to_string(),
            "SCUM/Content/Assets/Shared.uexp".to_string(),
            "SCUM/Content/Assets/BetaOnly.txt".to_string(),
        ];
        save_metadata(&paths, &metadata).unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };

        deploy_local_mods(&paths, &settings, &[alpha_mod, beta_mod], false).unwrap();

        assert!(!pak_dir.join("000_Alpha.pak").exists());
        assert!(!pak_dir.join("001_Beta.pak").exists());
        let merged = pak_dir.join(super::CONFLICT_MERGED_FILE);
        assert!(merged.is_file());
        assert_eq!(
            read_pak_file(&paths, &merged, "SCUM/Content/Assets/Shared.uasset"),
            b"beta-uasset"
        );
        assert_eq!(
            read_pak_file(&paths, &merged, "SCUM/Content/Assets/Shared.uexp"),
            b"beta-uexp"
        );
        assert_eq!(
            read_pak_file(&paths, &merged, "SCUM/Content/Assets/AlphaOnly.txt"),
            b"alpha-only"
        );
        assert_eq!(
            read_pak_file(&paths, &merged, "SCUM/Content/Assets/BetaOnly.txt"),
            b"beta-only"
        );
        let manifest = read_manifest(&paths).expect("deployment manifest should exist");
        assert_eq!(manifest.files, vec![path_string(&merged)]);
    }

    #[test]
    fn merged_pak_prefix_stays_after_large_numeric_ranges() {
        let width = super::deployment_prefix_width(1000);
        let last_pak = super::numbered_pak_file_name(999, "Last.pak", width);
        let merged_pak = super::conflict_merged_file_name(1000);

        assert_eq!(width, 4);
        assert_eq!(last_pak, "0999_Last.pak");
        assert_eq!(merged_pak, "9999_SCUM_Mod_Desk_Merged.pak");
        assert!(last_pak < merged_pak);
    }

    #[test]
    fn selected_conflict_winner_is_written_to_the_merged_pak() {
        let temp = TempRoot::new("deploy-conflict-winner");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let pak_dir = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods");
        fs::create_dir_all(&pak_dir).unwrap();
        let alpha = build_test_pak(
            temp.path(),
            &paths,
            "Alpha",
            &[
                ("SCUM/Content/Assets/Shared.uasset", b"alpha-uasset"),
                ("SCUM/Content/Assets/Shared.uexp", b"alpha-uexp"),
            ],
        );
        let beta = build_test_pak(
            temp.path(),
            &paths,
            "Beta",
            &[
                ("SCUM/Content/Assets/Shared.uasset", b"beta-uasset"),
                ("SCUM/Content/Assets/Shared.uexp", b"beta-uexp"),
            ],
        );
        let mut alpha_mod = mod_entry(&alpha, true, "clientPak");
        alpha_mod.load_order = 0;
        let mut beta_mod = mod_entry(&beta, true, "clientPak");
        beta_mod.load_order = 1;
        let mut metadata = MetadataFile::default();
        metadata.entry_mut(&alpha_mod.id).pak_entries = vec![
            "SCUM/Content/Assets/Shared.uasset".to_string(),
            "SCUM/Content/Assets/Shared.uexp".to_string(),
        ];
        metadata.entry_mut(&beta_mod.id).pak_entries = vec![
            "SCUM/Content/Assets/Shared.uasset".to_string(),
            "SCUM/Content/Assets/Shared.uexp".to_string(),
        ];
        metadata.conflict_winners.insert(
            "scum/content/assets/shared".to_string(),
            alpha_mod.id.clone(),
        );
        save_metadata(&paths, &metadata).unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };

        deploy_local_mods(&paths, &settings, &[alpha_mod, beta_mod], false).unwrap();

        assert!(!pak_dir.join("000_Alpha.pak").exists());
        assert!(!pak_dir.join("001_Beta.pak").exists());
        let merged_pak = pak_dir.join(super::CONFLICT_MERGED_FILE);
        assert!(merged_pak.is_file());
        assert_eq!(
            read_pak_file(&paths, &merged_pak, "SCUM/Content/Assets/Shared.uasset"),
            b"alpha-uasset"
        );
        assert_eq!(
            read_pak_file(&paths, &merged_pak, "SCUM/Content/Assets/Shared.uexp"),
            b"alpha-uexp"
        );
        let manifest = read_manifest(&paths).unwrap();
        assert_eq!(manifest.files, vec![path_string(&merged_pak)]);
        assert!(!paths.root.join("~merged").exists());

        reclaim_mods(&paths).unwrap();
        assert!(!merged_pak.exists());
        assert!(!paths.deployment_manifest.exists());
    }

    #[test]
    fn invalid_custom_winner_blocks_deployment_and_cleans_staging() {
        let temp = TempRoot::new("deploy-conflict-winner-failure");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let pak_dir = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods");
        fs::create_dir_all(&pak_dir).unwrap();
        let alpha = build_test_pak(
            temp.path(),
            &paths,
            "Alpha",
            &[("SCUM/Content/Assets/Shared.uasset", b"alpha")],
        );
        let beta = build_test_pak(
            temp.path(),
            &paths,
            "Beta",
            &[
                ("SCUM/Content/Assets/Shared.uasset", b"beta"),
                ("SCUM/Content/Assets/Shared.uexp", b"beta-sidecar"),
            ],
        );
        let mut alpha_mod = mod_entry(&alpha, true, "clientPak");
        alpha_mod.load_order = 0;
        let mut beta_mod = mod_entry(&beta, true, "clientPak");
        beta_mod.load_order = 1;
        let mut metadata = MetadataFile::default();
        metadata.entry_mut(&alpha_mod.id).pak_entries =
            vec!["SCUM/Content/Assets/Shared.uasset".to_string()];
        metadata.entry_mut(&beta_mod.id).pak_entries = vec![
            "SCUM/Content/Assets/Shared.uasset".to_string(),
            "SCUM/Content/Assets/Shared.uexp".to_string(),
        ];
        metadata.conflict_winners.insert(
            "scum/content/assets/shared".to_string(),
            alpha_mod.id.clone(),
        );
        save_metadata(&paths, &metadata).unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };

        let error =
            deploy_local_mods(&paths, &settings, &[alpha_mod, beta_mod], false).unwrap_err();

        assert!(error.to_string().contains("缺少资源"));
        assert!(!pak_dir.join("000_Alpha.pak").exists());
        assert!(!pak_dir.join("001_Beta.pak").exists());
        assert!(!pak_dir.join(super::CONFLICT_MERGED_FILE).exists());
        assert!(!paths.deployment_manifest.exists());
        assert!(!paths.root.join("~merged").exists());
    }

    #[test]
    fn deploys_ue4ss_framework_and_mod_then_reclaims_game_copy() {
        let temp = TempRoot::new("deploy-ue4ss");
        let paths = temp.paths();
        write_framework_archive(&paths);
        let install = temp.path().join("fake-scum");
        let binaries = install.join("SCUM").join("Binaries").join("Win64");
        fs::create_dir_all(&binaries).unwrap();
        let source = paths.ue4ss_mods.join("BetterAI");
        fs::create_dir_all(source.join("Scripts")).unwrap();
        fs::write(source.join("Scripts").join("main.lua"), b"print('ok')").unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };
        let mods = vec![mod_entry(&source, true, "ue4ssMod")];

        let deployed_at = deploy_local_mods(&paths, &settings, &mods, false)
            .unwrap()
            .expect("UE4SS mod should be deployed");

        let ue4ss_target = binaries.join("ue4ss");
        let mods_txt = ue4ss_target.join("Mods").join("mods.txt");
        let deployed_mod = ue4ss_target
            .join("Mods")
            .join("BetterAI")
            .join("Scripts")
            .join("main.lua");
        assert_eq!(fs::read(binaries.join("dwmapi.dll")).unwrap(), b"proxy");
        assert_eq!(fs::read(ue4ss_target.join("UE4SS.dll")).unwrap(), b"loader");
        assert_eq!(
            fs::read(ue4ss_target.join("UE4SS-settings.ini")).unwrap(),
            b"[General]\n"
        );
        assert_eq!(fs::read(&deployed_mod).unwrap(), b"print('ok')");
        assert!(fs::read_to_string(&mods_txt)
            .unwrap()
            .contains("BetterAI : 1"));
        assert!(paths
            .ue4ss_runtime
            .join("ue4ss")
            .join("UE4SS.dll")
            .is_file());

        let manifest = read_manifest(&paths).expect("deployment manifest should exist");
        assert_eq!(manifest.deployed_at, deployed_at);
        assert!(manifest.files.contains(&path_string(&deployed_mod)));

        assert!(reclaim_mods(&paths).unwrap() >= 6);
        assert!(!binaries.join("dwmapi.dll").exists());
        assert!(!ue4ss_target.join("UE4SS.dll").exists());
        assert!(!deployed_mod.exists());
        assert!(!paths.deployment_manifest.exists());
        assert!(source.join("Scripts").join("main.lua").exists());
        assert!(paths
            .ue4ss_runtime
            .join("ue4ss")
            .join("UE4SS.dll")
            .is_file());
    }

    #[test]
    fn reclaim_removes_runtime_logs_and_the_deployed_ue4ss_directory() {
        let temp = TempRoot::new("reclaim-ue4ss-runtime-log");
        let paths = temp.paths();
        write_framework_archive(&paths);
        let install = temp.path().join("fake-scum");
        let binaries = install.join("SCUM").join("Binaries").join("Win64");
        fs::create_dir_all(&binaries).unwrap();
        let source = paths.ue4ss_mods.join("BetterAI");
        fs::create_dir_all(source.join("Scripts")).unwrap();
        fs::write(source.join("Scripts").join("main.lua"), b"print('ok')").unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };

        deploy_local_mods(
            &paths,
            &settings,
            &[mod_entry(&source, true, "ue4ssMod")],
            false,
        )
        .unwrap();

        let ue4ss_target = binaries.join("ue4ss");
        fs::write(ue4ss_target.join("UE4SS.log"), b"runtime log").unwrap();
        reclaim_mods(&paths).unwrap();

        assert!(!ue4ss_target.exists());
        assert!(!paths.deployment_manifest.exists());
    }

    #[test]
    fn reclaim_cleans_legacy_ue4ss_runtime_logs_from_an_old_manifest() {
        let temp = TempRoot::new("reclaim-legacy-ue4ss-log");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let ue4ss_target = install
            .join("SCUM")
            .join("Binaries")
            .join("Win64")
            .join("ue4ss");
        fs::create_dir_all(&ue4ss_target).unwrap();
        fs::write(ue4ss_target.join("UE4SS.log"), b"runtime log").unwrap();
        let manifest = DeployedManifest {
            deployed_at: "2026-01-01T00:00:00Z".to_string(),
            roots: vec![path_string(&install)],
            files: Vec::new(),
            directories: vec![path_string(&ue4ss_target)],
            created_directories: Vec::new(),
            backups: Vec::new(),
        };
        fs::write(
            &paths.deployment_manifest,
            serde_json::to_string_pretty(&manifest).unwrap(),
        )
        .unwrap();

        assert_eq!(reclaim_mods(&paths).unwrap(), 0);

        assert!(!ue4ss_target.exists());
        assert!(!paths.deployment_manifest.exists());
    }

    #[test]
    fn reclaim_preserves_unmanaged_files_in_a_preexisting_ue4ss_directory() {
        let temp = TempRoot::new("reclaim-ue4ss-unmanaged");
        let paths = temp.paths();
        write_framework_archive(&paths);
        let install = temp.path().join("fake-scum");
        let binaries = install.join("SCUM").join("Binaries").join("Win64");
        let ue4ss_target = binaries.join("ue4ss");
        fs::create_dir_all(&ue4ss_target).unwrap();
        fs::write(ue4ss_target.join("keep.txt"), b"user data").unwrap();
        let source = paths.ue4ss_mods.join("BetterAI");
        fs::create_dir_all(source.join("Scripts")).unwrap();
        fs::write(source.join("Scripts").join("main.lua"), b"print('ok')").unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };

        deploy_local_mods(
            &paths,
            &settings,
            &[mod_entry(&source, true, "ue4ssMod")],
            false,
        )
        .unwrap();
        fs::write(ue4ss_target.join("UE4SS.log"), b"runtime log").unwrap();

        reclaim_mods(&paths).unwrap();

        assert_eq!(
            fs::read(ue4ss_target.join("keep.txt")).unwrap(),
            b"user data"
        );
        assert!(!ue4ss_target.join("UE4SS.log").exists());
        assert!(!paths.deployment_manifest.exists());
    }

    #[test]
    fn bundled_ue4ss_framework_contains_runtime_files() {
        let archive_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("resources")
            .join("ue4ss_framework.zip");
        let bytes = fs::metadata(&archive_path)
            .expect("bundled UE4SS framework is missing")
            .len();
        assert!(
            bytes > 1_000_000,
            "bundled UE4SS framework looks like a test fixture: {bytes} bytes"
        );

        let archive = zip::ZipArchive::new(File::open(archive_path).unwrap()).unwrap();
        let names = archive
            .file_names()
            .map(|name| name.replace('\\', "/"))
            .collect::<std::collections::HashSet<_>>();
        for required in [
            "ue4ss/LICENSE",
            "ue4ss/UE4SS.dll",
            "ue4ss/UE4SS-settings.ini",
            "ue4ss/UE4SS-settings-SCUM.ini",
            "ue4ss/Mods/mods.json",
            "ue4ss/Mods/mods.txt",
            "dwmapi.dll",
        ] {
            assert!(names.contains(required), "missing {required}");
        }
    }

    #[test]
    fn reclaim_ignores_manifest_entries_outside_declared_roots() {
        let temp = TempRoot::new("reclaim-outside");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        fs::create_dir_all(&install).unwrap();
        let outside = temp.path().join("outside").join("keep.pak");
        fs::create_dir_all(outside.parent().unwrap()).unwrap();
        fs::write(&outside, b"keep").unwrap();
        let manifest = DeployedManifest {
            deployed_at: "2026-01-01T00:00:00Z".to_string(),
            roots: vec![path_string(&install)],
            files: vec![path_string(&outside)],
            directories: Vec::new(),
            created_directories: Vec::new(),
            backups: Vec::new(),
        };
        fs::write(
            &paths.deployment_manifest,
            serde_json::to_string_pretty(&manifest).unwrap(),
        )
        .unwrap();

        assert_eq!(reclaim_mods(&paths).unwrap(), 0);
        assert!(outside.exists());
    }

    #[test]
    fn reclaim_ignores_parent_directory_escape_in_manifest() {
        let temp = TempRoot::new("reclaim-parent-escape");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let outside = temp.path().join("outside").join("keep.pak");
        fs::create_dir_all(&install).unwrap();
        fs::create_dir_all(outside.parent().unwrap()).unwrap();
        fs::write(&outside, b"keep").unwrap();
        let escaping = install.join("..").join("outside").join("keep.pak");
        let manifest = DeployedManifest {
            deployed_at: "2026-01-01T00:00:00Z".to_string(),
            roots: vec![path_string(&install)],
            files: vec![path_string(&escaping)],
            directories: Vec::new(),
            created_directories: Vec::new(),
            backups: Vec::new(),
        };
        fs::write(
            &paths.deployment_manifest,
            serde_json::to_string_pretty(&manifest).unwrap(),
        )
        .unwrap();

        assert_eq!(reclaim_mods(&paths).unwrap(), 0);
        assert!(outside.exists());
    }

    #[test]
    fn restores_files_that_were_overwritten_by_framework_deployment() {
        let temp = TempRoot::new("deploy-backup-restore");
        let paths = temp.paths();
        write_framework_archive(&paths);
        let install = temp.path().join("fake-scum");
        let binaries = install.join("SCUM").join("Binaries").join("Win64");
        fs::create_dir_all(&binaries).unwrap();
        fs::write(binaries.join("dwmapi.dll"), b"original-proxy").unwrap();
        let source = paths.ue4ss_mods.join("BetterAI");
        fs::create_dir_all(source.join("Scripts")).unwrap();
        fs::write(source.join("Scripts").join("main.lua"), b"print('ok')").unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };

        deploy_local_mods(
            &paths,
            &settings,
            &[mod_entry(&source, true, "ue4ssMod")],
            false,
        )
        .unwrap();
        assert_eq!(fs::read(binaries.join("dwmapi.dll")).unwrap(), b"proxy");
        let manifest = read_manifest(&paths).unwrap();
        assert_eq!(manifest.backups.len(), 1);
        assert!(Path::new(&manifest.backups[0].backup).is_file());

        reclaim_mods(&paths).unwrap();

        assert_eq!(
            fs::read(binaries.join("dwmapi.dll")).unwrap(),
            b"original-proxy"
        );
        assert!(!Path::new(&manifest.backups[0].backup).exists());
        assert!(!paths.deployment_manifest.exists());
    }

    #[test]
    fn rolls_back_files_copied_before_a_later_deployment_error() {
        let temp = TempRoot::new("deploy-partial-rollback");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let pak_dir = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods");
        fs::create_dir_all(&pak_dir).unwrap();
        let first = paths.local_mods.join("First.pak");
        let second = paths.local_mods.join("Second.pak");
        fs::write(&first, b"first").unwrap();
        fs::write(&second, b"second").unwrap();
        fs::create_dir_all(pak_dir.join("001_Second.pak")).unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };
        let mods = vec![
            mod_entry(&first, true, "clientPak"),
            mod_entry(&second, true, "clientPak"),
        ];

        let error = deploy_local_mods(&paths, &settings, &mods, false).unwrap_err();

        assert!(error.to_string().contains("不是文件"));
        assert!(!pak_dir.join("000_First.pak").exists());
        assert!(pak_dir.join("001_Second.pak").is_dir());
        assert!(!paths.deployment_manifest.exists());
    }

    #[test]
    fn reclaim_keeps_manifest_when_a_deployed_file_cannot_be_removed() {
        let temp = TempRoot::new("reclaim-failure");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let undeletable = install.join("locked.pak");
        fs::create_dir_all(&undeletable).unwrap();
        let manifest = DeployedManifest {
            deployed_at: "2026-01-01T00:00:00Z".to_string(),
            roots: vec![path_string(&install)],
            files: vec![path_string(&undeletable)],
            directories: Vec::new(),
            created_directories: Vec::new(),
            backups: Vec::new(),
        };
        fs::write(
            &paths.deployment_manifest,
            serde_json::to_string_pretty(&manifest).unwrap(),
        )
        .unwrap();

        let error = reclaim_mods(&paths).unwrap_err().to_string();

        assert!(error.contains("回收未完成"));
        let remaining = read_manifest(&paths).expect("failed manifest must remain");
        assert_eq!(remaining.files, vec![path_string(&undeletable)]);
    }

    #[test]
    fn rescue_never_overwrites_an_existing_local_pak() {
        let temp = TempRoot::new("rescue-no-overwrite");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let pak_dir = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods");
        fs::create_dir_all(&pak_dir).unwrap();
        fs::write(pak_dir.join("Shared.pak"), b"from-game").unwrap();
        fs::write(paths.local_mods.join("Shared.pak"), b"local-copy").unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };

        let result = rescue_mods_from_game(&paths, &settings).unwrap();

        assert_eq!(result.rescued, 0);
        assert_eq!(result.skipped, 1);
        assert_eq!(
            fs::read(paths.local_mods.join("Shared.pak")).unwrap(),
            b"local-copy"
        );
    }

    #[test]
    fn rescue_skips_files_owned_by_the_deployment_manifest() {
        let temp = TempRoot::new("rescue-managed-deploy-prefix");
        let paths = temp.paths();
        let install = temp.path().join("fake-scum");
        let pak_dir = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods");
        fs::create_dir_all(&pak_dir).unwrap();
        let managed = pak_dir.join("000_Managed.pak");
        fs::write(&managed, b"managed").unwrap();
        let manifest = DeployedManifest {
            deployed_at: "2026-01-01T00:00:00Z".to_string(),
            roots: vec![path_string(&install)],
            files: vec![path_string(&managed)],
            directories: Vec::new(),
            created_directories: Vec::new(),
            backups: Vec::new(),
        };
        fs::write(
            &paths.deployment_manifest,
            serde_json::to_string_pretty(&manifest).unwrap(),
        )
        .unwrap();
        let settings = AppSettings {
            scum_install_path: path_string(&install),
            ..AppSettings::default()
        };

        let result = rescue_mods_from_game(&paths, &settings).unwrap();

        assert_eq!(result.rescued, 0);
        assert_eq!(result.skipped, 0);
        assert!(!paths.local_mods.join("000_Managed.pak").exists());
    }

    #[test]
    fn ue4ss_mods_txt_preserves_unmanaged_lines_and_replaces_stale_entries() {
        let temp = TempRoot::new("ue4ss-mods-txt");
        let paths = temp.paths();
        let mods_txt = paths.ue4ss_mods.join("mods.txt");
        let managed_path = paths.ue4ss_mods.join(".scum_mm_managed.txt");
        fs::write(&mods_txt, "OtherMod : 1\nOldManaged : 0\nKeybinds : 1\n").unwrap();
        fs::write(
            &managed_path,
            base64::engine::general_purpose::STANDARD.encode("OldManaged"),
        )
        .unwrap();
        let enabled = temp.path().join("EnabledMod");
        let disabled = temp.path().join("DisabledMod");
        fs::create_dir_all(&enabled).unwrap();
        fs::create_dir_all(&disabled).unwrap();
        let mods = vec![
            mod_entry(&enabled, true, "ue4ssMod"),
            mod_entry(&disabled, false, "ue4ssMod"),
        ];

        sync_ue4ss_state(&paths, &mods).unwrap();

        let lines: Vec<String> = fs::read_to_string(&mods_txt)
            .unwrap()
            .lines()
            .map(ToString::to_string)
            .collect();
        assert_eq!(
            lines,
            vec![
                "OtherMod : 1",
                "EnabledMod : 1",
                "DisabledMod : 0",
                "Keybinds : 1"
            ]
        );
        let managed = fs::read_to_string(&managed_path).unwrap();
        assert!(managed.contains(&base64::engine::general_purpose::STANDARD.encode("EnabledMod")));
        assert!(managed.contains(&base64::engine::general_purpose::STANDARD.encode("DisabledMod")));
        assert!(!managed.contains("OldManaged"));
    }

    fn build_test_pak(
        root: &Path,
        paths: &crate::paths::AppPaths,
        label: &str,
        entries: &[(&str, &[u8])],
    ) -> PathBuf {
        let input = root.join(format!("{label}-input"));
        for (relative, body) in entries {
            let path = input.join(relative.replace('/', std::path::MAIN_SEPARATOR_STR));
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, body).unwrap();
        }
        let pak = root.join(format!("{label}.pak"));
        let output = Command::new(paths.resource("repak.exe"))
            .arg("pack")
            .arg("-m")
            .arg("../../../")
            .arg(&input)
            .arg(&pak)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "repak pack failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        pak
    }

    fn read_pak_file(paths: &crate::paths::AppPaths, pak: &Path, resource: &str) -> Vec<u8> {
        let output = Command::new(paths.resource("repak.exe"))
            .arg("get")
            .arg("--")
            .arg(pak)
            .arg(resource)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "repak get failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        output.stdout
    }
}
