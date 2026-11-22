use super::pak_scan;
use crate::metadata::MetadataFile;
use crate::models::{ConflictMergeResult, ModEntry};
use crate::paths::{is_within, path_string, AppPaths};
use anyhow::{bail, Context, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;

const MERGE_CACHE_VERSION: u32 = 1;
const MERGE_CACHE_DIR: &str = "conflict_merge";
const MERGE_CACHE_PAK: &str = "merged.pak";
const MERGE_CACHE_META: &str = "meta.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MergeCacheMetadata {
    version: u32,
    fingerprint: String,
    created_at: String,
    source_mods: usize,
    entries: usize,
    file_size: u64,
}

#[derive(Debug, Clone)]
pub(crate) struct ConflictMergePlan {
    selected_entries: BTreeMap<String, (String, PathBuf)>,
    conflicting_ids: HashSet<String>,
    fingerprint: String,
}

impl ConflictMergePlan {
    pub(crate) fn fingerprint(&self) -> &str {
        &self.fingerprint
    }

    pub(crate) fn source_mods(&self) -> usize {
        self.conflicting_ids.len()
    }

    pub(crate) fn entry_count(&self) -> usize {
        self.selected_entries.len()
    }
}

#[derive(Debug, Clone)]
pub(crate) struct MergeArtifact {
    pub(crate) path: PathBuf,
    pub(crate) cache_hit: bool,
    pub(crate) source_mods: usize,
    pub(crate) entries: usize,
    pub(crate) bytes: u64,
}

pub(crate) fn create_plan(
    mods: &[ModEntry],
    analysis: &pak_scan::ConflictAnalysis,
    metadata: &MetadataFile,
) -> Result<Option<ConflictMergePlan>> {
    let conflicting_ids = analysis
        .groups
        .iter()
        .flat_map(|group| group.owners.iter().map(|owner| owner.id.as_str()))
        .collect::<HashSet<_>>();
    if conflicting_ids.is_empty() {
        return Ok(None);
    }

    let mods_by_id = mods
        .iter()
        .map(|item| (item.id.as_str(), item))
        .collect::<HashMap<_, _>>();
    let mut selected_entries: BTreeMap<String, (String, PathBuf)> = BTreeMap::new();
    for group in &analysis.groups {
        let winner = mods_by_id
            .get(group.winner_id.as_str())
            .with_context(|| format!("找不到冲突组的合并胜者：{}", group.winner_id))?;
        if !winner.enabled || winner.mod_type != "clientPak" {
            bail!("冲突组的合并胜者当前不可部署：{}", winner.name);
        }
        let pak_path = PathBuf::from(&winner.file_path);
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
        return Ok(None);
    }

    let fingerprint = fingerprint_plan(mods, analysis, &selected_entries);
    Ok(Some(ConflictMergePlan {
        selected_entries,
        conflicting_ids: conflicting_ids.into_iter().map(str::to_string).collect(),
        fingerprint,
    }))
}

pub(crate) fn cached_artifact(paths: &AppPaths, plan: &ConflictMergePlan) -> Option<PathBuf> {
    let metadata = read_cache_metadata(paths)?;
    if metadata.version != MERGE_CACHE_VERSION || metadata.fingerprint != plan.fingerprint {
        return None;
    }
    let pak = cache_pak(paths);
    let file_size = std::fs::metadata(&pak).ok()?.len();
    (pak.is_file() && file_size > 0 && file_size == metadata.file_size).then_some(pak)
}

pub(crate) fn ensure_artifact(paths: &AppPaths, plan: &ConflictMergePlan) -> Result<MergeArtifact> {
    if let Some(path) = cached_artifact(paths, plan) {
        let bytes = std::fs::metadata(&path)?.len();
        return Ok(MergeArtifact {
            path,
            cache_hit: true,
            source_mods: plan.source_mods(),
            entries: plan.entry_count(),
            bytes,
        });
    }

    build_cache(paths, plan)?;
    let path = cache_pak(paths);
    let bytes = std::fs::metadata(&path)
        .with_context(|| format!("融合缓存未生成：{}", path.display()))?
        .len();
    Ok(MergeArtifact {
        path,
        cache_hit: false,
        source_mods: plan.source_mods(),
        entries: plan.entry_count(),
        bytes,
    })
}

