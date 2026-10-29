use crate::metadata::{MetadataFile, ModMetadata};
use crate::models::{ConflictGroup, ConflictOwner, ModEntry};
use crate::paths::AppPaths;
use anyhow::{bail, Context, Result};
#[cfg(test)]
use std::collections::BTreeSet;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::File;
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

const MAX_ERROR_CHARS: usize = 2_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PakScanDiagnostic {
    pub mod_id: String,
    pub file_name: String,
    pub message: String,
}

/// Refresh one PAK's cached entry list using the file identity recorded by the caller.
///
/// A non-empty list is reused only when both size and modification time match. Failed
/// scans keep an unchanged cache; a changed file drops its old cache so the next scan
/// cannot associate stale entries with the new file.
pub(crate) fn refresh_pak_cache<F>(
    metadata: &mut ModMetadata,
    file_size: u64,
    modified_at: i64,
    mut list_entries: F,
) -> Option<String>
where
    F: FnMut() -> Result<Vec<String>>,
{
    let identity_matches =
        metadata.file_size == Some(file_size) && metadata.modified_at == Some(modified_at);
    if identity_matches && !metadata.pak_entries.is_empty() {
        return None;
    }

    let error = match list_entries() {
        Ok(entries) => {
            metadata.pak_entries = normalize_entries(entries);
            None
        }
        Err(error) => {
            if !identity_matches {
                metadata.pak_entries.clear();
            }
            Some(format!("{error:#}"))
        }
    };
    metadata.file_size = Some(file_size);
    metadata.modified_at = Some(modified_at);
    error
}

pub(crate) fn list_pak_entries(paths: &AppPaths, pak_path: &Path) -> Result<Vec<String>> {
    let executable = paths.resource("repak.exe");
    if !executable.is_file() {
        bail!("找不到随包工具 {}", executable.display());
    }

    let mut command = Command::new(&executable);
    command
        .arg("list")
        .arg("--")
        .arg(pak_path)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);

    let output = command
        .output()
        .with_context(|| format!("无法启动 repak list：{}", pak_path.display()))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let detail = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        bail!(
            "repak list 失败（{}）：{}",
            output.status,
            truncate_error(detail)
        );
    }

    Ok(parse_list_output(&String::from_utf8_lossy(&output.stdout)))
}

pub(crate) fn parse_list_output(output: &str) -> Vec<String> {
    normalize_entries(
        output
            .lines()
            .filter_map(normalize_entry_path)
            .collect::<Vec<_>>(),
    )
}

/// Convert a repak output path to the canonical form used for conflict comparison.
///
/// Entries are relative to the package mount point: backslashes become slashes,
/// repak's fixed `../../../` mount prefix is removed, duplicate separators
/// collapse, and empty/escaping paths are rejected.
pub(crate) fn normalize_entry_path(raw: &str) -> Option<String> {
    let mut value = raw.trim().trim_start_matches('\u{feff}').replace('\\', "/");
    // repak lists mounted package paths as `../../../SCUM/...`; strip only that
    // exact three-level prefix. Generic parent traversal must remain invalid.
    if let Some(stripped) = value.strip_prefix("../../../") {
        if stripped.starts_with("../") {
            return None;
        }
        value = stripped.to_string();
    } else if value.starts_with("../") {
        return None;
    }
    value = value.trim_start_matches('/').to_string();

    let mut components = Vec::new();
    for component in value.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                if components.pop().is_none() {
                    return None;
                }
            }
            component => components.push(component),
        }
    }
    if components.is_empty() {
        None
    } else {
        Some(components.join("/"))
    }
}

fn normalize_entries(entries: Vec<String>) -> Vec<String> {
    let mut entries = entries
        .into_iter()
        .filter_map(|item| normalize_entry_path(&item))
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| {
        left.to_ascii_lowercase()
            .cmp(&right.to_ascii_lowercase())
            .then_with(|| left.cmp(right))
    });
    entries.dedup_by(|left, right| left.eq_ignore_ascii_case(right));
    entries
}

