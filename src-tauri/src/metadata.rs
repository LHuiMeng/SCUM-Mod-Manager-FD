use crate::paths::AppPaths;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

fn default_enabled() -> bool {
    true
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ModMetadata {
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    pub tags: Vec<String>,
    pub notes: String,
    pub sha256: String,
    #[serde(alias = "pak_entries")]
    pub pak_entries: Vec<String>,
    pub conflicts: HashMap<String, Vec<String>>,
    #[serde(alias = "file_size")]
    pub file_size: Option<u64>,
    #[serde(alias = "modified_at")]
    pub modified_at: Option<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MetadataFile {
    #[serde(rename = "__order__", default, skip_serializing_if = "Vec::is_empty")]
    pub order: Vec<String>,
    #[serde(flatten)]
    pub entries: BTreeMap<String, ModMetadata>,
}

impl MetadataFile {
    pub fn entry_mut(&mut self, id: &str) -> &mut ModMetadata {
        self.entries
            .entry(id.to_string())
            .or_insert_with(|| ModMetadata {
                enabled: true,
                ..ModMetadata::default()
            })
    }
}

pub fn load_metadata(paths: &AppPaths) -> Result<MetadataFile> {
    if !paths.metadata_file.exists() {
        return Ok(MetadataFile::default());
    }
    let text = std::fs::read_to_string(&paths.metadata_file)
        .with_context(|| format!("无法读取 {}", paths.metadata_file.display()))?;
    if text.trim().is_empty() {
        return Ok(MetadataFile::default());
    }
    serde_json::from_str(&text).context("mods_meta.json 格式无效")
}

pub fn save_metadata_at(path: &Path, metadata: &MetadataFile) -> Result<()> {
    let json = serde_json::to_string_pretty(metadata)?;
    std::fs::write(path, format!("{json}\n"))
        .with_context(|| format!("无法写入 {}", path.display()))?;
    Ok(())
}

pub fn save_metadata(paths: &AppPaths, metadata: &MetadataFile) -> Result<()> {
    save_metadata_at(&paths.metadata_file, metadata)
}

#[cfg(test)]
mod tests {
    use super::{load_metadata, save_metadata, MetadataFile};
    use crate::test_support::TempRoot;

    #[test]
    fn persists_order_enabled_tags_and_notes() {
        let temp = TempRoot::new("metadata-persistence");
        let paths = temp.paths();
        let mut metadata = MetadataFile {
            order: vec!["second".to_string(), "first".to_string()],
            ..MetadataFile::default()
        };
        let second = metadata.entry_mut("second");
        second.enabled = false;
        second.tags = vec!["server".to_string(), "balance".to_string()];
        second.notes = "测试备注".to_string();
        let first = metadata.entry_mut("first");
        first.enabled = true;
        first.tags = vec!["client".to_string()];
        first.notes = "keep enabled".to_string();

        save_metadata(&paths, &metadata).unwrap();
        let loaded = load_metadata(&paths).unwrap();

        assert_eq!(loaded.order, vec!["second", "first"]);
        assert!(!loaded.entries["second"].enabled);
        assert_eq!(loaded.entries["second"].tags, vec!["server", "balance"]);
        assert_eq!(loaded.entries["second"].notes, "测试备注");
        assert!(loaded.entries["first"].enabled);
        assert_eq!(loaded.entries["first"].tags, vec!["client"]);
        assert_eq!(loaded.entries["first"].notes, "keep enabled");
    }

    #[test]
    fn missing_enabled_field_defaults_to_true() {
        let temp = TempRoot::new("metadata-default-enabled");
        let paths = temp.paths();
        std::fs::write(
            &paths.metadata_file,
            r#"{"__order__":["demo"],"demo":{"tags":[],"notes":""}}"#,
        )
        .unwrap();

        let loaded = load_metadata(&paths).unwrap();

        assert!(loaded.entries["demo"].enabled);
    }
}
