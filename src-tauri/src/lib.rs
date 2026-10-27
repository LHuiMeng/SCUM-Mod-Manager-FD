mod app_update;
mod cloud;
mod commands;
mod config;
mod edition;
mod launcher;
mod metadata;
mod models;
mod mods;
mod paths;
mod secrets;
mod sftp;
mod state;
mod steam;

#[cfg(test)]
mod test_support;

use state::AppState;
use tauri::Manager;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            let state = AppState::new(app.handle()).map_err(|error| {
                Box::new(std::io::Error::other(format!(
                    "初始化应用状态失败：{error:#}"
                ))) as Box<dyn std::error::Error>
            })?;
            app.manage(state);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_library_snapshot,
            commands::scan_library,
            commands::set_mod_enabled,
            commands::reorder_mods,
            commands::update_mod_metadata,
            commands::save_settings,
            commands::set_theme,
            commands::detect_paths,
            commands::launch_game,
            commands::kill_game,
            commands::import_mods,
            commands::open_path,
            commands::open_mod_folder,
            commands::get_logs,
            commands::clear_logs,
            commands::get_app_info,
            commands::check_app_update,
            commands::install_app_update,
            commands::fetch_cloud_catalog,
            commands::download_remote_mod,
            commands::list_remote_files,
            commands::test_sftp_connection,
            commands::trust_sftp_host,
            commands::save_sftp_account,
            commands::upload_server_mods,
            commands::window_minimize,
            commands::window_toggle_maximize,
            commands::window_close,
        ])
        .run(tauri::generate_context!())
        .expect("运行 SCUM Mod Desk 失败");
}
