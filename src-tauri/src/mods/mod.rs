use crate::metadata::MetadataFile;
use crate::models::{ConflictGroup, ImportConflict, ImportResult, ModEntry};
use crate::paths::{path_string, safe_disk_name, AppPaths};
use anyhow::{Context, Result};
use base64::Engine;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use walkdir::WalkDir;
use zip::ZipArchive;

pub mod deploy;
mod duplicates;
mod pak_scan;

pub use pak_scan::PakScanDiagnostic;
pub(crate) use pak_scan::{analyze_conflicts, validate_conflict_winners};

#[derive(Debug, Default)]
pub struct LocalScanResult {
    pub mods: Vec<ModEntry>,
    pub diagnostics: Vec<PakScanDiagnostic>,
}

const MAX_COVER_BYTES: u64 = 2 * 1024 * 1024;
const MAX_PRESENTATION_BYTES: u64 = 64 * 1024;
const COVER_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "webp"];

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PresentationFile {
    author: Option<String>,
    cover: Option<String>,
    description: Option<String>,
}

#[derive(Debug, Default)]
struct Presentation {
    author: String,
    cover_url: Option<String>,
    description: String,
}

#[cfg(test)]
pub fn scan_local_mods(
    paths: &AppPaths,
    metadata: &mut MetadataFile,
    deployed_names: &HashSet<String>,
) -> Result<Vec<ModEntry>> {
    Ok(scan_local_mods_with_diagnostics(paths, metadata, deployed_names)?.mods)
}

pub fn scan_local_mods_with_diagnostics(
    paths: &AppPaths,
    metadata: &mut MetadataFile,
    deployed_names: &HashSet<String>,
) -> Result<LocalScanResult> {
    let mut mods = Vec::new();
    let mut diagnostics = Vec::new();

    if paths.local_mods.exists() {
        for entry in std::fs::read_dir(&paths.local_mods)? {
            let entry = entry?;
            let path = entry.path();
            if !path.is_file() || !is_pak(&path) {
                continue;
            }
            mods.push(build_file_mod(
                paths,
                metadata,
                deployed_names,
                &path,
                "clientPak",
                &mut diagnostics,
            )?);
        }
    }

    if paths.ue4ss_mods.exists() {
        for entry in std::fs::read_dir(&paths.ue4ss_mods)? {
            let entry = entry?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            mods.push(build_directory_mod(paths, metadata, deployed_names, &path)?);
        }
    }

    duplicates::promote_duplicate_metadata(&mods, metadata);
    let mut mods = duplicates::collapse_identical_mods(mods, metadata);
    let order: HashMap<&str, usize> = metadata
        .order
        .iter()
        .enumerate()
        .map(|(index, id)| (id.as_str(), index))
        .collect();
    mods.sort_by(|left, right| {
        order
            .get(left.id.as_str())
            .copied()
            .unwrap_or(usize::MAX)
            .cmp(&order.get(right.id.as_str()).copied().unwrap_or(usize::MAX))
            .then_with(|| {
                left.name
                    .to_ascii_lowercase()
                    .cmp(&right.name.to_ascii_lowercase())
            })
    });
    for (index, item) in mods.iter_mut().enumerate() {
        item.load_order = index;
    }
    refresh_conflicts(metadata, &mut mods);
    metadata.order = mods.iter().map(|item| item.id.clone()).collect();
    Ok(LocalScanResult { mods, diagnostics })
}

fn build_file_mod(
    paths: &AppPaths,
    metadata: &mut MetadataFile,
    deployed_names: &HashSet<String>,
    path: &Path,
    mod_type: &str,
    diagnostics: &mut Vec<PakScanDiagnostic>,
) -> Result<ModEntry> {
    let file_name = path
        .file_name()
        .context("模组文件缺少文件名")?
        .to_string_lossy()
        .into_owned();
    let id = stable_id(&paths.local_mods, &file_name);
    let file_size = std::fs::metadata(path)?.len();
    let modified = std::fs::metadata(path)?.modified().unwrap_or(UNIX_EPOCH);
    let modified_at = epoch_millis(modified);
    let meta = metadata.entry_mut(&id);
    let identity_matches =
        meta.file_size == Some(file_size) && meta.modified_at == Some(modified_at);
    if let Some(error) = pak_scan::refresh_pak_cache(meta, file_size, modified_at, || {
        pak_scan::list_pak_entries(paths, path)
    }) {
        diagnostics.push(PakScanDiagnostic {
            mod_id: id.clone(),
            file_name: file_name.clone(),
            message: error,
        });
    }
    if !meta.sha256.is_empty() && identity_matches {
        // Reuse the cached digest when file identity did not change.
    } else {
        meta.sha256 = compute_sha256(path).unwrap_or_default();
    }

    let name = meta
        .name
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| {
            path.file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned()
        });
    let tags = meta.tags.clone();
    let notes = meta.notes.clone();
    let enabled = meta.enabled;
    let sha256 = meta.sha256.clone();
    let conflict_count = meta.conflicts.len();
    let presentation =
        read_presentation(path.parent().unwrap_or(&paths.local_mods), Some(&file_name));

    Ok(ModEntry {
        id,
        name: name.clone(),
        author: presentation.author.clone(),
        file_name: file_name.clone(),
        file_path: path_string(path),
        file_size,
        last_modified: iso_time(modified),
        enabled,
        mod_type: mod_type.to_string(),
        load_order: 0,
        tags,
        notes,
        sha256,
        origin_source: "local".to_string(),
        deployed: deployed_names.contains(&file_name.to_ascii_lowercase()),
        description: if presentation.description.is_empty() {
            infer_description(&name, mod_type)
        } else {
            presentation.description
        },
        conflict_count,
        file_count: 0,
        overridden_file_count: 0,
        overriding_file_count: 0,
        fully_overridden: false,
        update_version: None,
        cover_url: presentation.cover_url,
        duplicate_count: 0,
        duplicate_aliases: Vec::new(),
    })
}

fn apply_conflicts(metadata: &mut MetadataFile, analysis: &pak_scan::ConflictAnalysis) {
    for entry in metadata.entries.values_mut() {
        entry.conflicts.clear();
    }
    for (id, entry_conflicts) in &analysis.entry_conflicts {
        if let Some(entry) = metadata.entries.get_mut(id) {
            entry.conflicts = entry_conflicts.clone();
        }
    }
}

