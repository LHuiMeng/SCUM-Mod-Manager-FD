use crate::metadata::MetadataFile;
use crate::models::ModEntry;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

/// Merge local PAK records that point at byte-identical files.
///
/// Only a complete, non-empty SHA-256 is treated as an identity. The canonical
/// entry keeps its own file path, while aliases are recorded for diagnostics and
/// UI. `metadata` is read-only so an alias keeps its settings if it later becomes
/// canonical.
pub fn collapse_identical_mods(mods: Vec<ModEntry>, metadata: &MetadataFile) -> Vec<ModEntry> {
    let mut groups: Vec<Vec<ModEntry>> = Vec::new();
    let mut group_by_hash: HashMap<String, usize> = HashMap::new();
    let mut result = Vec::new();

    for item in mods {
        let Some(hash) = full_sha256(&item.sha256) else {
            result.push(item);
            continue;
        };
        if let Some(index) = group_by_hash.get(&hash).copied() {
            groups[index].push(item);
        } else {
            group_by_hash.insert(hash, groups.len());
            groups.push(vec![item]);
        }
    }

    for group in groups {
        result.push(merge_group(group, metadata));
    }
    result.sort_by(canonical_order);
    result
}

/// Copy user-editable fields from duplicate aliases onto the canonical metadata
/// entry before catalog names are applied. Alias entries are left untouched.
pub fn promote_duplicate_metadata(mods: &[ModEntry], metadata: &mut MetadataFile) {
    let mut groups: HashMap<String, Vec<&ModEntry>> = HashMap::new();
    for item in mods {
        if let Some(hash) = full_sha256(&item.sha256) {
            groups.entry(hash).or_default().push(item);
        }
    }

    for mut group in groups.into_values() {
        if group.len() < 2 {
            continue;
        }
        group.sort_by(|left, right| canonical_order(left, right));
        let canonical_id = group[0].id.clone();
        let enabled = group.iter().any(|entry| entry.enabled);
        let name = first_metadata_value(&group, metadata, |entry| entry.name.as_deref());
        let tags = group.iter().find_map(|entry| {
            metadata
                .entries
                .get(&entry.id)
                .map(|item| &item.tags)
                .filter(|tags| !tags.is_empty())
                .cloned()
        });
        let notes = first_metadata_value(&group, metadata, |entry| {
            (!entry.notes.trim().is_empty()).then_some(entry.notes.as_str())
        });

        let Some(canonical) = metadata.entries.get_mut(&canonical_id) else {
            continue;
        };
        if canonical
            .name
            .as_deref()
            .map(str::trim)
            .is_none_or(|name| name.is_empty())
        {
            canonical.name = name;
        }
        if canonical.tags.is_empty() {
            canonical.tags = tags.unwrap_or_default();
        }
        if canonical.notes.trim().is_empty() {
            canonical.notes = notes.unwrap_or_default();
        }
        canonical.enabled = enabled;
        for alias in group.iter().filter(|entry| entry.id != canonical_id) {
            metadata.entry_mut(&alias.id).enabled = false;
        }
    }
}

fn merge_group(mut group: Vec<ModEntry>, metadata: &MetadataFile) -> ModEntry {
    group.sort_by(canonical_order);
    let minimum_load_order = group
        .iter()
        .map(|item| item.load_order)
        .min()
        .unwrap_or_default();
    let mut primary = group.remove(0);
    let metadata_values = {
        let ordered_entries = std::iter::once(&primary)
            .chain(group.iter())
            .collect::<Vec<_>>();
        (
            first_metadata_value(&ordered_entries, metadata, |entry| entry.name.as_deref()),
            ordered_entries.iter().find_map(|entry| {
                metadata
                    .entries
                    .get(&entry.id)
                    .map(|item| &item.tags)
                    .filter(|tags| !tags.is_empty())
                    .cloned()
            }),
            first_metadata_value(&ordered_entries, metadata, |entry| {
                (!entry.notes.trim().is_empty()).then_some(entry.notes.as_str())
            }),
        )
    };

    if let Some(name) = metadata_values.0 {
        primary.name = name;
    }
    if let Some(tags) = metadata_values.1 {
        primary.tags = tags;
    }
    if let Some(notes) = metadata_values.2 {
        primary.notes = notes;
    }

    primary.load_order = minimum_load_order;
    primary.enabled |= group.iter().any(|item| item.enabled);
    primary.deployed |= group.iter().any(|item| item.deployed);
    let mut seen_aliases = HashSet::new();
    primary.duplicate_aliases = group
        .into_iter()
        .filter(|item| seen_aliases.insert(item.file_path.to_ascii_lowercase()))
        .map(|item| item.file_path)
        .collect();
    primary.duplicate_count = primary.duplicate_aliases.len();
    primary
}

