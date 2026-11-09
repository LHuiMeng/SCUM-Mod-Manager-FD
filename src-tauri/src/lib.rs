mod app_update;
mod backups;
mod cloud;
mod commands;
mod config;
mod crash;
mod edition;
mod launcher;
mod library_watch;
mod locales;
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
            library_watch::spawn(app.handle().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_library_snapshot,
            commands::scan_library,
            commands::set_mod_enabled,
            commands::set_mods_enabled,
            commands::rename_mod,
            commands::reorder_mods,
            commands::update_mod_metadata,
            commands::save_conflict_winners,
            commands::prepare_conflict_merge,
            commands::delete_mod,
            commands::save_settings,
            commands::set_theme,
            commands::set_language,
            commands::detect_paths,
            commands::launch_game,
            commands::kill_game,
            commands::inspect_mod_import,
            commands::import_mods,
            commands::open_path,
            commands::open_mod_folder,
            commands::list_mod_config_files,
            commands::read_mod_config_file,
            commands::write_mod_config_file,
            commands::get_logs,
            commands::clear_logs,
            commands::get_app_info,
            commands::get_locale,
            commands::get_locales,
            commands::check_app_update,
            commands::install_app_update,
            commands::fetch_cloud_catalog,
            commands::download_remote_mod,
            commands::list_remote_files,
            commands::download_sftp_file,
            commands::test_sftp_connection,
            commands::sftp_directory_usage,
            commands::trust_sftp_host,
            commands::save_sftp_account,
            commands::upload_server_mods,
            commands::rename_sftp_entry,
            commands::delete_sftp_entry,
            commands::sftp_mkdir,
            commands::move_sftp_entry,
            commands::download_sftp_mod_to_library,
            commands::get_sftp_remote_notes,
            commands::save_sftp_remote_note,
            commands::list_remote_config_files,
            commands::read_remote_config_file,
            commands::write_remote_config_file,
            commands::analyze_sftp_conflicts,
            commands::prepare_sftp_mod_layout,
            commands::apply_sftp_mod_layout,
            commands::restore_sftp_mod_layout,
            commands::get_pending_links,
            commands::reclaim_pending_links,
            commands::dismiss_pending_links,
            commands::list_backups,
            commands::restore_backup,
            commands::delete_backup,
            commands::get_last_crash,
            commands::dismiss_crash,
            commands::window_minimize,
            commands::window_toggle_maximize,
            commands::window_close,
        ])
        .run(tauri::generate_context!())
        .expect("运行 SCUM Mod Desk 失败");
}