/// Return `mod_id -> canonical path -> conflicting mod IDs`.
///
/// Paths are compared case-insensitively after normalization. Repeated entries
/// inside one source are collapsed before ownership is counted.
#[cfg(test)]
pub(crate) fn compute_conflicts<'a, I>(sources: I) -> HashMap<String, HashMap<String, Vec<String>>>
where
    I: IntoIterator<Item = (&'a str, &'a [String])>,
{
    let mut owners: HashMap<String, BTreeSet<String>> = HashMap::new();
    let mut display_paths: HashMap<String, String> = HashMap::new();

    for (mod_id, entries) in sources {
        let mut seen = HashSet::new();
        for entry in entries {
            let Some(path) = normalize_entry_path(entry) else {
                continue;
            };
            let key = path.to_ascii_lowercase();
            if !seen.insert(key.clone()) {
                continue;
            }
            display_paths.entry(key.clone()).or_insert(path);
            owners.entry(key).or_default().insert(mod_id.to_string());
        }
    }

    let mut conflicts: HashMap<String, HashMap<String, Vec<String>>> = HashMap::new();
    for (key, mod_ids) in owners {
        if mod_ids.len() < 2 {
            continue;
        }
        let path = display_paths
            .get(&key)
            .cloned()
            .unwrap_or_else(|| key.clone());
        for mod_id in &mod_ids {
            let others = mod_ids
                .iter()
                .filter(|other| *other != mod_id)
                .cloned()
                .collect::<Vec<_>>();
            conflicts
                .entry(mod_id.clone())
                .or_default()
                .insert(path.clone(), others);
        }
    }

    for paths in conflicts.values_mut() {
        let mut sorted = paths.drain().collect::<Vec<(String, Vec<String>)>>();
        sorted.sort_by(|left, right| {
            left.0
                .to_ascii_lowercase()
                .cmp(&right.0.to_ascii_lowercase())
                .then_with(|| left.0.cmp(&right.0))
        });
        paths.extend(sorted);
    }
    conflicts
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct ConflictStats {
    pub file_count: usize,
    pub overridden_file_count: usize,
    pub overriding_file_count: usize,
    pub fully_overridden: bool,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct ConflictAnalysis {
    pub groups: Vec<ConflictGroup>,
    pub entry_conflicts: HashMap<String, HashMap<String, Vec<String>>>,
    pub stats: HashMap<String, ConflictStats>,
}

#[derive(Default)]
struct GroupBuilder {
    paths: BTreeMap<String, String>,
    owners: BTreeMap<String, ConflictOwner>,
}

/// Compute logical resource groups for enabled client PAKs.
///
/// Unreal package sidecars share the filename stem with their `.uasset` or
/// `.umap`. Other suffixes remain independent, so `Foo.png` and `Foo.txt` are
/// not treated as the same resource.
pub(crate) fn analyze_conflicts(metadata: &MetadataFile, mods: &[ModEntry]) -> ConflictAnalysis {
    let mut entries_by_mod: Vec<(&ModEntry, Vec<String>)> = Vec::new();
    let mut groups: BTreeMap<String, GroupBuilder> = BTreeMap::new();

    for item in mods.iter().filter(|item| item.mod_type == "clientPak") {
        let Some(entry) = metadata.entries.get(&item.id) else {
            continue;
        };
        let mut seen = HashSet::new();
        let mut paths = Vec::new();
        for raw in &entry.pak_entries {
            let Some(path) = normalize_entry_path(raw) else {
                continue;
            };
            if seen.insert(path.to_ascii_lowercase()) {
                paths.push(path);
            }
        }
        paths.sort_by(|left, right| {
            left.to_ascii_lowercase()
                .cmp(&right.to_ascii_lowercase())
                .then_with(|| left.cmp(right))
        });
        if item.enabled {
            for path in &paths {
                let key = logical_group_key(path);
                let group = groups.entry(key).or_default();
                group
                    .paths
                    .entry(path.to_ascii_lowercase())
                    .or_insert_with(|| path.clone());
                group.owners.insert(
                    item.id.clone(),
                    ConflictOwner {
                        id: item.id.clone(),
                        name: item.name.clone(),
                        load_order: item.load_order,
                        mod_type: item.mod_type.clone(),
                    },
                );
            }
        }
        entries_by_mod.push((item, paths));
    }

    let mut conflict_groups = Vec::new();
    for (key, group) in groups {
        if group.owners.len() < 2 {
            continue;
        }
        let mut owners = group.owners.into_values().collect::<Vec<_>>();
        owners.sort_by(|left, right| {
            left.load_order
                .cmp(&right.load_order)
                .then_with(|| left.id.cmp(&right.id))
        });
        let Some(default_winner_id) = owners
            .iter()
            .max_by(|left, right| {
                left.load_order
                    .cmp(&right.load_order)
                    .then_with(|| left.id.cmp(&right.id))
            })
            .map(|owner| owner.id.clone())
        else {
            continue;
        };
        let selected_winner_id = metadata
            .conflict_winners
            .get(&key)
            .filter(|winner| owners.iter().any(|owner| owner.id == **winner))
            .cloned();
        let winner_id = selected_winner_id
            .clone()
            .unwrap_or_else(|| default_winner_id.clone());
        let mut paths = group.paths.into_values().collect::<Vec<_>>();
        paths.sort_by(|left, right| {
            left.to_ascii_lowercase()
                .cmp(&right.to_ascii_lowercase())
                .then_with(|| left.cmp(right))
        });
        conflict_groups.push(ConflictGroup {
            key,
            paths,
            owners,
            default_winner_id,
            winner_id,
            selected_winner_id,
        });
    }

    let groups_by_key = conflict_groups
        .iter()
        .map(|group| (group.key.as_str(), group))
        .collect::<HashMap<_, _>>();
    let mut entry_conflicts: HashMap<String, HashMap<String, Vec<String>>> = HashMap::new();
    let mut stats = HashMap::new();

    for (item, paths) in entries_by_mod {
        let mut item_stats = ConflictStats {
            file_count: paths.len(),
            ..ConflictStats::default()
        };
        if !item.enabled {
            stats.insert(item.id.clone(), item_stats);
            continue;
        }
        for path in paths {
            let Some(group) = groups_by_key.get(logical_group_key(&path).as_str()) else {
                continue;
            };
            let others = group
                .owners
                .iter()
                .filter(|owner| owner.id != item.id)
                .map(|owner| owner.id.clone())
                .collect::<Vec<_>>();
            entry_conflicts
                .entry(item.id.clone())
                .or_default()
                .insert(path, others);
            if group.winner_id == item.id {
                item_stats.overriding_file_count += 1;
            } else {
                item_stats.overridden_file_count += 1;
            }
        }
        item_stats.fully_overridden =
            item_stats.file_count > 0 && item_stats.overridden_file_count == item_stats.file_count;
        stats.insert(item.id.clone(), item_stats);
    }

    ConflictAnalysis {
        groups: conflict_groups,
        entry_conflicts,
        stats,
    }
}

pub(crate) fn validate_conflict_winners(
    groups: &[ConflictGroup],
    winners: &BTreeMap<String, String>,
) -> Result<()> {
    for (key, winner) in winners {
        let group = groups
            .iter()
            .find(|group| group.key == *key)
            .with_context(|| format!("冲突组不存在：{key}"))?;
        if !group.owners.iter().any(|owner| owner.id == *winner) {
            bail!("所选模组不属于冲突组 {key}");
        }
    }
    Ok(())
}

pub(crate) fn extract_pak_entry(
    paths: &AppPaths,
    pak_path: &Path,
    entry: &str,
    output: &Path,
) -> Result<()> {
    let executable = paths.resource("repak.exe");
    if !executable.is_file() {
        bail!("找不到随包工具 {}", executable.display());
    }
    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("无法创建覆盖暂存目录 {}", parent.display()))?;
    }

    let mut command = Command::new(&executable);
    command
        .arg("get")
        .arg("--")
        .arg(pak_path)
        .arg(entry)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);

    let mut child = command
        .spawn()
        .with_context(|| format!("无法启动 repak get：{}", pak_path.display()))?;
    let mut stderr = child.stderr.take().context("无法读取 repak get 错误输出")?;
    let stderr_reader = thread::spawn(move || {
        let mut text = String::new();
        let _ = stderr.read_to_string(&mut text);
        text
    });
    let stdout = child.stdout.take().context("无法读取 repak get 输出")?;
    let copy_result = (|| -> Result<()> {
        let mut reader = stdout;
        let mut file = File::create(output)
            .with_context(|| format!("无法创建覆盖暂存文件 {}", output.display()))?;
        std::io::copy(&mut reader, &mut file)
            .with_context(|| format!("无法写入覆盖暂存文件 {}", output.display()))?;
        file.flush()
            .with_context(|| format!("无法刷新覆盖暂存文件 {}", output.display()))?;
        Ok(())
    })();
    let status = child.wait().context("等待 repak get 结束失败")?;
    let stderr = stderr_reader.join().unwrap_or_default();
    if copy_result.is_err() || !status.success() {
        let _ = std::fs::remove_file(output);
    }
    copy_result?;
    if !status.success() {
        let detail = truncate_error(stderr.trim());
        bail!("repak get 失败（{status}）：{detail}");
    }
    Ok(())
}

