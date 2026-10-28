use crate::app_update;
use crate::cloud;
use crate::launcher;
use crate::models::{
    AppInfo, AppSettings, AppUpdateInfo, CloudDownloadProgress, DetectPathsResult, DownloadResult,
    GameStatus, ImportResult, InstallUpdateResult, LibrarySnapshot, RemoteFile, RemoteMod,
    RuntimeLog, SftpAccountInput, SftpConnectionResult, UploadResult,
};
use crate::paths::path_string;
use crate::sftp;
use crate::state::AppState;
use crate::steam;
use std::collections::HashSet;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use tauri::{AppHandle, Emitter, Manager, State, WebviewWindow};

static ACTIVE_DOWNLOADS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

struct DownloadGuard {
    key: String,
}

impl Drop for DownloadGuard {
    fn drop(&mut self) {
        let downloads = ACTIVE_DOWNLOADS.get_or_init(|| Mutex::new(HashSet::new()));
        let mut active = downloads
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        active.remove(&self.key);
    }
}

fn begin_download(id: &str) -> Result<DownloadGuard, String> {
    let key = id.trim().to_ascii_lowercase();
    let downloads = ACTIVE_DOWNLOADS.get_or_init(|| Mutex::new(HashSet::new()));
    let mut active = downloads
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if !active.insert(key.clone()) {
        return Err("该模组正在下载，请等待当前任务完成".to_string());
    }
    Ok(DownloadGuard { key })
}

fn error_text(error: impl std::fmt::Display) -> String {
    error.to_string()
}

#[tauri::command]
pub fn get_library_snapshot(state: State<'_, AppState>) -> Result<LibrarySnapshot, String> {
    Ok(state.snapshot())
}

#[tauri::command]
pub async fn scan_library(app: AppHandle) -> Result<LibrarySnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || app.state::<AppState>().scan(true))
        .await
        .map_err(error_text)?
        .map_err(error_text)
}

#[tauri::command]
pub async fn set_mod_enabled(
    app: AppHandle,
    id: String,
    enabled: bool,
) -> Result<LibrarySnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || {
        app.state::<AppState>().set_mod_enabled(&id, enabled)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn reorder_mods(app: AppHandle, ids: Vec<String>) -> Result<LibrarySnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || app.state::<AppState>().reorder_mods(&ids))
        .await
        .map_err(error_text)?
        .map_err(error_text)
}

#[tauri::command]
pub async fn update_mod_metadata(
    app: AppHandle,
    id: String,
    tags: Vec<String>,
    notes: String,
) -> Result<LibrarySnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || {
        app.state::<AppState>()
            .update_mod_metadata(&id, tags, notes)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn save_settings(app: AppHandle, settings: AppSettings) -> Result<AppSettings, String> {
    tauri::async_runtime::spawn_blocking(move || app.state::<AppState>().save_settings(settings))
        .await
        .map_err(error_text)?
        .map_err(error_text)
}

#[tauri::command]
pub async fn set_theme(app: AppHandle, theme: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || app.state::<AppState>().set_theme(&theme))
        .await
        .map_err(error_text)?
        .map_err(error_text)
}

#[tauri::command]
pub async fn detect_paths() -> Result<DetectPathsResult, String> {
    tauri::async_runtime::spawn_blocking(steam::detect_game_paths)
        .await
        .map_err(error_text)
}

#[tauri::command]
pub async fn launch_game(app: AppHandle, mode: String) -> Result<GameStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        launcher::launch(app.clone(), &state, &mode)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn kill_game(app: AppHandle) -> Result<GameStatus, String> {
    tauri::async_runtime::spawn_blocking(move || launcher::stop(&app.state::<AppState>()))
        .await
        .map_err(error_text)?
        .map_err(error_text)
}

#[tauri::command]
pub async fn import_mods(app: AppHandle, paths: Vec<String>) -> Result<ImportResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let result = crate::mods::import_paths(&state.paths, &paths)?;
        state.refresh_files()?;
        state.log(
            "info",
            "import",
            &format!(
                "导入完成：成功 {}，跳过 {}",
                result.imported, result.skipped
            ),
        );
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub fn open_path(path: String) -> Result<(), String> {
    if !std::path::Path::new(&path).exists() {
        return Err(format!("路径不存在：{path}"));
    }
    let mut command = Command::new("explorer.exe");
    command
        .arg(&path)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    command.spawn().map_err(error_text)?;
    Ok(())
}

#[tauri::command]
pub fn open_mod_folder(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let mods = state.mods.read().unwrap();
    let item = mods
        .iter()
        .find(|item| item.id == id)
        .ok_or_else(|| "找不到指定模组".to_string())?;
    let path = std::path::PathBuf::from(&item.file_path);
    if path.is_file() {
        let parent = path
            .parent()
            .ok_or_else(|| "模组文件没有父目录".to_string())?;
        open_path(path_string(parent))
    } else {
        open_path(path_string(&path))
    }
}

#[tauri::command]
pub fn get_logs(state: State<'_, AppState>) -> Vec<RuntimeLog> {
    state.logs()
}

#[tauri::command]
pub fn clear_logs(state: State<'_, AppState>) {
    state.clear_logs();
}

#[tauri::command]
pub fn get_app_info(state: State<'_, AppState>) -> AppInfo {
    state.app_info()
}

