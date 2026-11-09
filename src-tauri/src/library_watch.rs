use crate::paths::AppPaths;
use crate::state::AppState;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::Path;
use std::time::{Duration, Instant, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager};

pub const LIBRARY_CHANGED_EVENT: &str = "library-changed";

const POLL_INTERVAL: Duration = Duration::from_millis(900);
const SETTLE_INTERVAL: Duration = Duration::from_millis(350);
const MAX_SETTLE_TIME: Duration = Duration::from_secs(8);

pub fn spawn(app: AppHandle) {
    let _ = std::thread::Builder::new()
        .name("library-watch".to_string())
        .spawn(move || watch_loop(app));
}

fn watch_loop(app: AppHandle) {
    let mut last_signature = {
        let state = app.state::<AppState>();
        library_signature(&state.paths)
    };
    loop {
        std::thread::sleep(POLL_INTERVAL);
        let state = app.state::<AppState>();
        let current = library_signature(&state.paths);
        if current == last_signature {
            continue;
        }
        let settled = wait_for_settled_signature(&state.paths, current);
        match state.refresh_files() {
            Ok(snapshot) => {
                last_signature = settled;
                let _ = app.emit(LIBRARY_CHANGED_EVENT, snapshot);
            }
            Err(error) => {
                // 记录一次即可，下一轮签名变化时再重试，避免失败时每个轮询周期刷日志。
                last_signature = settled;
                state.log(
                    "warn",
                    "library",
                    &format!("检测到模组目录变化，但自动刷新失败：{error:#}"),
                );
            }
        }
    }
}

/// 复制大 PAK 时目录会连续变化；等到签名稳定一小段时间后再扫描，
/// 避免把只写了一半的文件算进模组库。
fn wait_for_settled_signature(paths: &AppPaths, initial: u64) -> u64 {
    let started = Instant::now();
    let mut signature = initial;
    loop {
        std::thread::sleep(SETTLE_INTERVAL);
        let next = library_signature(paths);
        if next == signature {
            return signature;
        }
        signature = next;
        if started.elapsed() >= MAX_SETTLE_TIME {
            return signature;
        }
    }
}

fn library_signature(paths: &AppPaths) -> u64 {
    let mut entries: Vec<(String, u8, u64, u64)> = Vec::new();
    collect_pak_files(&paths.local_mods, &mut entries);
    collect_ue4ss_directories(&paths.ue4ss_mods, &mut entries);
    entries.sort();

    let mut hasher = DefaultHasher::new();
    for entry in entries {
        entry.hash(&mut hasher);
    }
    hasher.finish()
}

fn collect_pak_files(directory: &Path, entries: &mut Vec<(String, u8, u64, u64)>) {
    let Ok(read_dir) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in read_dir.flatten() {
        let path = entry.path();
        if !path.is_file()
            || !path
                .extension()
                .is_some_and(|extension| extension.to_string_lossy().eq_ignore_ascii_case("pak"))
        {
            continue;
        }
        push_signature_entry(entries, &path, 0, entry.metadata().ok());
    }
}

fn collect_ue4ss_directories(directory: &Path, entries: &mut Vec<(String, u8, u64, u64)>) {
    let Ok(read_dir) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in read_dir.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        push_signature_entry(entries, &path, 1, entry.metadata().ok());
    }
}

fn push_signature_entry(
    entries: &mut Vec<(String, u8, u64, u64)>,
    path: &Path,
    kind: u8,
    metadata: Option<std::fs::Metadata>,
) {
    let Some(metadata) = metadata else {
        return;
    };
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or_default();
    entries.push((
        path.file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default(),
        kind,
        metadata.len(),
        modified,
    ));
}

#[cfg(test)]
mod tests {
    use super::library_signature;
    use crate::test_support::TempRoot;

    #[test]
    fn signature_changes_when_a_mod_is_renamed() {
        let temp = TempRoot::new("library-watch-signature");
        let paths = temp.paths();
        std::fs::write(paths.local_mods.join("Alpha.pak"), b"alpha").unwrap();
        let before = library_signature(&paths);

        std::fs::rename(
            paths.local_mods.join("Alpha.pak"),
            paths.local_mods.join("Renamed.pak"),
        )
        .unwrap();

        assert_ne!(library_signature(&paths), before);
    }

    #[test]
    fn signature_ignores_non_mod_files() {
        let temp = TempRoot::new("library-watch-ignore");
        let paths = temp.paths();
        std::fs::write(paths.local_mods.join("Alpha.pak"), b"alpha").unwrap();
        let before = library_signature(&paths);

        std::fs::write(paths.local_mods.join("readme.txt"), b"not a mod").unwrap();

        assert_eq!(library_signature(&paths), before);
    }
}