pub(crate) fn pack_pak(paths: &AppPaths, input: &Path, output: &Path) -> Result<()> {
    let executable = paths.resource("repak.exe");
    if !executable.is_file() {
        bail!("找不到随包工具 {}", executable.display());
    }
    let mut command = Command::new(&executable);
    command
        .arg("pack")
        .arg("-m")
        .arg("../../../")
        .arg(input)
        .arg(output)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    let result = command
        .output()
        .with_context(|| format!("无法启动 repak pack：{}", input.display()))?;
    if !result.status.success() {
        let stderr = String::from_utf8_lossy(&result.stderr);
        let stdout = String::from_utf8_lossy(&result.stdout);
        let detail = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        bail!(
            "repak pack 失败（{}）：{}",
            result.status,
            truncate_error(detail)
        );
    }
    if !output.is_file() || output.metadata().map_or(0, |meta| meta.len()) == 0 {
        bail!("repak pack 未生成有效覆盖 PAK：{}", output.display());
    }
    Ok(())
}

fn logical_group_key(path: &str) -> String {
    if let Some((stem, extension)) = path.rsplit_once('.') {
        let file_stem = stem.rsplit('/').next().unwrap_or_default();
        if !file_stem.is_empty()
            && !extension.contains('/')
            && matches!(
                extension.to_ascii_lowercase().as_str(),
                "uasset" | "uexp" | "ubulk" | "umap"
            )
        {
            return stem.to_ascii_lowercase();
        }
    }
    path.to_ascii_lowercase()
}

