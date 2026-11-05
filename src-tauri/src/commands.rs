use crate::app_update;
use crate::backups;
use crate::cloud;
use crate::crash;
use crate::launcher;
use crate::models::{
    AppInfo, AppSettings, AppUpdateInfo, CloudDownloadProgress, ConflictMergeResult,
    DetectPathsResult, DownloadResult, GameStatus, ImportConflict, ImportResult,
    InstallUpdateResult, LibrarySnapshot, LocaleBundle, RemoteFile, RemoteMod, RuntimeLog,
    SftpAccountInput, SftpApplyResult, SftpConflictReport, SftpConnectionResult,
    SftpOperationResult, SftpPrepareResult, UploadResult,
};
use crate::mods::links::PendingLink;
use crate::paths::path_string;
use crate::sftp;
use crate::state::AppState;
use crate::steam;
use std::collections::{BTreeMap, HashSet};
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
pub async fn save_conflict_winners(
    app: AppHandle,
    winners: BTreeMap<String, String>,
) -> Result<LibrarySnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || {
        app.state::<AppState>().save_conflict_winners(winners)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn prepare_conflict_merge(app: AppHandle) -> Result<ConflictMergeResult, String> {
    tauri::async_runtime::spawn_blocking(move || app.state::<AppState>().prepare_conflict_merge())
        .await
        .map_err(error_text)?
        .map_err(error_text)
}

#[tauri::command]
pub async fn delete_mod(app: AppHandle, id: String) -> Result<LibrarySnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || app.state::<AppState>().delete_mod(&id))
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
pub async fn set_language(app: AppHandle, language: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || app.state::<AppState>().set_language(&language))
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
pub async fn inspect_mod_import(
    app: AppHandle,
    paths: Vec<String>,
) -> Result<Vec<ImportConflict>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        crate::mods::inspect_import_conflicts(&state.paths, &paths)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn import_mods(
    app: AppHandle,
    paths: Vec<String>,
    replace_existing: Option<bool>,
) -> Result<ImportResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let result =
            crate::mods::import_paths(&state.paths, &paths, replace_existing.unwrap_or(false))?;
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
pub fn get_locale(state: State<'_, AppState>, language: String) -> Result<LocaleBundle, String> {
    crate::locales::load(&state.paths, &language).map_err(error_text)
}