pub(crate) fn prepare(
    paths: &AppPaths,
    mods: &[ModEntry],
    metadata: &MetadataFile,
) -> Result<ConflictMergeResult> {
    let analysis = pak_scan::analyze_conflicts(metadata, mods);
    let Some(plan) = create_plan(mods, &analysis, metadata)? else {
        clear_cache(paths);
        return Ok(ConflictMergeResult {
            required: false,
            cache_hit: false,
            rebuilt: false,
            source_mods: 0,
            entries: 0,
            bytes: 0,
            message: "当前没有资源冲突，无需融合".to_string(),
        });
    };
    let artifact = ensure_artifact(paths, &plan)?;
    Ok(ConflictMergeResult {
        required: true,
        cache_hit: artifact.cache_hit,
        rebuilt: !artifact.cache_hit,
        source_mods: artifact.source_mods,
        entries: artifact.entries,
        bytes: artifact.bytes,
        message: if artifact.cache_hit {
            format!(
                "冲突融合已是最新：{} 个模组，{} 个资源",
                artifact.source_mods, artifact.entries
            )
        } else {
            format!(
                "已融合 {} 个冲突模组，共 {} 个资源",
                artifact.source_mods, artifact.entries
            )
        },
    })
}

fn build_cache(paths: &AppPaths, plan: &ConflictMergePlan) -> Result<()> {
    let cache_root = cache_root(paths);
    std::fs::create_dir_all(&cache_root)
        .with_context(|| format!("无法创建融合缓存目录 {}", cache_root.display()))?;
    let stage_root = cache_root.join(format!(".build-{}", uuid::Uuid::new_v4()));
    let tree = stage_root.join("tree");
    let output = stage_root.join(MERGE_CACHE_PAK);
    let metadata_path = stage_root.join(MERGE_CACHE_META);

    let result = (|| -> Result<()> {
        std::fs::create_dir_all(&tree)
            .with_context(|| format!("无法创建融合暂存目录 {}", tree.display()))?;
        let mut entries_by_source: BTreeMap<PathBuf, Vec<String>> = BTreeMap::new();
        for (_, (resource, pak_path)) in &plan.selected_entries {
            entries_by_source
                .entry(pak_path.clone())
                .or_default()
                .push(resource.clone());
        }
        let mut expected = BTreeSet::new();
        for (source_index, (pak_path, resources)) in entries_by_source.iter().enumerate() {
            if !pak_path.is_file() {
                bail!("参与冲突合并的 PAK 文件不存在：{}", pak_path.display());
            }
            let source_root = stage_root
                .join("sources")
                .join(format!("{source_index:04}"));
            pak_scan::extract_pak_entries(paths, pak_path, resources, &source_root)?;
            for resource in resources {
                let relative = safe_pak_relative_path(resource)?;
                let source = source_root.join(&relative);
                let destination = tree.join(&relative);
                if !is_within(&source, &source_root) || !is_within(&destination, &tree) {
                    bail!("融合暂存路径越界：{resource}");
                }
                if !source.is_file() {
                    bail!("冲突合并无法读取资源 {resource}：{}", pak_path.display());
                }
                if let Some(parent) = destination.parent() {
                    std::fs::create_dir_all(parent)
                        .with_context(|| format!("无法创建融合资源目录 {}", parent.display()))?;
                }
                if std::fs::hard_link(&source, &destination).is_err() {
                    std::fs::copy(&source, &destination).with_context(|| {
                        format!(
                            "无法复制融合资源 {} 到 {}",
                            source.display(),
                            destination.display()
                        )
                    })?;
                }
                expected.insert(resource.to_ascii_lowercase());
            }
        }
        pak_scan::pack_pak(paths, &tree, &output)?;
        let packed = pak_scan::list_pak_entries(paths, &output)?
            .into_iter()
            .map(|entry| entry.to_ascii_lowercase())
            .collect::<BTreeSet<_>>();
        if !expected.is_subset(&packed) {
            bail!("冲突合并 PAK 校验失败：打包结果缺少预期资源");
        }

        let file_size = std::fs::metadata(&output)?.len();
        let metadata = MergeCacheMetadata {
            version: MERGE_CACHE_VERSION,
            fingerprint: plan.fingerprint.clone(),
            created_at: Utc::now().to_rfc3339(),
            source_mods: plan.source_mods(),
            entries: plan.entry_count(),
            file_size,
        };
        std::fs::write(
            &metadata_path,
            format!("{}\n", serde_json::to_string_pretty(&metadata)?),
        )?;

        let final_pak = cache_pak(paths);
        let final_meta = cache_meta(paths);
        if final_pak.exists() {
            std::fs::remove_file(&final_pak)
                .with_context(|| format!("无法替换旧融合缓存 {}", final_pak.display()))?;
        }
        if final_meta.exists() {
            std::fs::remove_file(&final_meta)
                .with_context(|| format!("无法替换旧融合缓存信息 {}", final_meta.display()))?;
        }
        std::fs::rename(&output, &final_pak)
            .with_context(|| format!("无法保存融合缓存 {}", final_pak.display()))?;
        std::fs::rename(&metadata_path, &final_meta)
            .with_context(|| format!("无法保存融合缓存信息 {}", final_meta.display()))?;
        Ok(())
    })();

    let _ = std::fs::remove_dir_all(&stage_root);
    result
}