/// Recompute conflict metadata and mirror the counts into the current entries.
///
/// This is also used after toggling a mod so the UI does not keep stale conflict
/// counts until the next full library scan.
pub fn refresh_conflicts(metadata: &mut MetadataFile, mods: &mut [ModEntry]) -> Vec<ConflictGroup> {
    let analysis = pak_scan::analyze_conflicts(metadata, mods);
    metadata.conflict_winners.retain(|key, winner| {
        analysis
            .groups
            .iter()
            .any(|group| group.key == *key && group.owners.iter().any(|owner| owner.id == *winner))
    });
    apply_conflicts(metadata, &analysis);
    for item in mods {
        let stats = analysis.stats.get(&item.id).copied().unwrap_or_default();
        item.file_count = stats.file_count;
        item.overridden_file_count = stats.overridden_file_count;
        item.overriding_file_count = stats.overriding_file_count;
        item.fully_overridden = stats.fully_overridden;
        item.conflict_count = stats.overridden_file_count + stats.overriding_file_count;
    }
    analysis.groups
}

fn build_directory_mod(
    paths: &AppPaths,
    metadata: &mut MetadataFile,
    deployed_names: &HashSet<String>,
    path: &Path,
) -> Result<ModEntry> {
    let file_name = path
        .file_name()
        .context("UE4SS 模组缺少目录名")?
        .to_string_lossy()
        .into_owned();
    let id = stable_id(&paths.ue4ss_mods, &file_name);
    let file_size = directory_size(path);
    let modified = std::fs::metadata(path)?.modified().unwrap_or(UNIX_EPOCH);
    let meta = metadata.entry_mut(&id);
    meta.file_size = Some(file_size);
    meta.modified_at = Some(epoch_millis(modified));
    let name = meta
        .name
        .clone()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| file_name.clone());
    let tags = meta.tags.clone();
    let notes = meta.notes.clone();
    let enabled = meta.enabled;
    let conflict_count = meta.conflicts.len();
    let presentation = read_presentation(path, None);

    Ok(ModEntry {
        id,
        name: name.clone(),
        author: presentation.author.clone(),
        file_name: file_name.clone(),
        file_path: path_string(path),
        file_size,
        last_modified: iso_time(modified),
        enabled,
        mod_type: "ue4ssMod".to_string(),
        load_order: 0,
        tags,
        notes,
        sha256: String::new(),
        origin_source: "local".to_string(),
        deployed: deployed_names.contains(&file_name.to_ascii_lowercase()),
        description: if presentation.description.is_empty() {
            infer_description(&file_name, "ue4ssMod")
        } else {
            presentation.description
        },
        conflict_count,
        file_count: 0,
        overridden_file_count: 0,
        overriding_file_count: 0,
        fully_overridden: false,
        update_version: None,
        cover_url: presentation.cover_url,
        duplicate_count: 0,
        duplicate_aliases: Vec::new(),
    })
}

fn read_presentation(root: &Path, pak_file_name: Option<&str>) -> Presentation {
    let presentation = read_presentation_json(root, pak_file_name);
    let mut result = Presentation {
        author: presentation
            .author
            .map(|value| clean_text(&value, 120))
            .unwrap_or_default(),
        cover_url: None,
        description: presentation
            .description
            .map(|value| clean_text(&value, 1200))
            .unwrap_or_default(),
    };
    let declared = presentation
        .cover
        .filter(|value| !value.trim().is_empty())
        .and_then(|value| safe_cover_name(&value));
    let discovered = declared
        .and_then(|name| cover_data_url(&root.join(name), root))
        .or_else(|| discover_cover(root, pak_file_name));
    result.cover_url = discovered;
    result
}

fn read_presentation_json(root: &Path, pak_file_name: Option<&str>) -> PresentationFile {
    let candidates: Vec<PathBuf> = match pak_file_name {
        Some(file_name) => {
            let stem = Path::new(file_name)
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            vec![
                root.join(format!("{stem}.mod.json")),
                root.join(format!("{stem}.presentation.json")),
            ]
        }
        None => vec![root.join("mod.json"), root.join("presentation.json")],
    };
    for path in candidates {
        let Ok(metadata) = std::fs::metadata(&path) else {
            continue;
        };
        if !metadata.is_file() || metadata.len() > MAX_PRESENTATION_BYTES {
            continue;
        }
        let Ok(bytes) = std::fs::read(&path) else {
            continue;
        };
        if let Ok(value) = serde_json::from_slice::<PresentationFile>(&bytes) {
            return value;
        }
    }
    PresentationFile::default()
}

fn clean_text(value: &str, max_chars: usize) -> String {
    value.trim().chars().take(max_chars).collect()
}

fn safe_cover_name(value: &str) -> Option<String> {
    let path = Path::new(value.trim());
    if path.is_absolute()
        || path.components().count() != 1
        || !matches!(path.components().next(), Some(Component::Normal(_)))
    {
        return None;
    }
    let extension = path
        .extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_ascii_lowercase();
    COVER_EXTENSIONS.contains(&extension.as_str()).then(|| {
        path.file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned()
    })
}

fn discover_cover(root: &Path, pak_file_name: Option<&str>) -> Option<String> {
    match pak_file_name {
        Some(file_name) => {
            let stem = Path::new(file_name)
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            for extension in COVER_EXTENSIONS {
                let candidate = root.join(format!("{stem}.cover.{extension}"));
                if candidate.is_file() {
                    if let Some(url) = cover_data_url(&candidate, root) {
                        return Some(url);
                    }
                }
            }
        }
        None => {
            for stem in ["cover", "preview"] {
                for extension in COVER_EXTENSIONS {
                    let candidate = root.join(format!("{stem}.{extension}"));
                    if candidate.is_file() {
                        if let Some(url) = cover_data_url(&candidate, root) {
                            return Some(url);
                        }
                    }
                }
            }
        }
    }
    None
}

