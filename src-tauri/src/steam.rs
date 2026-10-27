use crate::models::DetectPathsResult;
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
    use super::quoted_strings;

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
}
