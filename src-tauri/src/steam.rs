use crate::models::{AppSettings, DetectPathsResult};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

pub fn detect_game_paths() -> DetectPathsResult {
    let client_env = std::env::var("SCUM_MM_CLIENT_PATH").unwrap_or_default();
    let server_env = std::env::var("SCUM_MM_SERVER_PATH").unwrap_or_default();
    let mut client = if Path::new(&client_env).is_dir() {
        client_env
    } else {
        String::new()
    };
    let mut server = if Path::new(&server_env).is_dir() {
        server_env
    } else {
        String::new()
    };

    for library in steam_libraries() {
        let common = library.join("steamapps").join("common");
        let client_candidate = common.join("SCUM");
        let server_candidate = common.join("SCUM Server");
        if client.is_empty() && client_candidate.is_dir() {
            client = client_candidate.to_string_lossy().into_owned();
        }
        if server.is_empty() && server_candidate.is_dir() {
            server = server_candidate.to_string_lossy().into_owned();
        }
        if !client.is_empty() && !server.is_empty() {
            break;
        }
    }

    DetectPathsResult {
        scum_install_path: client,
        server_install_path: server,
    }
}

/// 首次启动或配置里缺少路径时，把检测结果写入空白字段。
///
/// 用户已经手动填写的路径优先级更高，自动检测不会覆盖。
pub fn fill_missing_settings_paths(
    settings: &mut AppSettings,
    detected: DetectPathsResult,
) -> bool {
    let mut changed = false;
    if settings.scum_install_path.trim().is_empty() && !detected.scum_install_path.trim().is_empty()
    {
        settings.scum_install_path = detected.scum_install_path;
        changed = true;
    }
    if settings.server_install_path.trim().is_empty()
        && !detected.server_install_path.trim().is_empty()
    {
        settings.server_install_path = detected.server_install_path;
        changed = true;
    }
    changed
}

fn steam_libraries() -> Vec<PathBuf> {
    let mut libraries = Vec::new();
    let Some(steam_path) = steam_install_path() else {
        return libraries;
    };
    libraries.push(steam_path.clone());
    let vdf = steam_path.join("steamapps").join("libraryfolders.vdf");
    let Ok(text) = std::fs::read_to_string(vdf) else {
        return libraries;
    };
    let quoted = quoted_strings(&text);
    let mut seen: HashSet<String> = libraries
        .iter()
        .map(|path| path.to_string_lossy().to_ascii_lowercase())
        .collect();
    for (index, value) in quoted.iter().enumerate() {
        let key = quoted.get(index.wrapping_sub(1)).map(String::as_str);
        if !(key.is_some_and(|key| {
            key.eq_ignore_ascii_case("path") || key.chars().all(|ch| ch.is_ascii_digit())
        })) {
            continue;
        }
        let path = PathBuf::from(value.replace("\\\\", "\\"));
        if path.is_dir() && seen.insert(path.to_string_lossy().to_ascii_lowercase()) {
            libraries.push(path);
        }
    }
    libraries
}

fn quoted_strings(text: &str) -> Vec<String> {
    let mut values = Vec::new();
    let mut current = String::new();
    let mut inside = false;
    let mut escaped = false;
    for ch in text.chars() {
        if !inside {
            if ch == '"' {
                inside = true;
                current.clear();
            }
            continue;
        }
        if escaped {
            current.push(ch);
            escaped = false;
        } else if ch == '\\' {
            current.push(ch);
            escaped = true;
        } else if ch == '"' {
            values.push(current.clone());
            inside = false;
        } else {
            current.push(ch);
        }
    }
    values
}

#[cfg(windows)]
fn steam_install_path() -> Option<PathBuf> {
    use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_READ};
    use winreg::RegKey;

    let paths = [
        (
            RegKey::predef(HKEY_LOCAL_MACHINE),
            r"SOFTWARE\WOW6432Node\Valve\Steam",
        ),
        (RegKey::predef(HKEY_LOCAL_MACHINE), r"SOFTWARE\Valve\Steam"),
        (RegKey::predef(HKEY_CURRENT_USER), r"Software\Valve\Steam"),
    ];
    for (root, path) in paths {
        if let Ok(key) = root.open_subkey_with_flags(path, KEY_READ) {
            if let Ok(value) = key.get_value::<String, _>("InstallPath") {
                let path = PathBuf::from(value);
                if path.is_dir() {
                    return Some(path);
                }
            }
        }
    }
    None
}

#[cfg(not(windows))]
fn steam_install_path() -> Option<PathBuf> {
    None
}

#[cfg(test)]
mod tests {
    use super::{fill_missing_settings_paths, quoted_strings};
    use crate::models::{AppSettings, DetectPathsResult};

    #[test]
    fn parses_quoted_values_with_escaped_backslashes() {
        let vdf = r#"
            "libraryfolders"
            {
                "0" { "path" "C:\\Program Files (x86)\\Steam" }
                "1" { "path" "D:\\SteamLibrary" }
            }
        "#;

        assert_eq!(
            quoted_strings(vdf),
            vec![
                "libraryfolders",
                "0",
                "path",
                r"C:\\Program Files (x86)\\Steam",
                "1",
                "path",
                r"D:\\SteamLibrary"
            ]
        );
    }

    #[test]
    fn fills_only_missing_install_paths() {
        let mut settings = AppSettings {
            scum_install_path: String::new(),
            server_install_path: r"D:\My SCUM Server".to_string(),
            ..AppSettings::default()
        };
        let detected = DetectPathsResult {
            scum_install_path: r"X:\Steam\steamapps\common\SCUM".to_string(),
            server_install_path: r"X:\Steam\steamapps\common\SCUM Server".to_string(),
        };

        assert!(fill_missing_settings_paths(&mut settings, detected));
        assert_eq!(
            settings.scum_install_path,
            r"X:\Steam\steamapps\common\SCUM"
        );
        assert_eq!(
            settings.server_install_path, r"D:\My SCUM Server",
            "用户已填写的路径不能被自动检测覆盖"
        );
    }

    #[test]
    fn reports_no_change_when_nothing_can_be_filled() {
        let mut settings = AppSettings::default();
        let detected = DetectPathsResult {
            scum_install_path: String::new(),
            server_install_path: String::new(),
        };

        assert!(!fill_missing_settings_paths(&mut settings, detected));
    }
}