fn cover_data_url(path: &Path, root: &Path) -> Option<String> {
    let canonical_root = root.canonicalize().ok()?;
    let canonical = path.canonicalize().ok()?;
    if !canonical.starts_with(&canonical_root) {
        return None;
    }
    let metadata = std::fs::metadata(&canonical).ok()?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_COVER_BYTES {
        return None;
    }
    let extension = canonical
        .extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_ascii_lowercase();
    if !COVER_EXTENSIONS.contains(&extension.as_str()) {
        return None;
    }
    let bytes = std::fs::read(&canonical).ok()?;
    let mime = image_mime(&extension, &bytes)?;
    Some(format!(
        "data:{mime};base64,{}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    ))
}

fn image_mime(extension: &str, bytes: &[u8]) -> Option<&'static str> {
    match extension {
        "png" if bytes.starts_with(b"\x89PNG\r\n\x1a\n") => Some("image/png"),
        "jpg" | "jpeg" if bytes.starts_with(b"\xff\xd8\xff") => Some("image/jpeg"),
        "webp" if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") => {
            Some("image/webp")
        }
        _ => None,
    }
}

pub fn stable_id(directory: &Path, name: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("{}|{}", path_string(directory), name).as_bytes());
    hex::encode(hasher.finalize())[..16].to_string()
}