fn truncate_error(message: &str) -> String {
    let mut chars = message.chars();
    let truncated = chars.by_ref().take(MAX_ERROR_CHARS).collect::<String>();
    if chars.next().is_some() {
        format!("{truncated}...")
    } else {
        truncated
    }
}

#[cfg(test)]
mod tests {
    use super::{
        analyze_conflicts, compute_conflicts, list_pak_entries, normalize_entry_path,
        parse_list_output, refresh_pak_cache, validate_conflict_winners,
    };
    use crate::metadata::{MetadataFile, ModMetadata};
    use crate::models::ModEntry;
    use crate::mods::scan_local_mods_with_diagnostics;
    use crate::test_support::TempRoot;
    use std::collections::HashSet;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    #[test]
    fn normalizes_unreal_paths_case_and_separators() {
        assert_eq!(
            normalize_entry_path(r"..\..\..\SCUM\Content\Assets\Shared.uasset"),
            Some("SCUM/Content/Assets/Shared.uasset".to_string())
        );
        assert_eq!(
            normalize_entry_path("/SCUM//Content/./Assets/Shared.uasset"),
            Some("SCUM/Content/Assets/Shared.uasset".to_string())
        );
        assert_eq!(
            normalize_entry_path("SCUM/Content/A/../Shared.uasset"),
            Some("SCUM/Content/Shared.uasset".to_string())
        );
        assert_eq!(normalize_entry_path("../outside.uasset"), None);
        assert_eq!(normalize_entry_path("../../outside.uasset"), None);
        assert_eq!(normalize_entry_path("../"), None);
        assert_eq!(normalize_entry_path("../../../../outside.uasset"), None);
    }

