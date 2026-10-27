use super::extract_zip_file;
use crate::models::{AppSettings, ModEntry};
use crate::paths::{is_within, path_string, AppPaths};
use anyhow::{bail, Context, Result};
use base64::Engine;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeployedManifest {
    pub deployed_at: String,
    pub roots: Vec<String>,
    pub files: Vec<String>,
    pub directories: Vec<String>,
}

pub fn read_manifest(paths: &AppPaths) -> Option<DeployedManifest> {
    let text = std::fs::read_to_string(&paths.deployment_manifest).ok()?;
    serde_json::from_str(&text).ok()
}

pub fn deployed_file_names(paths: &AppPaths) -> HashSet<String> {
    read_manifest(paths)
        .map(|manifest| {
            manifest
                .files
                .iter()
                .filter_map(|path| Path::new(path).file_name())
                .map(|name| name.to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default()
}

pub fn reclaim_mods(paths: &AppPaths) -> Result<usize> {
    let Some(manifest) = read_manifest(paths) else {
        return Ok(0);
    };
    let roots: Vec<PathBuf> = manifest.roots.iter().map(PathBuf::from).collect();
    let mut removed = 0;
    for file in manifest.files.iter().rev() {
        let file = PathBuf::from(file);
        if !roots.iter().any(|root| is_within(&file, root)) {
            continue;
        }
        if file.is_file() && std::fs::remove_file(&file).is_ok() {
            removed += 1;
        }
    }
    let mut directories = manifest.directories.clone();
    directories.sort_by_key(|path| std::cmp::Reverse(path.len()));
    for directory in directories {
        let directory = PathBuf::from(directory);
        if !roots.iter().any(|root| is_within(&directory, root)) {
            continue;
        }
        let _ = std::fs::remove_dir(&directory);
    }
    let _ = std::fs::remove_file(&paths.deployment_manifest);
    Ok(removed)
}

pub fn rescue_mods_from_game(paths: &AppPaths, settings: &AppSettings) -> Result<usize> {
    let mut rescued = 0;
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
                let destination = paths.local_mods.join(entry.file_name());
                std::fs::create_dir_all(&paths.local_mods)?;
                std::fs::copy(&source, destination)?;
                rescued += 1;
            }
        }
    }
    Ok(rescued)
}

pub fn deploy_local_mods(
    paths: &AppPaths,
    settings: &AppSettings,
    mods: &[ModEntry],
    is_server: bool,
) -> Result<Option<String>> {
    reclaim_mods(paths)?;
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
            .join("~mod")
    });
    std::fs::create_dir_all(&pak_dir)
        .with_context(|| format!("无法创建游戏模组目录 {}", pak_dir.display()))?;

    let enabled: Vec<&ModEntry> = mods.iter().filter(|item| item.enabled).collect();
    if enabled.is_empty() {
        return Ok(None);
    }

    let mut manifest = DeployedManifest {
        deployed_at: Utc::now().to_rfc3339(),
        roots: vec![path_string(install), path_string(&pak_dir)],
        ..DeployedManifest::default()
    };

    for item in enabled.iter().filter(|item| item.mod_type == "clientPak") {
        let source = PathBuf::from(&item.file_path);
        if !source.is_file() {
            continue;
        }
        let target = pak_dir.join(&item.file_name);
        copy_file_record(&source, &target, &mut manifest)?;
    }

    let ue4ss_enabled: Vec<&&ModEntry> = enabled
        .iter()
        .filter(|item| item.mod_type == "ue4ssMod")
        .collect();
    if !ue4ss_enabled.is_empty() {
        if let Some(binaries) = find_binaries_dir(install) {
            ensure_runtime_framework(paths)?;
            sync_ue4ss_mods_txt(paths, mods)?;
            deploy_framework(paths, &binaries, &mut manifest)?;
            for item in ue4ss_enabled {
                deploy_ue4ss_mod(item, &binaries, &mut manifest)?;
            }
        }
    }

    if manifest.files.is_empty() {
        bail!("没有可部署的模组文件，请检查本地 ~mods 目录");
    }
    let json = serde_json::to_string_pretty(&manifest)?;
    std::fs::write(&paths.deployment_manifest, format!("{json}\n"))?;
    Ok(Some(manifest.deployed_at))
}

pub fn find_pak_dir(install: &Path) -> Option<PathBuf> {
    candidate_paths(install, ["SCUM/Content/Paks/~mod", "Content/Paks/~mod"])
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
    manifest: &mut DeployedManifest,
) -> Result<()> {
    let dll = paths.ue4ss_runtime.join("dwmapi.dll");
    if dll.is_file() {
        copy_file_record(&dll, &binaries.join("dwmapi.dll"), manifest)?;
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
            std::fs::create_dir_all(&target)?;
            manifest.directories.push(path_string(&target));
        } else if entry.file_type().is_file() {
            copy_file_record(entry.path(), &target, manifest)?;
        }
    }
    for file_name in ["mods.json", "mods.txt"] {
        let source = source_root.join("Mods").join(file_name);
        if source.is_file() {
            copy_file_record(&source, &target_root.join("Mods").join(file_name), manifest)?;
        }
    }
    Ok(())
}

fn deploy_ue4ss_mod(
    item: &ModEntry,
    binaries: &Path,
    manifest: &mut DeployedManifest,
) -> Result<()> {
    let source = PathBuf::from(&item.file_path);
    let target = binaries.join("ue4ss").join("Mods").join(&item.name);
    std::fs::create_dir_all(&target)?;
    manifest.directories.push(path_string(&target));
    for entry in WalkDir::new(&source).follow_links(false) {
        let entry = entry?;
        let relative = entry.path().strip_prefix(&source)?;
        if relative.as_os_str().is_empty() {
            continue;
        }
        let destination = target.join(relative);
        if entry.file_type().is_dir() {
            std::fs::create_dir_all(&destination)?;
            manifest.directories.push(path_string(&destination));
        } else if entry.file_type().is_file() {
            copy_file_record(entry.path(), &destination, manifest)?;
        }
    }
    Ok(())
}

fn copy_file_record(source: &Path, target: &Path, manifest: &mut DeployedManifest) -> Result<()> {
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
        manifest.directories.push(path_string(parent));
    }
    std::fs::copy(source, target)
        .with_context(|| format!("无法复制 {} 到 {}", source.display(), target.display()))?;
    manifest.files.push(path_string(target));
    Ok(())
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
        deploy_local_mods, read_manifest, reclaim_mods, sync_ue4ss_state, DeployedManifest,
    };
    use crate::models::{AppSettings, ModEntry};
    use crate::paths::path_string;
    use crate::test_support::TempRoot;
    use base64::Engine;
    use std::fs::{self, File};
    use std::io::Write;
    use std::path::{Path, PathBuf};
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
            update_version: None,
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
            .join("~mod");
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

        let target = pak_dir.join("TestWeapon.pak");
        assert_eq!(fs::read(&target).unwrap(), b"pak-content");
        let manifest = read_manifest(&paths).expect("deployment manifest should exist");
        assert_eq!(manifest.deployed_at, deployed_at);
        assert!(manifest.files.contains(&path_string(&target)));

        assert_eq!(reclaim_mods(&paths).unwrap(), 1);
        assert!(!target.exists());
        assert!(!paths.deployment_manifest.exists());
        assert!(source.exists());
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
}