pub fn compute_sha256(path: &Path) -> Result<String> {
    let file = File::open(path)?;
    let mut reader = BufReader::with_capacity(1024 * 1024, file);
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub fn inspect_import_conflicts(
    paths: &AppPaths,
    sources: &[String],
) -> Result<Vec<ImportConflict>> {
    let mut conflicts = Vec::new();
    let mut seen_targets = HashSet::new();
    for source in sources {
        let source = PathBuf::from(source);
        if !source.exists() {
            continue;
        }
        if source.is_dir() {
            let Some(file_name) = source.file_name() else {
                continue;
            };
            let target = paths.ue4ss_mods.join(file_name);
            push_import_conflict(
                &mut conflicts,
                &mut seen_targets,
                &source,
                &target,
                file_name.to_string_lossy().as_ref(),
            );
            continue;
        }
        match source
            .extension()
            .unwrap_or_default()
            .to_string_lossy()
            .to_ascii_lowercase()
            .as_str()
        {
            "pak" => {
                let Some(file_name) = source.file_name() else {
                    continue;
                };
                let target = paths.local_mods.join(file_name);
                push_import_conflict(
                    &mut conflicts,
                    &mut seen_targets,
                    &source,
                    &target,
                    file_name.to_string_lossy().as_ref(),
                );
            }
            "zip" => {
                for (target, file_name) in zip_import_targets(paths, &source)? {
                    if target.exists() {
                        push_import_conflict(
                            &mut conflicts,
                            &mut seen_targets,
                            &source,
                            &target,
                            &file_name,
                        );
                    }
                }
            }
            _ => {}
        }
    }
    Ok(conflicts)
}

fn push_import_conflict(
    conflicts: &mut Vec<ImportConflict>,
    seen_targets: &mut HashSet<String>,
    source: &Path,
    target: &Path,
    file_name: &str,
) {
    if !target.exists() || same_import_path(source, target) {
        return;
    }
    let target_key = target.to_string_lossy().to_ascii_lowercase();
    if !seen_targets.insert(target_key) {
        return;
    }
    conflicts.push(ImportConflict {
        source_path: path_string(source),
        file_name: file_name.to_string(),
        target_path: path_string(target),
    });
}

fn zip_import_targets(paths: &AppPaths, source: &Path) -> Result<Vec<(PathBuf, String)>> {
    let file = File::open(source)?;
    let mut archive = ZipArchive::new(file)?;
    let mut contains_pak = false;
    for index in 0..archive.len() {
        let entry = archive.by_index(index)?;
        if entry.name().to_ascii_lowercase().ends_with(".pak") {
            contains_pak = true;
            break;
        }
    }
    if contains_pak {
        let mut targets = Vec::new();
        for index in 0..archive.len() {
            let entry = archive.by_index(index)?;
            if entry.is_dir() || !is_pak_import_asset(entry.name()) {
                continue;
            }
            let Some(relative) = entry.enclosed_name() else {
                continue;
            };
            let Some(file_name) = relative.file_name() else {
                continue;
            };
            targets.push((
                paths.local_mods.join(file_name),
                file_name.to_string_lossy().into_owned(),
            ));
        }
        return Ok(targets);
    }

    let wrapper = zip_wrapper_directory(&mut archive)?;
    let raw_name = wrapper
        .or_else(|| {
            source
                .file_stem()
                .map(|value| value.to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| "mod".to_string());
    let folder_name = safe_disk_name(&raw_name, "mod");
    Ok(vec![(paths.ue4ss_mods.join(&folder_name), folder_name)])
}

fn same_import_path(left: &Path, right: &Path) -> bool {
    let left = std::path::absolute(left).unwrap_or_else(|_| left.to_path_buf());
    let right = std::path::absolute(right).unwrap_or_else(|_| right.to_path_buf());
    left.to_string_lossy()
        .eq_ignore_ascii_case(&right.to_string_lossy())
}

pub fn import_paths(paths: &AppPaths, sources: &[String], replace: bool) -> Result<ImportResult> {
    let mut imported = 0;
    let mut skipped = 0;
    for source in sources {
        let source = PathBuf::from(source);
        if !source.exists() {
            skipped += 1;
            continue;
        }
        if source.is_dir() {
            let destination = paths
                .ue4ss_mods
                .join(source.file_name().unwrap_or_default());
            if destination.exists() {
                if !replace || same_import_path(&source, &destination) {
                    skipped += 1;
                    continue;
                }
                replace_imported_directory(paths, &source, &destination)?;
            } else {
                copy_tree(&source, &destination)?;
            }
            imported += 1;
            continue;
        }

        match source
            .extension()
            .unwrap_or_default()
            .to_string_lossy()
            .to_ascii_lowercase()
            .as_str()
        {
            "pak" => {
                let destination = paths
                    .local_mods
                    .join(source.file_name().context("导入文件缺少文件名")?);
                if destination.exists() {
                    if !replace || same_import_path(&source, &destination) {
                        skipped += 1;
                        continue;
                    }
                    replace_imported_file(paths, &source, &destination)?;
                } else {
                    std::fs::copy(&source, &destination)?;
                }
                imported += 1;
            }
            "zip" => {
                let result = import_zip(paths, &source, replace)?;
                imported += result.0;
                skipped += result.1;
            }
            _ => skipped += 1,
        }
    }
    Ok(ImportResult {
        imported,
        skipped,
        message: format!("已导入 {imported} 个条目，跳过 {skipped} 个不支持或重复的文件"),
    })
}

fn import_zip(paths: &AppPaths, source: &Path, replace: bool) -> Result<(usize, usize)> {
    install_ue4ss_zip(paths, source, None, replace)
}

fn import_backup_path(paths: &AppPaths, file_name: &str) -> Result<PathBuf> {
    let directory = paths.backups_dir.join("imports");
    std::fs::create_dir_all(&directory)?;
    Ok(directory.join(format!(
        "{}-{}",
        uuid::Uuid::new_v4(),
        safe_disk_name(file_name, "mod")
    )))
}

fn replace_imported_file(paths: &AppPaths, source: &Path, destination: &Path) -> Result<()> {
    let file_name = destination
        .file_name()
        .context("导入目标缺少文件名")?
        .to_string_lossy();
    let backup = import_backup_path(paths, &file_name)?;
    std::fs::rename(destination, &backup)
        .with_context(|| format!("无法备份已存在的模组文件 {}", destination.display()))?;
    if let Err(error) = std::fs::copy(source, destination) {
        let _ = std::fs::rename(&backup, destination);
        return Err(error).with_context(|| format!("无法覆盖模组文件 {}", destination.display()));
    }
    Ok(())
}

fn replace_imported_directory(paths: &AppPaths, source: &Path, destination: &Path) -> Result<()> {
    let directory_name = destination
        .file_name()
        .context("导入目标缺少目录名")?
        .to_string_lossy();
    let backup = import_backup_path(paths, &directory_name)?;
    std::fs::rename(destination, &backup)
        .with_context(|| format!("无法备份已存在的模组目录 {}", destination.display()))?;
    if let Err(error) = copy_tree(source, destination) {
        let _ = std::fs::remove_dir_all(destination);
        let _ = std::fs::rename(&backup, destination);
        return Err(error).with_context(|| format!("无法覆盖模组目录 {}", destination.display()));
    }
    Ok(())
}

/// 安装一个 ZIP 形态的模组包：含 `.pak` 的包只提取 PAK 到本地模组库，
/// 否则按 UE4SS 模组装进运行时目录。
///
/// 云端下载与本地拖入共用这一条路径，保证 wrapper 目录剥离、目标名清洗、
/// 已存在跳过/替换的语义完全一致。`replace` 为真时先解到以点开头的暂存目录，
/// 成功后再原子替换，解压失败不会清空用户已有的安装。
pub fn install_ue4ss_zip(
    paths: &AppPaths,
    source: &Path,
    preferred_name: Option<&str>,
    replace: bool,
) -> Result<(usize, usize)> {
    let file = File::open(source)?;
    let mut archive = ZipArchive::new(file)?;
    let mut contains_pak = false;
    for index in 0..archive.len() {
        let entry = archive.by_index(index)?;
        if entry.name().to_ascii_lowercase().ends_with(".pak") {
            contains_pak = true;
            break;
        }
    }
    if contains_pak {
        return extract_zip_matching(paths, archive, &paths.local_mods, replace, |name| {
            is_pak_import_asset(name)
        });
    }

    let wrapper = zip_wrapper_directory(&mut archive)?;
    let raw_name = wrapper
        .clone()
        .or_else(|| preferred_name.map(str::to_string))
        .unwrap_or_else(|| {
            source
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned()
        });
    let folder_name = safe_disk_name(&raw_name, "mod");
    let destination = paths.ue4ss_mods.join(&folder_name);
    if destination.exists() && !replace {
        return Ok((0, 1));
    }

    let staging = paths
        .ue4ss_mods
        .join(format!(".staging-{}-{}", std::process::id(), folder_name));
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging)?;
    let extracted = match extract_zip_all_with_wrapper(archive, &staging, wrapper.as_deref()) {
        Ok(count) => count,
        Err(error) => {
            let _ = std::fs::remove_dir_all(&staging);
            return Err(error);
        }
    };
    if extracted == 0 {
        let _ = std::fs::remove_dir_all(&staging);
        return Ok((0, 1));
    }

    let mut retired = None;
    if destination.exists() {
        let trash =
            paths
                .ue4ss_mods
                .join(format!(".retired-{}-{}", std::process::id(), folder_name));
        let _ = std::fs::remove_dir_all(&trash);
        std::fs::rename(&destination, &trash).with_context(|| {
            format!("无法替换已存在的 UE4SS 模组目录 {}", destination.display())
        })?;
        retired = Some(trash);
    }
    if let Err(error) = std::fs::rename(&staging, &destination) {
        if let Some(trash) = retired {
            let _ = std::fs::rename(&trash, &destination);
        }
        let _ = std::fs::remove_dir_all(&staging);
        return Err(error)
            .with_context(|| format!("无法写入 UE4SS 模组目录 {}", destination.display()));
    }
    if let Some(trash) = retired {
        let _ = std::fs::remove_dir_all(&trash);
    }
    Ok((1, 0))
}

fn is_pak_import_asset(name: &str) -> bool {
    let file_name = name
        .rsplit(|character| character == '/' || character == '\\')
        .next()
        .unwrap_or(name)
        .to_ascii_lowercase();
    file_name.ends_with(".pak")
        || file_name.ends_with(".mod.json")
        || file_name.ends_with(".presentation.json")
        || COVER_EXTENSIONS
            .iter()
            .any(|extension| file_name.ends_with(&format!(".cover.{extension}")))
}

fn zip_wrapper_directory(archive: &mut ZipArchive<File>) -> Result<Option<String>> {
    let mut wrapper: Option<String> = None;
    for index in 0..archive.len() {
        let entry = archive.by_index(index)?;
        if entry.is_dir() {
            continue;
        }
        let Some(relative) = entry.enclosed_name() else {
            return Ok(None);
        };
        let mut components = relative.components();
        let Some(Component::Normal(root)) = components.next() else {
            return Ok(None);
        };
        if components.next().is_none() {
            return Ok(None);
        }
        let root = root.to_string_lossy().into_owned();
        if is_ue4ss_content_root(&root) {
            return Ok(None);
        }
        match &wrapper {
            Some(existing) if existing != &root => return Ok(None),
            Some(_) => {}
            None => wrapper = Some(root),
        }
    }
    Ok(wrapper)
}

fn is_ue4ss_content_root(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        "scripts" | "dlls" | "binaries" | "content"
    )
}

pub fn extract_zip_file(zip_path: &Path, destination: &Path) -> Result<usize> {
    let file = File::open(zip_path)?;
    let archive = ZipArchive::new(file)?;
    extract_zip_all(archive, destination)
}

fn extract_zip_matching<F>(
    paths: &AppPaths,
    mut archive: ZipArchive<File>,
    destination: &Path,
    replace: bool,
    predicate: F,
) -> Result<(usize, usize)>
where
    F: Fn(&str) -> bool,
{
    std::fs::create_dir_all(destination)?;
    let mut imported = 0;
    let mut skipped = 0;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        let Some(relative) = entry.enclosed_name() else {
            skipped += 1;
            continue;
        };
        if !predicate(entry.name()) || entry.is_dir() {
            continue;
        }
        let filename = relative.file_name().context("压缩包内 PAK 缺少文件名")?;
        let output = destination.join(filename);
        if output.exists() {
            if !replace {
                skipped += 1;
                continue;
            }
            // 与直接落盘的 PAK 一致：覆盖前留一份可回收的备份。
            let backup = import_backup_path(
                paths,
                &output.file_name().unwrap_or_default().to_string_lossy(),
            )?;
            std::fs::rename(&output, &backup)
                .with_context(|| format!("无法备份已存在的模组文件 {}", output.display()))?;
        }
        if let Some(parent) = output.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut target = File::create(output)?;
        std::io::copy(&mut entry, &mut target)?;
        imported += 1;
    }
    Ok((imported, skipped))
}