#[tauri::command]
pub fn get_locales(state: State<'_, AppState>) -> Result<Vec<LocaleBundle>, String> {
    ["zh-CN", "en-US"]
        .into_iter()
        .map(|language| crate::locales::load(&state.paths, language).map_err(error_text))
        .collect()
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
pub async fn download_sftp_file(
    app: AppHandle,
    account_id: String,
    path: String,
    local_path: String,
) -> Result<SftpOperationResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::download_file(&state.paths, &settings, &account_id, &path, &local_path)?;
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
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
        let detected_pak = result.detected_mods_path.clone();
        let detected_ue4ss = result.detected_ue4ss_path.clone();
        let mut current = state.settings.lock().unwrap();
        if let Some(account) = current
            .sftp_accounts
            .iter_mut()
            .find(|account| account.id == account_id)
        {
            let mut changed = false;
            if let Some(path) = detected_pak {
                if account.mods_path != path {
                    account.mods_path = path;
                    changed = true;
                }
            }
            if let Some(path) = detected_ue4ss {
                if account.ue4ss_path != path {
                    account.ue4ss_path = path;
                    changed = true;
                }
            }
            if changed {
                crate::config::save_settings(&state.paths, &current)?;
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
    kind: String,
    paths: Vec<String>,
) -> Result<UploadResult, String> {
    let progress_app = app.clone();
    let progress: sftp::SftpUploadProgressCallback = std::sync::Arc::new(move |payload| {
        let _ = progress_app.emit("sftp-upload-progress", payload);
    });
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::upload_files(
            &state.paths,
            &settings,
            &account_id,
            &kind,
            &paths,
            progress,
        )?;
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn rename_sftp_entry(
    app: AppHandle,
    account_id: String,
    path: String,
    new_name: String,
) -> Result<SftpOperationResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::rename_entry(&state.paths, &settings, &account_id, &path, &new_name)?;
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn delete_sftp_entry(
    app: AppHandle,
    account_id: String,
    path: String,
) -> Result<SftpOperationResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::delete_entry(&state.paths, &settings, &account_id, &path)?;
        state.log("warn", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn sftp_mkdir(
    app: AppHandle,
    account_id: String,
    path: String,
) -> Result<SftpOperationResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::mkdir_entry(&state.paths, &settings, &account_id, &path)?;
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn move_sftp_entry(
    app: AppHandle,
    account_id: String,
    path: String,
    new_path: String,
) -> Result<SftpOperationResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::move_entry(&state.paths, &settings, &account_id, &path, &new_path)?;
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn download_sftp_mod_to_library(
    app: AppHandle,
    account_id: String,
    path: String,
) -> Result<LibrarySnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::download_mod_to_library(&state.paths, &settings, &account_id, &path)?;
        state.log("info", "sftp", &result.message);
        let snapshot = state.refresh_files()?;
        Ok::<_, anyhow::Error>(snapshot)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn get_sftp_remote_notes(
    app: AppHandle,
    account_id: String,
) -> Result<BTreeMap<String, String>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        sftp::read_remote_notes(&state.paths, &settings, &account_id)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn save_sftp_remote_note(
    app: AppHandle,
    account_id: String,
    path: String,
    note: String,
) -> Result<BTreeMap<String, String>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        sftp::save_remote_note(&state.paths, &settings, &account_id, &path, &note)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn analyze_sftp_conflicts(
    app: AppHandle,
    account_id: String,
) -> Result<SftpConflictReport, String> {
    let progress_app = app.clone();
    let progress: sftp::SftpConflictProgressCallback = Arc::new(move |payload| {
        let _ = progress_app.emit("sftp-conflict-progress", payload);
    });
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result =
            sftp::analyze_remote_conflicts(&state.paths, &settings, &account_id, progress)?;
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn prepare_sftp_mod_layout(
    app: AppHandle,
    account_id: String,
    order: Vec<String>,
    disabled: Vec<String>,
    deleted: Vec<String>,
    winners: BTreeMap<String, String>,
) -> Result<SftpPrepareResult, String> {
    let progress_app = app.clone();
    let progress: sftp::SftpConflictProgressCallback = Arc::new(move |payload| {
        let _ = progress_app.emit("sftp-conflict-progress", payload);
    });
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::prepare_remote_layout(
            &state.paths,
            &settings,
            &account_id,
            &order,
            &disabled,
            &deleted,
            &winners,
            progress,
        )?;
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn apply_sftp_mod_layout(
    app: AppHandle,
    account_id: String,
    order: Vec<String>,
    disabled: Vec<String>,
    deleted: Vec<String>,
    winners: BTreeMap<String, String>,
) -> Result<SftpApplyResult, String> {
    let progress_app = app.clone();
    let progress: sftp::SftpConflictProgressCallback = Arc::new(move |payload| {
        let _ = progress_app.emit("sftp-conflict-progress", payload);
    });
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::apply_remote_layout(
            &state.paths,
            &settings,
            &account_id,
            &order,
            &disabled,
            &deleted,
            &winners,
            progress,
        )?;
        state.log("info", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn restore_sftp_mod_layout(
    app: AppHandle,
    account_id: String,
) -> Result<SftpOperationResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        let result = sftp::restore_remote_layout(&state.paths, &settings, &account_id)?;
        state.log("warn", "sftp", &result.message);
        Ok::<_, anyhow::Error>(result)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub fn get_pending_links(state: State<'_, AppState>) -> Vec<PendingLink> {
    state.pending_links()
}

#[tauri::command]
pub async fn reclaim_pending_links(app: AppHandle) -> Result<usize, String> {
    // 回收要等被占用的文件释放（单文件最长 30s），不能放在 UI 线程上同步跑。
    let progress_app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        state
            .reclaim_pending_links_notified(|wait| {
                let file_name = std::path::Path::new(&wait.path)
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| wait.path.clone());
                let _ = progress_app.emit(
                    "reclaim-progress",
                    serde_json::json!({
                        "phase": if wait.waited_ms == 0 { "waiting" } else { "still-waiting" },
                        "file": file_name,
                        "waitedMs": wait.waited_ms,
                        "message": format!(
                            "正在回收 {file_name}，文件被占用，已等待 {} 秒",
                            wait.waited_ms / 1000
                        ),
                    }),
                );
            })
            .map_err(error_text)
    })
    .await
    .map_err(error_text)?
}

#[tauri::command]
pub fn dismiss_pending_links(state: State<'_, AppState>) {
    state.dismiss_pending_links();
}

#[tauri::command]
pub async fn list_backups(app: AppHandle) -> Result<Vec<backups::BackupEntry>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        backups::list_backups(&state.paths)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn restore_backup(app: AppHandle, id: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        let message =
            backups::restore_backup(&state.paths, &id, crate::launcher::is_running(&state))?;
        state.log("info", "backup", &message);
        Ok::<_, anyhow::Error>(message)
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub async fn delete_backup(app: AppHandle, id: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<AppState>();
        backups::remove_backup(&state.paths, &id)?;
        state.log("info", "backup", "已删除一个本地备份");
        Ok::<_, anyhow::Error>(())
    })
    .await
    .map_err(error_text)?
    .map_err(error_text)
}

#[tauri::command]
pub fn get_last_crash(state: State<'_, AppState>) -> Option<crash::CrashReport> {
    state.last_crash()
}

#[tauri::command]
pub fn dismiss_crash(state: State<'_, AppState>) {
    let _ = state.take_last_crash();
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
pub async fn window_close(window: WebviewWindow, app: AppHandle) -> Result<(), String> {
    let emit_app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        app.state::<AppState>().shutdown_cleanup_notified(|wait| {
            let file_name = std::path::Path::new(&wait.path)
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| wait.path.clone());
            let _ = emit_app.emit(
                "reclaim-progress",
                serde_json::json!({
                    "phase": if wait.waited_ms == 0 { "waiting" } else { "still-waiting" },
                    "file": file_name,
                    "waitedMs": wait.waited_ms,
                    "message": format!(
                        "正在回收 {file_name}，文件被占用，已等待 {} 秒",
                        wait.waited_ms / 1000
                    ),
                }),
            );
        });
    })
    .await
    .map_err(error_text)?;
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