fn first_metadata_value<F>(
    entries: &[&ModEntry],
    metadata: &MetadataFile,
    get_value: F,
) -> Option<String>
where
    F: Fn(&crate::metadata::ModMetadata) -> Option<&str>,
{
    entries.iter().find_map(|entry| {
        metadata
            .entries
            .get(&entry.id)
            .and_then(|item| get_value(item))
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
    })
}

fn canonical_order(left: &ModEntry, right: &ModEntry) -> Ordering {
    left.load_order
        .cmp(&right.load_order)
        .then_with(|| {
            left.file_name
                .to_ascii_lowercase()
                .cmp(&right.file_name.to_ascii_lowercase())
        })
        .then_with(|| left.file_name.cmp(&right.file_name))
        .then_with(|| left.id.cmp(&right.id))
}

fn full_sha256(value: &str) -> Option<String> {
    let hash = value.trim().to_ascii_lowercase();
    (hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit())).then_some(hash)
}

#[cfg(test)]
mod tests {
    use super::{collapse_identical_mods, promote_duplicate_metadata};
    use crate::metadata::MetadataFile;
    use crate::models::ModEntry;

    const HASH_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const HASH_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn mod_entry(id: &str, file_name: &str, sha256: &str, load_order: usize) -> ModEntry {
        ModEntry {
            id: id.to_string(),
            name: file_name.trim_end_matches(".pak").to_string(),
            author: String::new(),
            file_name: file_name.to_string(),
            file_path: format!(r"W:\mods\{file_name}"),
            file_size: 42,
            last_modified: "2026-01-01T00:00:00Z".to_string(),
            enabled: true,
            mod_type: "clientPak".to_string(),
            load_order,
            tags: Vec::new(),
            notes: String::new(),
            sha256: sha256.to_string(),
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

    #[test]
    fn merges_identical_hashes_case_insensitively() {
        let metadata = MetadataFile::default();
        let mods = vec![
            mod_entry("zeta", "Zeta.pak", &HASH_A.to_ascii_uppercase(), 0),
            mod_entry("alpha", "Alpha.pak", HASH_A, 0),
        ];

        let merged = collapse_identical_mods(mods, &metadata);

        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].id, "alpha");
        assert_eq!(merged[0].duplicate_count, 1);
        assert_eq!(merged[0].duplicate_aliases, vec![r"W:\mods\Zeta.pak"]);
    }

    #[test]
    fn keeps_different_hashes_as_separate_entries() {
        let metadata = MetadataFile::default();
        let mods = vec![
            mod_entry("alpha", "Alpha.pak", HASH_A, 0),
            mod_entry("beta", "Beta.pak", HASH_B, 0),
        ];

        let merged = collapse_identical_mods(mods, &metadata);

        assert_eq!(merged.len(), 2);
        assert!(merged.iter().all(|item| item.duplicate_count == 0));
    }

    #[test]
    fn never_merges_entries_without_a_hash() {
        let metadata = MetadataFile::default();
        let mods = vec![
            mod_entry("alpha", "Alpha.pak", "", 0),
            mod_entry("beta", "Beta.pak", "  ", 0),
            mod_entry("gamma", "Gamma.pak", "", 0),
        ];

        let merged = collapse_identical_mods(mods, &metadata);

        assert_eq!(merged.len(), 3);
        assert_eq!(
            merged
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec!["alpha", "beta", "gamma"]
        );
    }