pub fn extract_zip_all(archive: ZipArchive<File>, destination: &Path) -> Result<usize> {
    extract_zip_all_with_wrapper(archive, destination, None)
}

fn extract_zip_all_with_wrapper(
    mut archive: ZipArchive<File>,
    destination: &Path,
    wrapper: Option<&str>,
) -> Result<usize> {
    std::fs::create_dir_all(destination)?;
    let mut count = 0;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        let Some(relative) = entry.enclosed_name() else {
            continue;
        };
        if relative.is_absolute()
            || relative
                .components()
                .any(|part| !matches!(part, Component::Normal(_)))
        {
            continue;
        }
        let relative = match wrapper {
            Some(root) => match relative.strip_prefix(root) {
                Ok(stripped) if !stripped.as_os_str().is_empty() => stripped.to_path_buf(),
                _ => continue,
            },
            None => relative,
        };
        let output = destination.join(relative);
        if entry.is_dir() {
            std::fs::create_dir_all(&output)?;
            continue;
        }
        if let Some(parent) = output.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut target = File::create(&output)?;
        std::io::copy(&mut entry, &mut target)?;
        count += 1;
    }
    Ok(count)
}

pub fn copy_tree(source: &Path, destination: &Path) -> Result<()> {
    std::fs::create_dir_all(destination)?;
    for entry in WalkDir::new(source).follow_links(false) {
        let entry = entry?;
        let relative = entry.path().strip_prefix(source)?;
        if relative.as_os_str().is_empty() {
            continue;
        }
        let target = destination.join(relative);
        if entry.file_type().is_dir() {
            std::fs::create_dir_all(target)?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

pub fn directory_size(path: &Path) -> u64 {
    WalkDir::new(path)
        .follow_links(false)
        .into_iter()
        .filter_map(Result::ok)
        .filter_map(|entry| entry.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
        .sum()
}

pub fn is_pak(path: &Path) -> bool {
    path.extension()
        .is_some_and(|extension| extension.to_string_lossy().eq_ignore_ascii_case("pak"))
}

fn infer_description(name: &str, mod_type: &str) -> String {
    let lower = name.to_ascii_lowercase();
    if lower.contains("weapon") {
        "武器与战斗内容扩展".to_string()
    } else if lower.contains("vehicle") {
        "载具操控与外观内容扩展".to_string()
    } else if lower.contains("loot") || lower.contains("food") {
        "物资刷新与生存平衡调整".to_string()
    } else if lower.contains("map") {
        "地图与场景内容扩展".to_string()
    } else if lower.contains("ui") || lower.contains("hud") {
        "界面与 HUD 调整".to_string()
    } else if mod_type == "ue4ssMod" {
        "UE4SS 脚本模组".to_string()
    } else {
        "SCUM 客户端 PAK 模组".to_string()
    }
}

fn iso_time(time: SystemTime) -> String {
    let date: DateTime<Utc> = time.into();
    date.to_rfc3339()
}

fn epoch_millis(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::{
        extract_zip_file, import_paths, inspect_import_conflicts, install_ue4ss_zip,
        refresh_conflicts, scan_local_mods, stable_id,
    };
    use crate::models::ModEntry;
    use crate::paths::AppPaths;
    use std::collections::HashSet;
    use std::fs::{self, File};
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use uuid::Uuid;
    use zip::write::SimpleFileOptions;
    use zip::{CompressionMethod, ZipWriter};

    struct TempRoot(PathBuf);

    impl TempRoot {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("scum-mod-import-{}", Uuid::new_v4()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn test_paths(root: &Path) -> AppPaths {
        let paths = AppPaths::for_test(root.to_path_buf());
        fs::create_dir_all(&paths.local_mods).unwrap();
        fs::create_dir_all(&paths.ue4ss_mods).unwrap();
        paths
    }

    #[test]
    fn uses_the_recorded_display_name_over_the_file_name() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        fs::write(paths.local_mods.join("______.pak"), b"pak-body").unwrap();
        let mut metadata = crate::metadata::MetadataFile::default();
        let id = stable_id(&paths.local_mods, "______.pak");
        metadata.entry_mut(&id).name = Some("衣物容器嵌套".to_string());

        let mods = scan_local_mods(&paths, &mut metadata, &HashSet::new()).unwrap();

        assert_eq!(mods.len(), 1);
        assert_eq!(mods[0].name, "衣物容器嵌套");
        assert_eq!(mods[0].file_name, "______.pak");
    }

    #[test]
    fn collapses_byte_identical_paks_and_keeps_the_canonical_file() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        fs::write(paths.local_mods.join("Alpha.pak"), b"same pak bytes").unwrap();
        fs::write(paths.local_mods.join("Zeta.pak"), b"same pak bytes").unwrap();
        let mut metadata = crate::metadata::MetadataFile::default();
        let zeta_id = stable_id(&paths.local_mods, "Zeta.pak");
        metadata.entry_mut(&zeta_id).name = Some("用户保留名".to_string());
        metadata.entry_mut(&zeta_id).notes = "别名备注".to_string();

        let mods = scan_local_mods(&paths, &mut metadata, &HashSet::new()).unwrap();

        assert_eq!(mods.len(), 1);
        assert_eq!(mods[0].file_name, "Alpha.pak");
        assert_eq!(mods[0].duplicate_count, 1);
        assert_eq!(mods[0].duplicate_aliases.len(), 1);
        assert_eq!(mods[0].name, "用户保留名");
        assert_eq!(mods[0].notes, "别名备注");
        assert_eq!(
            metadata.entries[&mods[0].id].name.as_deref(),
            Some("用户保留名")
        );
        assert!(metadata.entries.contains_key(&zeta_id));
        assert_eq!(metadata.order, vec![mods[0].id.clone()]);
    }

    #[test]
    fn reads_pak_sidecar_presentation_and_cover() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        fs::write(paths.local_mods.join("Weapon.pak"), b"pak-body").unwrap();
        fs::write(
            paths.local_mods.join("Weapon.mod.json"),
            r#"{
                "author": "IslandWorks",
                "description": "替换武器外观，不改动数值。",
                "cover": "Weapon.cover.png"
            }"#,
        )
        .unwrap();
        fs::write(
            paths.local_mods.join("Weapon.cover.png"),
            b"\x89PNG\r\n\x1a\npreview",
        )
        .unwrap();

        let mods = scan_local_mods(
            &paths,
            &mut crate::metadata::MetadataFile::default(),
            &HashSet::new(),
        )
        .unwrap();

        assert_eq!(mods[0].author, "IslandWorks");
        assert_eq!(mods[0].description, "替换武器外观，不改动数值。");
        assert!(mods[0]
            .cover_url
            .as_deref()
            .is_some_and(|url| url.starts_with("data:image/png;base64,")));
    }

    #[test]
    fn discovers_conventional_cover_and_rejects_fake_or_oversized_images() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        fs::write(paths.local_mods.join("CleanHUD.pak"), b"pak-body").unwrap();
        fs::write(paths.local_mods.join("CleanHUD.cover.jpg"), b"not-a-jpeg").unwrap();
        fs::write(
            paths.local_mods.join("CleanHUD.cover.webp"),
            b"RIFF\x0c\0\0\0WEBPpreview",
        )
        .unwrap();

        let mods = scan_local_mods(
            &paths,
            &mut crate::metadata::MetadataFile::default(),
            &HashSet::new(),
        )
        .unwrap();
        assert!(mods[0]
            .cover_url
            .as_deref()
            .is_some_and(|url| url.starts_with("data:image/webp;base64,")));

        fs::remove_file(paths.local_mods.join("CleanHUD.cover.webp")).unwrap();
        fs::write(paths.local_mods.join("CleanHUD.cover.png"), b"not-a-png").unwrap();
        let mods = scan_local_mods(
            &paths,
            &mut crate::metadata::MetadataFile::default(),
            &HashSet::new(),
        )
        .unwrap();
        assert_eq!(mods[0].cover_url, None);

        let mut oversized = b"\x89PNG\r\n\x1a\n".to_vec();
        oversized.resize((2 * 1024 * 1024 + 1) as usize, 0);
        fs::write(paths.local_mods.join("CleanHUD.cover.png"), oversized).unwrap();
        let mods = scan_local_mods(
            &paths,
            &mut crate::metadata::MetadataFile::default(),
            &HashSet::new(),
        )
        .unwrap();
        assert_eq!(mods[0].cover_url, None);
    }

    #[test]
    fn reads_ue4ss_presentation_from_the_module_directory() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let module = paths.ue4ss_mods.join("BetterAI");
        fs::create_dir_all(&module).unwrap();
        fs::write(
            module.join("presentation.json"),
            br#"{"author":"Northstar"}"#,
        )
        .unwrap();
        fs::write(module.join("preview.png"), b"\x89PNG\r\n\x1a\npreview").unwrap();

        let mods = scan_local_mods(
            &paths,
            &mut crate::metadata::MetadataFile::default(),
            &HashSet::new(),
        )
        .unwrap();

        assert_eq!(mods.len(), 1);
        assert_eq!(mods[0].author, "Northstar");
        assert!(mods[0]
            .cover_url
            .as_deref()
            .is_some_and(|url| url.starts_with("data:image/png;base64,")));
    }

    #[test]
    fn refreshes_conflict_counts_when_enabled_state_changes() {
        let mut metadata = crate::metadata::MetadataFile::default();
        metadata.entry_mut("first").pak_entries = vec!["SCUM/Content/Shared.uasset".to_string()];
        metadata.entry_mut("second").pak_entries = vec!["scum/content/shared.uasset".to_string()];
        let mut mods = vec![
            ModEntry {
                id: "first".to_string(),
                mod_type: "clientPak".to_string(),
                enabled: true,
                ..ModEntry::default()
            },
            ModEntry {
                id: "second".to_string(),
                mod_type: "clientPak".to_string(),
                enabled: true,
                ..ModEntry::default()
            },
        ];

        refresh_conflicts(&mut metadata, &mut mods);
        assert_eq!(
            mods.iter()
                .map(|item| item.conflict_count)
                .collect::<Vec<_>>(),
            vec![1, 1]
        );

        mods[1].enabled = false;
        metadata.entry_mut("second").enabled = false;
        refresh_conflicts(&mut metadata, &mut mods);
        assert_eq!(
            mods.iter()
                .map(|item| item.conflict_count)
                .collect::<Vec<_>>(),
            vec![0, 0]
        );
        assert!(metadata
            .entries
            .values()
            .all(|entry| entry.conflicts.is_empty()));
    }

    #[test]
    fn imports_pak_file_into_local_library() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let source = temp.path().join("downloads").join("TestWeapon.pak");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, b"pak-content").unwrap();

        let result = import_paths(&paths, &[source.to_string_lossy().into_owned()], false).unwrap();

        assert_eq!(result.imported, 1);
        assert_eq!(result.skipped, 0);
        assert_eq!(
            fs::read(paths.local_mods.join("TestWeapon.pak")).unwrap(),
            b"pak-content"
        );
    }

    #[test]
    fn skips_existing_pak_without_overwriting_library_copy() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let existing = paths.local_mods.join("TestWeapon.pak");
        fs::write(&existing, b"original").unwrap();
        let source = temp.path().join("downloads").join("TestWeapon.pak");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, b"replacement").unwrap();

        let result = import_paths(&paths, &[source.to_string_lossy().into_owned()], false).unwrap();

        assert_eq!(result.imported, 0);
        assert_eq!(result.skipped, 1);
        assert_eq!(fs::read(existing).unwrap(), b"original");
        assert!(result.message.contains("跳过 1"));
    }

    #[test]
    fn previews_and_backs_up_a_confirmed_same_name_pak_replacement() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let existing = paths.local_mods.join("TestWeapon.pak");
        fs::write(&existing, b"original").unwrap();
        let source = temp.path().join("downloads").join("TestWeapon.pak");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, b"replacement").unwrap();
        let sources = vec![source.to_string_lossy().into_owned()];

        let conflicts = inspect_import_conflicts(&paths, &sources).unwrap();

        assert_eq!(conflicts.len(), 1);
        assert_eq!(conflicts[0].file_name, "TestWeapon.pak");
        assert_eq!(Path::new(&conflicts[0].target_path), existing);

        let result = import_paths(&paths, &sources, true).unwrap();

        assert_eq!(result.imported, 1);
        assert_eq!(fs::read(existing).unwrap(), b"replacement");
        let backups = fs::read_dir(paths.backups_dir.join("imports"))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(backups.len(), 1);
        assert_eq!(fs::read(backups[0].path()).unwrap(), b"original");
    }

    #[test]
    fn previews_same_name_pak_inside_zip_archives() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        fs::write(paths.local_mods.join("SharedWeapon.pak"), b"original").unwrap();
        let archive = temp.path().join("WeaponPack.zip");
        write_zip(&archive, &[("nested/SharedWeapon.pak", b"replacement")]);

        let conflicts =
            inspect_import_conflicts(&paths, &[archive.to_string_lossy().into_owned()]).unwrap();

        assert_eq!(conflicts.len(), 1);
        assert_eq!(conflicts[0].file_name, "SharedWeapon.pak");
    }

    #[test]
    fn imports_ue4ss_directory_into_runtime_library() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let source = temp.path().join("downloads").join("BetterAI");
        fs::create_dir_all(source.join("Scripts")).unwrap();
        fs::write(source.join("Scripts").join("main.lua"), b"print('ok')").unwrap();

        let result = import_paths(&paths, &[source.to_string_lossy().into_owned()], false).unwrap();

        assert_eq!(result.imported, 1);
        assert_eq!(
            fs::read(
                paths
                    .ue4ss_mods
                    .join("BetterAI")
                    .join("Scripts")
                    .join("main.lua")
            )
            .unwrap(),
            b"print('ok')"
        );
    }

    #[test]
    fn imports_ue4ss_zip_into_runtime_library() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let archive = temp.path().join("BetterAI.zip");
        let file = File::create(&archive).unwrap();
        let mut writer = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        writer
            .start_file("BetterAI/Scripts/main.lua", options)
            .unwrap();
        writer.write_all(b"print('zip')").unwrap();
        writer.finish().unwrap();

        let result =
            import_paths(&paths, &[archive.to_string_lossy().into_owned()], false).unwrap();

        assert_eq!(result.imported, 1);
        assert_eq!(
            fs::read(
                paths
                    .ue4ss_mods
                    .join("BetterAI")
                    .join("Scripts")
                    .join("main.lua")
            )
            .unwrap(),
            b"print('zip')"
        );
    }

    #[test]
    fn imports_flat_ue4ss_zip_using_archive_name() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let archive = temp.path().join("FlatMod.zip");
        let file = File::create(&archive).unwrap();
        let mut writer = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        writer.start_file("Scripts/main.lua", options).unwrap();
        writer.write_all(b"print('flat')").unwrap();
        writer.finish().unwrap();

        let result =
            import_paths(&paths, &[archive.to_string_lossy().into_owned()], false).unwrap();

        assert_eq!(result.imported, 1);
        assert_eq!(
            fs::read(
                paths
                    .ue4ss_mods
                    .join("FlatMod")
                    .join("Scripts")
                    .join("main.lua")
            )
            .unwrap(),
            b"print('flat')"
        );
    }

    #[test]
    fn skips_missing_and_unsupported_drop_sources() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let unsupported = temp.path().join("readme.txt");
        fs::write(&unsupported, b"not a mod").unwrap();
        let missing = temp.path().join("missing.pak");

        let result = import_paths(
            &paths,
            &[
                unsupported.to_string_lossy().into_owned(),
                missing.to_string_lossy().into_owned(),
            ],
            false,
        )
        .unwrap();

        assert_eq!(result.imported, 0);
        assert_eq!(result.skipped, 2);
    }

    #[test]
    fn zip_extraction_rejects_parent_and_backslash_traversal() {
        let temp = TempRoot::new();
        let archive = temp.path().join("unsafe.zip");
        let file = File::create(&archive).unwrap();
        let mut writer = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        for name in [
            "safe/inside.txt",
            "../escape.txt",
            "nested/../../escape2.txt",
            r"..\escape-backslash.txt",
        ] {
            writer.start_file(name, options).unwrap();
            writer.write_all(name.as_bytes()).unwrap();
        }
        writer.finish().unwrap();
        let destination = temp.path().join("safe").join("out");

        let extracted = extract_zip_file(&archive, &destination).unwrap();

        assert_eq!(extracted, 1);
        assert_eq!(
            fs::read(destination.join("safe").join("inside.txt")).unwrap(),
            b"safe/inside.txt"
        );
        assert!(!temp.path().join("safe").join("escape.txt").exists());
        assert!(!temp.path().join("safe").join("escape2.txt").exists());
        assert!(!temp
            .path()
            .join("safe")
            .join("escape-backslash.txt")
            .exists());
        assert!(!temp.path().join("escape.txt").exists());
        assert!(!temp.path().join("escape-backslash.txt").exists());
    }

    #[test]
    fn pak_zip_import_skips_existing_target_without_overwriting() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let existing = paths.local_mods.join("SharedWeapon.pak");
        fs::write(&existing, b"original").unwrap();
        let archive = temp.path().join("WeaponPack.zip");
        let file = File::create(&archive).unwrap();
        let mut writer = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        writer
            .start_file("nested/SharedWeapon.pak", options)
            .unwrap();
        writer.write_all(b"replacement").unwrap();
        writer.finish().unwrap();

        let result =
            import_paths(&paths, &[archive.to_string_lossy().into_owned()], false).unwrap();

        assert_eq!(result.imported, 0);
        assert_eq!(result.skipped, 1);
        assert_eq!(fs::read(existing).unwrap(), b"original");
    }

    fn write_zip(archive: &Path, entries: &[(&str, &[u8])]) {
        let file = File::create(archive).unwrap();
        let mut writer = ZipWriter::new(file);
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        for (name, body) in entries {
            writer.start_file(*name, options).unwrap();
            writer.write_all(body).unwrap();
        }
        writer.finish().unwrap();
    }

    #[test]
    fn imports_pak_presentation_sidecars_from_zip() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let archive = temp.path().join("WeaponPack.zip");
        write_zip(
            &archive,
            &[
                ("pack/Weapon.pak", b"pak"),
                (
                    "pack/Weapon.mod.json",
                    br#"{"author":"IslandWorks","cover":"Weapon.cover.png"}"#,
                ),
                ("pack/Weapon.cover.png", b"\x89PNG\r\n\x1a\npreview"),
                ("pack/readme.txt", b"ignored"),
            ],
        );

        let result =
            import_paths(&paths, &[archive.to_string_lossy().into_owned()], false).unwrap();

        assert_eq!(result.imported, 3);
        assert!(paths.local_mods.join("Weapon.pak").is_file());
        assert!(paths.local_mods.join("Weapon.mod.json").is_file());
        assert!(paths.local_mods.join("Weapon.cover.png").is_file());
        assert!(!paths.local_mods.join("readme.txt").exists());
        let mods = scan_local_mods(
            &paths,
            &mut crate::metadata::MetadataFile::default(),
            &HashSet::new(),
        )
        .unwrap();
        assert_eq!(mods[0].author, "IslandWorks");
        assert!(mods[0].cover_url.is_some());
    }

    #[test]
    fn keeps_chinese_ue4ss_names_distinct_on_disk() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let first = temp.path().join("武器增强.zip");
        write_zip(&first, &[("武器增强/Scripts/main.lua", b"print('a')")]);
        let second = temp.path().join("高清材质包.zip");
        write_zip(&second, &[("高清材质包/Scripts/main.lua", b"print('b')")]);

        assert_eq!(
            install_ue4ss_zip(&paths, &first, None, false).unwrap(),
            (1, 0)
        );
        assert_eq!(
            install_ue4ss_zip(&paths, &second, None, false).unwrap(),
            (1, 0)
        );

        assert_eq!(
            fs::read(
                paths
                    .ue4ss_mods
                    .join("武器增强")
                    .join("Scripts")
                    .join("main.lua")
            )
            .unwrap(),
            b"print('a')"
        );
        assert_eq!(
            fs::read(
                paths
                    .ue4ss_mods
                    .join("高清材质包")
                    .join("Scripts")
                    .join("main.lua")
            )
            .unwrap(),
            b"print('b')"
        );
    }

    #[test]
    fn strips_wrapper_and_replaces_only_when_requested() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let archive = temp.path().join("BetterAI.zip");
        write_zip(&archive, &[("BetterAI/Scripts/main.lua", b"v1")]);

        assert_eq!(
            install_ue4ss_zip(&paths, &archive, None, false).unwrap(),
            (1, 0)
        );
        assert!(paths
            .ue4ss_mods
            .join("BetterAI")
            .join("Scripts")
            .join("main.lua")
            .exists());
        assert!(!paths.ue4ss_mods.join("BetterAI").join("BetterAI").exists());

        let update = temp.path().join("BetterAI-v2.zip");
        write_zip(&update, &[("BetterAI/Scripts/main.lua", b"v2")]);
        assert_eq!(
            install_ue4ss_zip(&paths, &update, None, false).unwrap(),
            (0, 1)
        );
        assert_eq!(
            fs::read(
                paths
                    .ue4ss_mods
                    .join("BetterAI")
                    .join("Scripts")
                    .join("main.lua")
            )
            .unwrap(),
            b"v1"
        );
        assert_eq!(
            install_ue4ss_zip(&paths, &update, None, true).unwrap(),
            (1, 0)
        );
        assert_eq!(
            fs::read(
                paths
                    .ue4ss_mods
                    .join("BetterAI")
                    .join("Scripts")
                    .join("main.lua")
            )
            .unwrap(),
            b"v2"
        );
        assert!(!paths.ue4ss_mods.join(".staging").exists());
    }

    #[test]
    fn uses_remote_name_when_the_zip_has_no_wrapper() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let archive = temp.path().join("payload.zip");
        write_zip(&archive, &[("Scripts/main.lua", b"flat")]);

        assert_eq!(
            install_ue4ss_zip(&paths, &archive, Some("武器增强"), true).unwrap(),
            (1, 0)
        );
        assert!(paths
            .ue4ss_mods
            .join("武器增强")
            .join("Scripts")
            .join("main.lua")
            .exists());
    }

    #[test]
    fn replaces_existing_pak_from_zip_only_when_requested() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let existing = paths.local_mods.join("Weapon.pak");
        fs::write(&existing, b"old").unwrap();
        let archive = temp.path().join("WeaponPack.zip");
        write_zip(&archive, &[("nested/Weapon.pak", b"new")]);

        assert_eq!(
            install_ue4ss_zip(&paths, &archive, None, false).unwrap(),
            (0, 1)
        );
        assert_eq!(fs::read(&existing).unwrap(), b"old");

        assert_eq!(
            install_ue4ss_zip(&paths, &archive, None, true).unwrap(),
            (1, 0)
        );
        assert_eq!(fs::read(&existing).unwrap(), b"new");
        let imports = fs::read_dir(paths.backups_dir.join("imports"))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(imports.len(), 1);
        assert_eq!(fs::read(imports[0].path()).unwrap(), b"old");
    }
}