fn read_cache_metadata(paths: &AppPaths) -> Option<MergeCacheMetadata> {
    let text = std::fs::read_to_string(cache_meta(paths)).ok()?;
    serde_json::from_str(&text).ok()
}

fn clear_cache(paths: &AppPaths) {
    let _ = std::fs::remove_file(cache_pak(paths));
    let _ = std::fs::remove_file(cache_meta(paths));
}

fn cache_root(paths: &AppPaths) -> PathBuf {
    paths.root.join("cache").join(MERGE_CACHE_DIR)
}

fn cache_pak(paths: &AppPaths) -> PathBuf {
    cache_root(paths).join(MERGE_CACHE_PAK)
}

fn cache_meta(paths: &AppPaths) -> PathBuf {
    cache_root(paths).join(MERGE_CACHE_META)
}

fn fingerprint_plan(
    mods: &[ModEntry],
    analysis: &pak_scan::ConflictAnalysis,
    selected_entries: &BTreeMap<String, (String, PathBuf)>,
) -> String {
    let mods_by_path = mods
        .iter()
        .map(|item| (normalized_path(Path::new(&item.file_path)), item))
        .collect::<HashMap<_, _>>();
    let mut hasher = Sha256::new();
    hash_field(&mut hasher, "scum-mod-desk-conflict-merge");
    hash_field(&mut hasher, env!("CARGO_PKG_VERSION"));
    hash_field(&mut hasher, &MERGE_CACHE_VERSION.to_string());

    for group in &analysis.groups {
        hash_field(&mut hasher, &group.key);
        hash_field(&mut hasher, &group.winner_id);
        for path in &group.paths {
            hash_field(&mut hasher, path);
        }
    }
    let mut source_identities = HashMap::new();
    for (_, pak_path) in selected_entries.values() {
        let key = normalized_path(pak_path);
        source_identities
            .entry(key.clone())
            .or_insert_with(|| source_identity(mods_by_path.get(&key).copied(), pak_path));
    }
    for (key, (resource, pak_path)) in selected_entries {
        hash_field(&mut hasher, key);
        hash_field(&mut hasher, resource);
        let source_key = normalized_path(pak_path);
        hash_field(&mut hasher, &source_key);
        hash_field(
            &mut hasher,
            source_identities
                .get(&source_key)
                .map(String::as_str)
                .unwrap_or_default(),
        );
    }
    hex::encode(hasher.finalize())
}

fn source_identity(source: Option<&ModEntry>, pak_path: &Path) -> String {
    let actual = std::fs::metadata(pak_path).ok();
    let size = actual
        .as_ref()
        .map(std::fs::Metadata::len)
        .or_else(|| source.map(|item| item.file_size))
        .unwrap_or_default();
    let sha256 = source.map(|item| item.sha256.as_str()).unwrap_or_default();
    // 有内容哈希时不把 mtime 计入身份：同内容重导入只会抬 mtime，不应让融合缓存失效。
    let modified = if sha256.trim().is_empty() {
        actual
            .and_then(|metadata| metadata.modified().ok())
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_nanos().to_string())
            .or_else(|| source.map(|item| item.last_modified.clone()))
            .unwrap_or_default()
    } else {
        String::new()
    };
    let id = source.map(|item| item.id.as_str()).unwrap_or_default();
    format!("{id}|{size}|{modified}|{sha256}")
}

fn normalized_path(path: &Path) -> String {
    path_string(&std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf()))
        .replace('/', "\\")
        .to_ascii_lowercase()
}