    #[test]
    fn parses_and_deduplicates_repak_listing() {
        let entries = parse_list_output(
            "SCUM/Content/Assets/Shared.uasset\r\n\
             scum\\content\\assets\\shared.uasset\r\n\
             SCUM/Content/Assets/Other.uexp\r\n",
        );

        assert_eq!(
            entries,
            vec![
                "SCUM/Content/Assets/Other.uexp",
                "SCUM/Content/Assets/Shared.uasset"
            ]
        );
    }

    #[test]
    fn duplicate_entries_within_one_mod_are_not_conflicts() {
        let entries = vec![
            "SCUM/Content/Shared.uasset".to_string(),
            "scum/content/shared.uasset".to_string(),
        ];
        let conflicts = compute_conflicts([("same-mod", entries.as_slice())]);

        assert!(conflicts.is_empty());
    }

    #[test]
    fn groups_unreal_sidecars_and_uses_highest_load_order_as_default_winner() {
        let mut metadata = MetadataFile::default();
        metadata.entry_mut("alpha").pak_entries = vec![
            "SCUM/Content/Weapons/Gun.uasset".to_string(),
            "SCUM/Content/Weapons/Gun.uexp".to_string(),
            "SCUM/Content/Weapons/Gun.png".to_string(),
        ];
        metadata.entry_mut("beta").pak_entries = vec![
            "scum/content/weapons/gun.uasset".to_string(),
            "scum/content/weapons/gun.uexp".to_string(),
        ];
        let mods = vec![
            test_mod("alpha", "Alpha", 0, true),
            test_mod("beta", "Beta", 1, true),
        ];

        let analysis = analyze_conflicts(&metadata, &mods);

        assert_eq!(analysis.groups.len(), 1);
        let group = &analysis.groups[0];
        assert_eq!(group.key, "scum/content/weapons/gun");
        assert_eq!(
            group.paths,
            vec![
                "SCUM/Content/Weapons/Gun.uasset",
                "SCUM/Content/Weapons/Gun.uexp"
            ]
        );
        assert_eq!(
            group
                .owners
                .iter()
                .map(|owner| owner.id.as_str())
                .collect::<Vec<_>>(),
            vec!["alpha", "beta"]
        );
        assert_eq!(group.default_winner_id, "beta");
        assert_eq!(group.winner_id, "beta");
        assert_eq!(group.selected_winner_id, None);

        assert_eq!(analysis.stats["alpha"].file_count, 3);
        assert_eq!(analysis.stats["alpha"].overridden_file_count, 2);
        assert_eq!(analysis.stats["alpha"].overriding_file_count, 0);
        assert!(!analysis.stats["alpha"].fully_overridden);
        assert_eq!(analysis.stats["beta"].file_count, 2);
        assert_eq!(analysis.stats["beta"].overridden_file_count, 0);
        assert_eq!(analysis.stats["beta"].overriding_file_count, 2);
    }