#[tauri::command]
pub async fn check_app_update(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<AppUpdateInfo, String> {
    let config = app_update::resolve_config(state.inner());
    app_update::check(&app, config).await
}

#[tauri::command]
pub async fn install_app_update(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<InstallUpdateResult, String> {
    let config = app_update::resolve_config(state.inner());
    app_update::install(&app, config).await
}

#[tauri::command]
pub async fn fetch_cloud_catalog(app: AppHandle) -> Result<Vec<RemoteMod>, String> {
    let (paths, mut settings, secrets) = {
        let state = app.state::<AppState>();
        let snapshot = (
            state.paths.clone(),
            state.settings.lock().unwrap().clone(),
            state.secrets.clone(),
        );
        snapshot
    };
    let result = cloud::fetch_catalog(
        &paths,
        &mut settings,
        &secrets,
        cloud::CloudAccess::current(),
    )
    .await
    .map_err(error_text);
    if result.is_ok() {
        let state = app.state::<AppState>();
        if let Err(error) = state.set_cloud_settings(&settings) {
            state.log("warn", "cloud", &format!("保存云源状态失败：{error:#}"));
        }
        state.log("info", "cloud", "云端目录刷新完成");
    } else if let Err(error) = &result {
        app.state::<AppState>()
            .log("error", "cloud", &format!("云端目录刷新失败：{error}"));
    }
    result
}

#[tauri::command]
pub async fn download_remote_mod(app: AppHandle, id: String) -> Result<DownloadResult, String> {
    let progress_app = app.clone();
    let progress_id = id.clone();
    let progress: cloud::CloudDownloadProgressCallback = Arc::new(move |payload| {
        let _ = progress_app.emit("cloud-download-progress", payload);
    });
    let _download = match begin_download(&id) {
        Ok(guard) => guard,
        Err(error) => {
            progress(CloudDownloadProgress {
                id: progress_id.clone(),
                phase: "error".to_string(),
                downloaded: 0,
                total: None,
                segments: 0,
                message: Some(error.clone()),
            });
            return Err(error);
        }
    };
    progress(CloudDownloadProgress {
        id: progress_id.clone(),
        phase: "queued".to_string(),
        downloaded: 0,
        total: None,
        segments: 0,
        message: None,
    });
    let (paths, mut settings, secrets) = {
        let state = app.state::<AppState>();
        let snapshot = (
            state.paths.clone(),
            state.settings.lock().unwrap().clone(),
            state.secrets.clone(),
        );
        snapshot
    };
    let message = match cloud::download_remote(
        &paths,
        &mut settings,
        &secrets,
        cloud::CloudAccess::current(),
        &id,
        progress.clone(),
    )
    .await
    {
        Ok(message) => message,
        Err(error) => {
            let message = error_text(error);
            progress(CloudDownloadProgress {
                id: progress_id.clone(),
                phase: "error".to_string(),
                downloaded: 0,
                total: None,
                segments: 0,
                message: Some(message.clone()),
            });
            app.state::<AppState>()
                .log("error", "cloud", &format!("云端下载失败：{message}"));
            return Err(message);
        }
    };
    let state = app.state::<AppState>();
    if let Err(error) = state.set_cloud_settings(&settings) {
        state.log("warn", "cloud", &format!("保存云源状态失败：{error:#}"));
    }
    if let Err(error) = state.refresh_files() {
        state.log(
            "warn",
            "cloud",
            &format!("下载完成，但刷新模组库失败：{}", error_text(error)),
        );
    }
    state.log("info", "cloud", &message);
    Ok(DownloadResult { message })
}

#[tauri::command]
pub async fn trust_sftp_host(
    app: AppHandle,
    account_id: String,
    fingerprint: String,
) -> Result<SftpConnectionResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::trust_host(&state.paths, &settings, &account_id, &fingerprint)?;
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn list_remote_files(app: AppHandle, path: String) -> Result<Vec<RemoteFile>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        sftp::list_files(&state.paths, &settings, &path)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn test_sftp_connection(
    app: AppHandle,
    account_id: String,
) -> Result<SftpConnectionResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::test_connection(&state.paths, &settings, &account_id)?;
        if let Some(path) = &result.detected_mods_path {
            let mut current = state.settings.lock().unwrap();
            if let Some(account) = current
                .sftp_accounts
                .iter_mut()
                .find(|account| account.id == account_id)
            {
                if account.mods_path.trim().is_empty() {
                    account.mods_path = path.clone();
                    crate::config::save_settings(&state.paths, &current)?;
                }
            }
        }
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn save_sftp_account(
    app: AppHandle,
    account: SftpAccountInput,
    password: String,
) -> Result<LibrarySnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || {
        app.state::<AppState>()
            .save_sftp_account(account, &password)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn upload_server_mods(
    app: AppHandle,
    account_id: String,
    paths: Vec<String>,
) -> Result<UploadResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::upload_files(&state.paths, &settings, &account_id, &paths)?;
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub fn window_minimize(window: WebviewWindow) -> Result<(), String> {
    window.minimize().map_err(error_text)
}

#[tauri::command]
pub fn window_toggle_maximize(window: WebviewWindow) -> Result<(), String> {
    if window.is_maximized().map_err(error_text)? {
        window.unmaximize().map_err(error_text)
    } else {
        window.maximize().map_err(error_text)
    }
}

#[tauri::command]
pub fn window_close(window: WebviewWindow, app: AppHandle) -> Result<(), String> {
    app.state::<AppState>().shutdown_cleanup();
    window.close().map_err(error_text)
}

#[cfg(test)]
mod tests {
    use super::begin_download;

    #[test]
    fn allows_parallel_mods_but_blocks_the_same_download_twice() {
        let first = begin_download("parallel-download-a").unwrap();
        let second = begin_download("parallel-download-b").unwrap();

        assert!(begin_download(" PARALLEL-DOWNLOAD-A ").is_err());

        drop(first);
        let retried = begin_download("parallel-download-a").unwrap();
        drop(retried);
        drop(second);
    }
}
