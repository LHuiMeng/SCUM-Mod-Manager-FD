use crate::metadata::MetadataFile;
use crate::models::{ImportResult, ModEntry};
use crate::paths::{path_string, AppPaths};
use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use walkdir::WalkDir;
use zip::ZipArchive;

pub mod deploy;

pub fn scan_local_mods(
    paths: &AppPaths,
    metadata: &mut MetadataFile,
    deployed_names: &HashSet<String>,
) -> Result<Vec<ModEntry>> {
    let mut mods = Vec::new();

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
    metadata.order = mods.iter().map(|item| item.id.clone()).collect();
    Ok(mods)
}

fn build_file_mod(
    paths: &AppPaths,
    metadata: &mut MetadataFile,
    deployed_names: &HashSet<String>,
    path: &Path,
    mod_type: &str,
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
    if !meta.sha256.is_empty()
        && meta.file_size == Some(file_size)
        && meta.modified_at == Some(modified_at)
    {
        // Reuse the cached digest when file identity did not change.
    } else {
        meta.sha256 = compute_sha256(path).unwrap_or_default();
        meta.file_size = Some(file_size);
        meta.modified_at = Some(modified_at);
    }

    let name = path
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let tags = meta.tags.clone();
    let notes = meta.notes.clone();
    let enabled = meta.enabled;
    let sha256 = meta.sha256.clone();
    let conflict_count = meta.conflicts.len();

    Ok(ModEntry {
        id,
        name: name.clone(),
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
        deployed: deployed_names.contains(&file_name),
        description: infer_description(&name, mod_type),
        conflict_count,
        update_version: None,
    })
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
    let tags = meta.tags.clone();
    let notes = meta.notes.clone();
    let enabled = meta.enabled;
    let conflict_count = meta.conflicts.len();

    Ok(ModEntry {
        id,
        name: file_name.clone(),
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
        deployed: deployed_names.contains(&file_name),
        description: infer_description(&file_name, "ue4ssMod"),
        conflict_count,
        update_version: None,
    })
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

pub fn import_paths(paths: &AppPaths, sources: &[String]) -> Result<ImportResult> {
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
                skipped += 1;
                continue;
            }
            copy_tree(&source, &destination)?;
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
                    skipped += 1;
                    continue;
                }
                std::fs::copy(&source, &destination)?;
                imported += 1;
            }
            "zip" => {
                let result = import_zip(paths, &source)?;
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

fn import_zip(paths: &AppPaths, source: &Path) -> Result<(usize, usize)> {
    let file = File::open(source)?;
    let mut archive = ZipArchive::new(file)?;
    let mut contains_pak = false;
    for index in 0..archive.len() {
        let file = archive.by_index(index)?;
        if file.name().to_ascii_lowercase().ends_with(".pak") {
            contains_pak = true;
            break;
        }
    }
    if contains_pak {
        extract_zip_matching(paths, archive, &paths.local_mods, |name| {
            name.to_ascii_lowercase().ends_with(".pak")
        })
    } else {
        let wrapper = zip_wrapper_directory(&mut archive)?;
        let folder_name = wrapper.clone().unwrap_or_else(|| {
            source
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned()
        });
        let destination = paths.ue4ss_mods.join(folder_name);
        if destination.exists() {
            return Ok((0, 1));
        }
        std::fs::create_dir_all(&destination)?;
        extract_zip_all_with_wrapper(archive, &destination, wrapper.as_deref())?;
        Ok((1, 0))
    }
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
    _paths: &AppPaths,
    mut archive: ZipArchive<File>,
    destination: &Path,
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
            skipped += 1;
            continue;
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
    use super::{extract_zip_file, import_paths};
    use crate::paths::AppPaths;
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
    fn imports_pak_file_into_local_library() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let source = temp.path().join("downloads").join("TestWeapon.pak");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, b"pak-content").unwrap();

        let result = import_paths(&paths, &[source.to_string_lossy().into_owned()]).unwrap();

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

        let result = import_paths(&paths, &[source.to_string_lossy().into_owned()]).unwrap();

        assert_eq!(result.imported, 0);
        assert_eq!(result.skipped, 1);
        assert_eq!(fs::read(existing).unwrap(), b"original");
        assert!(result.message.contains("跳过 1"));
    }

    #[test]
    fn imports_ue4ss_directory_into_runtime_library() {
        let temp = TempRoot::new();
        let paths = test_paths(temp.path());
        let source = temp.path().join("downloads").join("BetterAI");
        fs::create_dir_all(source.join("Scripts")).unwrap();
        fs::write(source.join("Scripts").join("main.lua"), b"print('ok')").unwrap();

        let result = import_paths(&paths, &[source.to_string_lossy().into_owned()]).unwrap();

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

        let result = import_paths(&paths, &[archive.to_string_lossy().into_owned()]).unwrap();

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

        let result = import_paths(&paths, &[archive.to_string_lossy().into_owned()]).unwrap();

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

        let result = import_paths(&paths, &[archive.to_string_lossy().into_owned()]).unwrap();

        assert_eq!(result.imported, 0);
        assert_eq!(result.skipped, 1);
        assert_eq!(fs::read(existing).unwrap(), b"original");
    }
}