    #[test]
    fn prefers_user_metadata_from_any_duplicate() {
        let mut metadata = MetadataFile::default();
        let preferred = metadata.entry_mut("zeta");
        preferred.name = Some("用户命名".to_string());
        preferred.tags = vec!["服务器".to_string()];
        preferred.notes = "保留这条备注".to_string();
        metadata.entry_mut("alpha");
        let mods = vec![
            mod_entry("zeta", "Zeta.pak", HASH_A, 0),
            mod_entry("alpha", "Alpha.pak", &HASH_A.to_ascii_uppercase(), 0),
        ];

        let merged = collapse_identical_mods(mods, &metadata);

        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].id, "alpha");
        assert_eq!(merged[0].name, "用户命名");
        assert_eq!(merged[0].tags, vec!["服务器"]);
        assert_eq!(merged[0].notes, "保留这条备注");
    }

    #[test]
    fn picks_canonical_stably_by_load_order_then_file_name() {
        let metadata = MetadataFile::default();
        let mods = vec![
            mod_entry("first-order", "Zeta.pak", HASH_A, 1),
            mod_entry("second-order", "Alpha.pak", HASH_A, 3),
        ];
        let merged = collapse_identical_mods(mods, &metadata);
        assert_eq!(merged[0].id, "first-order");
        assert_eq!(merged[0].load_order, 1);

        let mods = vec![
            mod_entry("zeta", "Zeta.pak", HASH_A, 2),
            mod_entry("alpha", "Alpha.pak", HASH_A, 2),
        ];
        let merged = collapse_identical_mods(mods, &metadata);
        assert_eq!(merged[0].id, "alpha");
        assert_eq!(merged[0].load_order, 2);
    }

    #[test]
    fn keeps_duplicate_metadata_untouched_for_future_aliases() {
        let mut metadata = MetadataFile::default();
        metadata.entry_mut("alpha");
        metadata.entry_mut("zeta").name = Some("别名设置".to_string());
        let mods = vec![
            mod_entry("alpha", "Alpha.pak", HASH_A, 0),
            mod_entry("zeta", "Zeta.pak", HASH_A, 0),
        ];

        let merged = collapse_identical_mods(mods, &metadata);

        assert_eq!(merged.len(), 1);
        assert_eq!(metadata.entries["zeta"].name.as_deref(), Some("别名设置"));
    }

    #[test]
    fn promotes_alias_metadata_to_canonical_without_removing_alias_settings() {
        let mut metadata = MetadataFile::default();
        metadata.entry_mut("alpha");
        let alias = metadata.entry_mut("zeta");
        alias.name = Some("别名设置".to_string());
        alias.tags = vec!["服务器".to_string()];
        alias.notes = "alias note".to_string();
        let mods = vec![
            mod_entry("alpha", "Alpha.pak", HASH_A, 0),
            mod_entry("zeta", "Zeta.pak", HASH_A, 0),
        ];

        promote_duplicate_metadata(&mods, &mut metadata);

        assert_eq!(metadata.entries["alpha"].name.as_deref(), Some("别名设置"));
        assert_eq!(metadata.entries["alpha"].tags, vec!["服务器"]);
        assert_eq!(metadata.entries["alpha"].notes, "alias note");
        assert_eq!(metadata.entries["zeta"].name.as_deref(), Some("别名设置"));
    }

    #[test]
    fn merges_enabled_state_and_disables_stale_aliases() {
        let mut metadata = MetadataFile::default();
        metadata.entry_mut("alpha").enabled = false;
        metadata.entry_mut("zeta").enabled = true;
        let mods = vec![
            mod_entry("alpha", "Alpha.pak", HASH_A, 0),
            mod_entry("zeta", "Zeta.pak", HASH_A, 0),
        ];

        promote_duplicate_metadata(&mods, &mut metadata);
        let merged = collapse_identical_mods(mods, &metadata);

        assert_eq!(merged.len(), 1);
        assert!(merged[0].enabled);
        assert!(metadata.entries["alpha"].enabled);
        assert!(!metadata.entries["zeta"].enabled);
    }
}