fn hash_field(hasher: &mut Sha256, value: &str) {
    hasher.update((value.len() as u64).to_le_bytes());
    hasher.update(value.as_bytes());
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

#[cfg(test)]
mod tests {
    use super::create_plan;
    use crate::metadata::MetadataFile;
    use crate::models::ModEntry;
    use crate::mods::pak_scan;

    fn conflicting_mod(id: &str, order: usize) -> ModEntry {
        ModEntry {
            id: id.to_string(),
            name: id.to_string(),
            file_path: format!("C:/mods/{id}.pak"),
            file_name: format!("{id}.pak"),
            enabled: true,
            mod_type: "clientPak".to_string(),
            load_order: order,
            file_size: 1024,
            last_modified: "2026-01-01T00:00:00Z".to_string(),
            sha256: format!("hash-{id}"),
            ..ModEntry::default()
        }
    }

    fn metadata_for(mods: &[ModEntry]) -> MetadataFile {
        let mut metadata = MetadataFile::default();
        for item in mods {
            metadata.entry_mut(&item.id).pak_entries = vec![
                "SCUM/Content/Shared.uasset".to_string(),
                format!("SCUM/Content/{}.txt", item.id),
            ];
        }
        metadata
    }

    #[test]
    fn non_conflicting_mods_do_not_change_merge_fingerprint() {
        let alpha = conflicting_mod("alpha", 0);
        let beta = conflicting_mod("beta", 1);
        let metadata = metadata_for(&[alpha.clone(), beta.clone()]);
        let analysis = pak_scan::analyze_conflicts(&metadata, &[alpha.clone(), beta.clone()]);
        let first = create_plan(&[alpha.clone(), beta.clone()], &analysis, &metadata)
            .unwrap()
            .unwrap();

        let mut gamma = conflicting_mod("gamma", 2);
        gamma.file_path = "C:/mods/gamma.pak".to_string();
        let mut metadata = metadata_for(&[alpha.clone(), beta.clone(), gamma.clone()]);
        metadata.entry_mut("gamma").pak_entries = vec!["SCUM/Content/GammaOnly.uasset".to_string()];
        let all_mods = vec![alpha, beta, gamma];
        let analysis = pak_scan::analyze_conflicts(&metadata, &all_mods);
        let second = create_plan(&all_mods, &analysis, &metadata)
            .unwrap()
            .unwrap();

        assert_eq!(first.fingerprint(), second.fingerprint());
    }

    #[test]
    fn reordering_conflicting_mods_changes_merge_fingerprint() {
        let alpha = conflicting_mod("alpha", 0);
        let beta = conflicting_mod("beta", 1);
        let metadata = metadata_for(&[alpha.clone(), beta.clone()]);
        let analysis = pak_scan::analyze_conflicts(&metadata, &[alpha.clone(), beta.clone()]);
        let first = create_plan(&[alpha.clone(), beta.clone()], &analysis, &metadata)
            .unwrap()
            .unwrap();

        let mut alpha = alpha;
        let mut beta = beta;
        alpha.load_order = 1;
        beta.load_order = 0;
        let analysis = pak_scan::analyze_conflicts(&metadata, &[beta.clone(), alpha.clone()]);
        let second = create_plan(&[beta, alpha], &analysis, &metadata)
            .unwrap()
            .unwrap();

        assert_ne!(first.fingerprint(), second.fingerprint());
    }

    #[test]
    fn merge_fingerprint_stays_stable_when_only_mtime_changes() {
        let alpha = conflicting_mod("alpha", 0);
        let beta = conflicting_mod("beta", 1);
        let metadata = metadata_for(&[alpha.clone(), beta.clone()]);
        let analysis = pak_scan::analyze_conflicts(&metadata, &[alpha.clone(), beta.clone()]);
        let first = create_plan(&[alpha.clone(), beta.clone()], &analysis, &metadata)
            .unwrap()
            .unwrap();

        // 同内容重导入：last_modified 被抬高，内容哈希不变。
        let mut alpha_reimported = alpha.clone();
        alpha_reimported.last_modified = "2026-06-01T00:00:00Z".to_string();
        let mut beta_reimported = beta.clone();
        beta_reimported.last_modified = "2026-06-01T00:00:00Z".to_string();
        let analysis = pak_scan::analyze_conflicts(
            &metadata,
            &[alpha_reimported.clone(), beta_reimported.clone()],
        );
        let second = create_plan(&[alpha_reimported, beta_reimported], &analysis, &metadata)
            .unwrap()
            .unwrap();

        assert_eq!(
            first.fingerprint(),
            second.fingerprint(),
            "同内容重导入只抬 mtime，不应让融合缓存失效"
        );
    }
}
