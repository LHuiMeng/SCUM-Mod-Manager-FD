use crate::models::LocaleBundle;
use crate::paths::AppPaths;
use anyhow::{Context, Result};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

const MAX_LOCALE_BYTES: u64 = 512 * 1024;
const MAX_LOCALE_DEPTH: usize = 8;
const LOCALE_README: &str = include_str!("../../locales/README.md");
const ZH_TEMPLATE: &str = include_str!("../../src/i18n/locales/zh-CN.json");
const EN_TEMPLATE: &str = include_str!("../../src/i18n/locales/en-US.json");
const OVERRIDE_EXAMPLE: &str = include_str!("../../locales/example.zh-CN.json");

pub fn load(paths: &AppPaths, language: &str) -> Result<LocaleBundle> {
    let language = normalize_language(language);
    std::fs::create_dir_all(&paths.locales_dir)
        .with_context(|| format!("无法创建翻译目录 {}", paths.locales_dir.display()))?;
    ensure_examples(paths);
    let path = paths.locales_dir.join(format!("{language}.json"));
    let mut warnings = Vec::new();
    let mut messages = BTreeMap::new();
    let mut loaded_user_file = false;

    if path.exists() {
        match read_user_locale(&path) {
            Ok(value) => {
                loaded_user_file = true;
                flatten_locale(&value, "", 0, &mut messages, &mut warnings);
            }
            Err(error) => warnings.push(format!("{}: {error:#}", path.display())),
        }
    }

    let source = if loaded_user_file {
        if warnings.is_empty() {
            "user"
        } else {
            "mixed"
        }
    } else {
        "bundled"
    };
    Ok(LocaleBundle {
        language: language.to_string(),
        messages,
        source: source.to_string(),
        locale_directory: paths.locales_dir.to_string_lossy().into_owned(),
        warnings,
    })
}

fn ensure_examples(paths: &AppPaths) {
    for (name, contents) in [
        ("README.md", LOCALE_README),
        ("zh-CN.example.json", ZH_TEMPLATE),
        ("en-US.example.json", EN_TEMPLATE),
        ("override-example.json", OVERRIDE_EXAMPLE),
    ] {
        let path = paths.locales_dir.join(name);
        if !path.exists() {
            let _ = std::fs::write(path, contents);
        }
    }
}

pub fn normalize_language(value: &str) -> &'static str {
    if value.eq_ignore_ascii_case("en-US") {
        "en-US"
    } else {
        "zh-CN"
    }
}

fn read_user_locale(path: &Path) -> Result<Value> {
    let metadata =
        std::fs::metadata(path).with_context(|| format!("无法读取 {}", path.display()))?;
    if !metadata.is_file() {
        anyhow::bail!("不是普通文件");
    }
    if metadata.len() > MAX_LOCALE_BYTES {
        anyhow::bail!("文件超过 {} KiB 上限", MAX_LOCALE_BYTES / 1024);
    }
    let raw =
        std::fs::read_to_string(path).with_context(|| format!("无法读取 {}", path.display()))?;
    let value: Value = serde_json::from_str(&raw).context("JSON 格式无效")?;
    if !value.is_object() {
        anyhow::bail!("根节点必须是 JSON 对象");
    }
    Ok(value)
}

fn flatten_locale(
    value: &Value,
    prefix: &str,
    depth: usize,
    output: &mut BTreeMap<String, String>,
    warnings: &mut Vec<String>,
) {
    if depth > MAX_LOCALE_DEPTH {
        warnings.push(format!("忽略层级过深的节点：{prefix}"));
        return;
    }
    let Some(object) = value.as_object() else {
        return;
    };
    for (key, child) in object {
        let full_key = if prefix.is_empty() {
            key.clone()
        } else {
            format!("{prefix}.{key}")
        };
        match child {
            Value::String(text) => {
                output.insert(full_key, text.clone());
            }
            Value::Object(_) => {
                flatten_locale(child, &full_key, depth + 1, output, warnings);
            }
            Value::Number(_) | Value::Bool(_) => {
                output.insert(full_key, child.to_string());
            }
            Value::Null | Value::Array(_) => {
                warnings.push(format!("忽略不支持的值：{full_key}"));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{load, normalize_language};
    use crate::test_support::TempRoot;
    use serde_json::json;
    use std::fs;

    #[test]
    fn normalizes_unknown_languages_to_chinese() {
        assert_eq!(normalize_language("en-US"), "en-US");
        assert_eq!(normalize_language("en-us"), "en-US");
        assert_eq!(normalize_language("fr-FR"), "zh-CN");
    }

    #[test]
    fn flattens_user_overrides_and_keeps_unknown_keys() {
        let temp = TempRoot::new("locale-overrides");
        let paths = temp.paths();
        fs::create_dir_all(&paths.locales_dir).unwrap();
        fs::write(
            paths.locales_dir.join("en-US.json"),
            serde_json::to_vec_pretty(&json!({
                "library": {
                    "title": "My Library",
                    "scan": "Rescan"
                },
                "custom": {
                    "welcome": "Hello"
                }
            }))
            .unwrap(),
        )
        .unwrap();

        let bundle = load(&paths, "en-US").unwrap();

        assert_eq!(bundle.source, "user");
        assert_eq!(bundle.messages.get("library.title").unwrap(), "My Library");
        assert_eq!(bundle.messages.get("custom.welcome").unwrap(), "Hello");
    }

    #[test]
    fn invalid_user_file_falls_back_with_a_warning() {
        let temp = TempRoot::new("locale-invalid");
        let paths = temp.paths();
        fs::create_dir_all(&paths.locales_dir).unwrap();
        fs::write(paths.locales_dir.join("zh-CN.json"), b"{broken").unwrap();

        let bundle = load(&paths, "zh-CN").unwrap();

        assert_eq!(bundle.source, "bundled");
        assert!(!bundle.warnings.is_empty());
        assert!(bundle.messages.is_empty());
    }

    #[test]
    fn seeds_examples_without_overwriting_user_files() {
        let temp = TempRoot::new("locale-examples");
        let paths = temp.paths();
        fs::create_dir_all(&paths.locales_dir).unwrap();
        fs::write(paths.locales_dir.join("README.md"), "custom readme").unwrap();

        load(&paths, "zh-CN").unwrap();

        assert_eq!(
            fs::read_to_string(paths.locales_dir.join("README.md")).unwrap(),
            "custom readme"
        );
        assert!(paths.locales_dir.join("zh-CN.example.json").exists());
        assert!(paths.locales_dir.join("en-US.example.json").exists());
        assert!(paths.locales_dir.join("override-example.json").exists());
    }
}