    #[test]
    fn custom_winner_is_validated_and_changes_file_statistics() {
        let mut metadata = MetadataFile::default();
        metadata.entry_mut("alpha").pak_entries = vec!["SCUM/Content/Shared.uasset".to_string()];
        metadata.entry_mut("beta").pak_entries = vec!["SCUM/Content/Shared.uasset".to_string()];
        metadata
            .conflict_winners
            .insert("scum/content/shared".to_string(), "alpha".to_string());
        let mods = vec![
            test_mod("alpha", "Alpha", 0, true),
            test_mod("beta", "Beta", 1, true),
        ];

        let analysis = analyze_conflicts(&metadata, &mods);
        let group = &analysis.groups[0];
        assert_eq!(group.default_winner_id, "beta");
        assert_eq!(group.selected_winner_id.as_deref(), Some("alpha"));
        assert_eq!(group.winner_id, "alpha");
        assert_eq!(analysis.stats["alpha"].overriding_file_count, 1);
        assert_eq!(analysis.stats["beta"].overridden_file_count, 1);
        assert!(analysis.stats["beta"].fully_overridden);

        let mut invalid = std::collections::BTreeMap::new();
        invalid.insert("missing-group".to_string(), "alpha".to_string());
        assert!(validate_conflict_winners(&analysis.groups, &invalid).is_err());
        invalid.clear();
        invalid.insert("scum/content/shared".to_string(), "missing".to_string());
        assert!(validate_conflict_winners(&analysis.groups, &invalid).is_err());
        let mut valid = std::collections::BTreeMap::new();
        valid.insert("scum/content/shared".to_string(), "alpha".to_string());
        assert!(validate_conflict_winners(&analysis.groups, &valid).is_ok());
    }

    #[test]
    fn disabled_and_non_pak_mods_do_not_participate_in_conflicts() {
        let mut metadata = MetadataFile::default();
        metadata.entry_mut("alpha").pak_entries = vec!["SCUM/Content/Shared.uasset".to_string()];
        metadata.entry_mut("beta").pak_entries = vec!["SCUM/Content/Shared.uasset".to_string()];
        let mods = vec![
            test_mod("alpha", "Alpha", 0, true),
            test_mod("beta", "Beta", 1, false),
            test_mod("script", "Script", 2, true),
        ];

        let analysis = analyze_conflicts(&metadata, &mods);

        assert!(analysis.groups.is_empty());
        assert_eq!(analysis.stats["alpha"].file_count, 1);
        assert_eq!(analysis.stats["alpha"].overridden_file_count, 0);
        assert_eq!(analysis.stats["beta"].file_count, 1);
        assert_eq!(analysis.stats["beta"].overridden_file_count, 0);
        assert_eq!(
            analysis
                .stats
                .get("script")
                .copied()
                .unwrap_or_default()
                .file_count,
            0
        );
    }

    #[test]
    fn different_non_package_suffixes_do_not_share_a_group() {
        let mut metadata = MetadataFile::default();
        metadata.entry_mut("alpha").pak_entries = vec!["SCUM/Content/Preview.png".to_string()];
        metadata.entry_mut("beta").pak_entries = vec!["SCUM/Content/Preview.txt".to_string()];
        let mods = vec![
            test_mod("alpha", "Alpha", 0, true),
            test_mod("beta", "Beta", 1, true),
        ];

        assert!(analyze_conflicts(&metadata, &mods).groups.is_empty());
    }

    #[test]
    fn cache_reuses_matching_identity_and_refreshes_changed_or_empty_lists() {
        let mut metadata = ModMetadata {
            file_size: Some(10),
            modified_at: Some(20),
            pak_entries: vec!["SCUM/Content/Shared.uasset".to_string()],
            ..ModMetadata::default()
        };
        let mut calls = 0;
        let unchanged = refresh_pak_cache(&mut metadata, 10, 20, || {
            calls += 1;
            Ok(vec!["SCUM/Content/Unused.uasset".to_string()])
        });
        assert_eq!(unchanged, None);
        assert_eq!(calls, 0);

        let changed = refresh_pak_cache(&mut metadata, 11, 21, || {
            calls += 1;
            Ok(vec![r"..\..\..\SCUM\Content\New.uasset".to_string()])
        });
        assert_eq!(changed, None);
        assert_eq!(calls, 1);
        assert_eq!(
            metadata.pak_entries,
            vec!["SCUM/Content/New.uasset".to_string()]
        );

        metadata.pak_entries.clear();
        let empty_refresh = refresh_pak_cache(&mut metadata, 11, 21, || {
            calls += 1;
            Ok(vec!["SCUM/Content/Retried.uasset".to_string()])
        });
        assert_eq!(empty_refresh, None);
        assert_eq!(calls, 2);
        assert_eq!(
            metadata.pak_entries,
            vec!["SCUM/Content/Retried.uasset".to_string()]
        );
    }

    #[test]
    fn failed_changed_pak_clears_stale_cache_but_does_not_stop_scan() {
        let mut metadata = ModMetadata {
            file_size: Some(10),
            modified_at: Some(20),
            pak_entries: vec!["SCUM/Content/Old.uasset".to_string()],
            ..ModMetadata::default()
        };

        let error = refresh_pak_cache(&mut metadata, 11, 21, || anyhow::bail!("unsupported pak"));

        assert!(error
            .as_deref()
            .unwrap_or_default()
            .contains("unsupported pak"));
        assert!(metadata.pak_entries.is_empty());
        assert_eq!(metadata.file_size, Some(11));
        assert_eq!(metadata.modified_at, Some(21));
    }

    #[test]
    fn scans_real_paks_and_reports_cross_mod_conflicts() {
        let temp = TempRoot::new("pak-scan-conflicts");
        let paths = temp.paths();
        let first = build_test_pak(
            temp.path(),
            &paths,
            "First",
            &[
                ("SCUM/Content/Assets/Shared.uasset", b"first"),
                ("SCUM/Content/Assets/FirstOnly.uexp", b"first-only"),
            ],
        );
        let second = build_test_pak(
            temp.path(),
            &paths,
            "Second",
            &[
                ("scum/content/assets/shared.uasset", b"second"),
                ("SCUM/Content/Assets/SecondOnly.uexp", b"second-only"),
            ],
        );
        fs::copy(first, paths.local_mods.join("First.pak")).unwrap();
        fs::copy(second, paths.local_mods.join("Second.pak")).unwrap();
        let mut metadata = MetadataFile::default();

        let scan =
            scan_local_mods_with_diagnostics(&paths, &mut metadata, &HashSet::new()).unwrap();

        assert!(scan.diagnostics.is_empty(), "{:?}", scan.diagnostics);
        assert_eq!(scan.mods.len(), 2);
        assert!(scan.mods.iter().all(|item| item.conflict_count == 1));
        assert!(metadata
            .entries
            .values()
            .all(|entry| entry.pak_entries.len() == 2));
        assert!(metadata.entries.values().all(|entry| {
            entry.conflicts.len() == 1 && entry.conflicts.values().all(|others| others.len() == 1)
        }));
    }

    #[test]
    fn repak_list_uses_the_bundled_executable() {
        let temp = TempRoot::new("pak-scan-list-format");
        let paths = temp.paths();
        let pak = build_test_pak(
            temp.path(),
            &paths,
            "List",
            &[("SCUM/Content/Assets/Listed.uasset", b"listed")],
        );

        let entries = list_pak_entries(&paths, &pak).unwrap();

        assert_eq!(entries, vec!["SCUM/Content/Assets/Listed.uasset"]);
    }

    fn test_mod(id: &str, name: &str, load_order: usize, enabled: bool) -> ModEntry {
        ModEntry {
            id: id.to_string(),
            name: name.to_string(),
            enabled,
            mod_type: if id == "script" {
                "ue4ssMod".to_string()
            } else {
                "clientPak".to_string()
            },
            load_order,
            ..ModEntry::default()
        }
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
}
