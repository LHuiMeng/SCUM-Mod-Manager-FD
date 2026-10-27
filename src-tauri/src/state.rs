use crate::config;
use crate::edition;
use crate::launcher::ManagedProcess;
use crate::metadata::{self, MetadataFile};
use crate::models::{
    AppInfo, AppSettings, GameStatus, LibrarySnapshot, ModEntry, RuntimeLog, SftpAccount,
    SftpAccountInput,
};
use crate::mods::deploy::{
    deployed_file_names, read_manifest, reclaim_mods, rescue_mods_from_game, sync_ue4ss_state,
};
use crate::mods::scan_local_mods;
use crate::paths::{path_string, AppPaths};
use crate::secrets::{load_runtime_secrets, RuntimeSecrets};
use anyhow::{Context, Result};
use chrono::Utc;
use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, RwLock};
use tauri::AppHandle;
use uuid::Uuid;

pub struct AppState {
    pub paths: AppPaths,
    pub settings: Mutex<AppSettings>,
    pub metadata: Mutex<MetadataFile>,
    pub mods: RwLock<Vec<ModEntry>>,
    pub game: Mutex<GameStatus>,
    pub process: Mutex<Option<ManagedProcess>>,
    pub next_launch_token: Mutex<u64>,
    pub last_deployed_at: Mutex<Option<String>>,
    pub last_scanned_at: Mutex<Option<String>>,
    pub logs: Mutex<VecDeque<RuntimeLog>>,
    log_sequence: Mutex<u64>,
    pub secrets: RuntimeSecrets,
}

impl AppState {
    pub fn new(app: &AppHandle) -> Result<Self> {
        Self::from_paths(AppPaths::init(app)?)
    }

    fn from_paths(paths: AppPaths) -> Result<Self> {
        let settings = config::load_settings(&paths).unwrap_or_else(|error| {
            eprintln!("读取配置失败，使用默认值：{error:#}");
            AppSettings::default()
        });
        let mut metadata = metadata::load_metadata(&paths).unwrap_or_else(|error| {
            eprintln!("读取模组元数据失败，使用默认值：{error:#}");
            MetadataFile::default()
        });
        let deployed = deployed_file_names(&paths);
        let mods = scan_local_mods(&paths, &mut metadata, &deployed).unwrap_or_default();
        let _ = metadata::save_metadata(&paths, &metadata);
        let deployed_at = read_manifest(&paths).map(|manifest| manifest.deployed_at);
        let secrets = load_runtime_secrets(&paths, edition::current());
        let state = Self {
            paths,
            settings: Mutex::new(settings),
            metadata: Mutex::new(metadata),
            mods: RwLock::new(mods),
            game: Mutex::new(GameStatus::default()),
            process: Mutex::new(None),
            next_launch_token: Mutex::new(0),
            last_deployed_at: Mutex::new(deployed_at),
            last_scanned_at: Mutex::new(Some(Utc::now().to_rfc3339())),
            logs: Mutex::new(VecDeque::new()),
            log_sequence: Mutex::new(0),
            secrets,
        };
        state.log("info", "app", "Rust 后端已初始化，本地模组扫描完成");
        Ok(state)
    }

    pub fn snapshot(&self) -> LibrarySnapshot {
        let settings = self.settings.lock().unwrap().clone();
        let client_mods_path = suggested_pak_dir(&settings.scum_install_path);
        LibrarySnapshot {
            mods: self.mods.read().unwrap().clone(),
            settings,
            game_status: self.game.lock().unwrap().clone(),
            last_deployed_at: self.last_deployed_at.lock().unwrap().clone(),
            last_scanned_at: self.last_scanned_at.lock().unwrap().clone(),
            local_mods_path: path_string(&self.paths.local_mods),
            client_mods_path,
        }
    }

    pub fn scan(&self, rescue: bool) -> Result<LibrarySnapshot> {
        let settings = self.settings.lock().unwrap().clone();
        if !self.process_running() {
            if rescue {
                let rescued = rescue_mods_from_game(&self.paths, &settings)?;
                if rescued > 0 {
                    self.log(
                        "info",
                        "library",
                        &format!("从游戏目录抢救 {rescued} 个 PAK 到本地模组库"),
                    );
                }
            }
            let reclaimed = reclaim_mods(&self.paths)?;
            if reclaimed > 0 {
                self.log(
                    "info",
                    "library",
                    &format!("回收 {reclaimed} 个上次部署的文件"),
                );
            }
        }

        let mut metadata = self.metadata.lock().unwrap();
        let deployed = deployed_file_names(&self.paths);
        let mods = scan_local_mods(&self.paths, &mut metadata, &deployed)?;
        metadata::save_metadata(&self.paths, &metadata)?;
        let count = mods.len();
        *self.mods.write().unwrap() = mods;
        *self.last_scanned_at.lock().unwrap() = Some(Utc::now().to_rfc3339());
        drop(metadata);
        self.log(
            "info",
            "library",
            &format!("扫描完成，共发现 {count} 个本地模组"),
        );
        Ok(self.snapshot())
    }

    pub fn refresh_files(&self) -> Result<LibrarySnapshot> {
        let mut metadata = self.metadata.lock().unwrap();
        let deployed = deployed_file_names(&self.paths);
        let mods = scan_local_mods(&self.paths, &mut metadata, &deployed)?;
        metadata::save_metadata(&self.paths, &metadata)?;
        *self.mods.write().unwrap() = mods;
        *self.last_scanned_at.lock().unwrap() = Some(Utc::now().to_rfc3339());
        Ok(self.snapshot())
    }

    pub fn set_mod_enabled(&self, id: &str, enabled: bool) -> Result<LibrarySnapshot> {
        if self.process_running() {
            anyhow::bail!("游戏运行期间不能更改模组启用状态");
        }
        let mut mods = self.mods.write().unwrap();
        let item = mods
            .iter_mut()
            .find(|item| item.id == id)
            .context("找不到指定模组")?;
        item.enabled = enabled;
        let mods_snapshot = mods.clone();
        drop(mods);
        let mut metadata = self.metadata.lock().unwrap();
        metadata.entry_mut(id).enabled = enabled;
        metadata::save_metadata(&self.paths, &metadata)?;
        drop(metadata);
        if let Err(error) = sync_ue4ss_state(&self.paths, &mods_snapshot) {
            self.log("warn", "ue4ss", &format!("同步 mods.txt 失败：{error:#}"));
        }
        Ok(self.snapshot())
    }

    pub fn reorder_mods(&self, ids: &[String]) -> Result<LibrarySnapshot> {
        let mut ordered = Vec::new();
        let mut mods = self.mods.write().unwrap();
        let mut by_id: HashMap<String, ModEntry> =
            mods.drain(..).map(|item| (item.id.clone(), item)).collect();
        for id in ids {
            if let Some(item) = by_id.remove(id) {
                ordered.push(item);
            }
        }
        let mut remaining: Vec<ModEntry> = by_id.into_values().collect();
        remaining.sort_by_key(|item| item.load_order);
        ordered.extend(remaining);
        for (index, item) in ordered.iter_mut().enumerate() {
            item.load_order = index;
        }
        let order = ordered
            .iter()
            .map(|item| item.id.clone())
            .collect::<Vec<_>>();
        *mods = ordered;
        drop(mods);
        let mut metadata = self.metadata.lock().unwrap();
        metadata.order = order;
        metadata::save_metadata(&self.paths, &metadata)?;
        Ok(self.snapshot())
    }

    pub fn update_mod_metadata(
        &self,
        id: &str,
        tags: Vec<String>,
        notes: String,
    ) -> Result<LibrarySnapshot> {
        let mut mods = self.mods.write().unwrap();
        let item = mods
            .iter_mut()
            .find(|item| item.id == id)
            .context("找不到指定模组")?;
        item.tags = tags.clone();
        item.notes = notes.clone();
        drop(mods);
        let mut metadata = self.metadata.lock().unwrap();
        let entry = metadata.entry_mut(id);
        entry.tags = tags;
        entry.notes = notes;
        metadata::save_metadata(&self.paths, &metadata)?;
        Ok(self.snapshot())
    }

    pub fn save_settings(&self, settings: AppSettings) -> Result<AppSettings> {
        config::save_settings(&self.paths, &settings)?;
        let saved = config::load_settings(&self.paths)?;
        *self.settings.lock().unwrap() = saved.clone();
        Ok(saved)
    }

    pub fn set_theme(&self, theme: &str) -> Result<()> {
        if theme != "light" && theme != "dark" {
            anyhow::bail!("无效主题");
        }
        let mut settings = self.settings.lock().unwrap();
        settings.theme = theme.to_string();
        config::save_settings(&self.paths, &settings)
    }

    pub fn save_sftp_account(
        &self,
        input: SftpAccountInput,
        password: &str,
    ) -> Result<LibrarySnapshot> {
        if input.host.trim().is_empty() || input.username.trim().is_empty() {
            anyhow::bail!("服务器地址和用户名不能为空");
        }
        let mut settings = self.settings.lock().unwrap();
        let existing_index = settings
            .sftp_accounts
            .iter()
            .position(|item| item.name.eq_ignore_ascii_case(input.name.trim()))
            .or_else(|| {
                settings.sftp_accounts.iter().position(|item| {
                    item.host.eq_ignore_ascii_case(input.host.trim())
                        && item.username == input.username.trim()
                })
            });
        let id = existing_index
            .map(|index| settings.sftp_accounts[index].id.clone())
            .filter(|id| !id.is_empty())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let has_password = !password.is_empty() || self.paths.sftp_secret(&id).exists();
        if !password.is_empty() {
            crate::secrets::write_secret(&self.paths.sftp_secret(&id), password)?;
        }
        let account = SftpAccount {
            id: id.clone(),
            name: input.name.trim().to_string(),
            host: input.host.trim().to_string(),
            port: input.port.max(1),
            username: input.username.trim().to_string(),
            mods_path: input.mods_path.trim().to_string(),
            has_password,
        };
        if let Some(index) = existing_index {
            settings.sftp_accounts[index] = account;
        } else {
            settings.sftp_accounts.push(account);
        }
        settings.active_sftp_account_id = Some(id);
        config::save_settings(&self.paths, &settings)?;
        drop(settings);
        self.log("info", "sftp", "SFTP 账户配置已保存，密码由 DPAPI 加密");
        Ok(self.snapshot())
    }

    pub fn set_cloud_settings(&self, settings: &AppSettings) -> Result<()> {
        let mut current = self.settings.lock().unwrap();
        current.cloud = settings.cloud.clone();
        config::save_settings(&self.paths, &current)
    }

    pub fn app_info(&self) -> AppInfo {
        AppInfo {
            version: env!("CARGO_PKG_VERSION").to_string(),
            data_root: path_string(&self.paths.root),
            secrets_path: path_string(&self.paths.secrets),
            platform: std::env::consts::OS.to_string(),
            edition: edition::label(edition::current()).to_string(),
        }
    }

    pub fn log(&self, level: &str, target: &str, message: &str) {
        let id = {
            let mut sequence = self.log_sequence.lock().unwrap();
            *sequence += 1;
            *sequence
        };
        let entry = RuntimeLog {
            id,
            timestamp: Utc::now().to_rfc3339(),
            level: level.to_string(),
            target: target.to_string(),
            message: message.to_string(),
        };
        {
            let mut logs = self.logs.lock().unwrap();
            logs.push_back(entry.clone());
            while logs.len() > 1000 {
                logs.pop_front();
            }
        }
        let path = self.paths.logs_dir.join("runtime.jsonl");
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let _ = writeln!(
                file,
                "{}",
                serde_json::to_string(&entry).unwrap_or_default()
            );
        }
    }

    pub fn logs(&self) -> Vec<RuntimeLog> {
        self.logs.lock().unwrap().iter().cloned().collect()
    }

    pub fn clear_logs(&self) {
        self.logs.lock().unwrap().clear();
        let _ = std::fs::write(self.paths.logs_dir.join("runtime.jsonl"), "");
    }

    pub fn process_running(&self) -> bool {
        let mut guard = self.process.lock().unwrap();
        match guard.as_mut() {
            Some(process) => matches!(process.child.try_wait(), Ok(None)),
            None => false,
        }
    }

    pub fn shutdown_cleanup(&self) {
        if self.process.lock().unwrap().is_some() {
            let _ = crate::launcher::stop(self);
        } else {
            let _ = reclaim_mods(&self.paths);
        }
    }
}

fn suggested_pak_dir(install: &str) -> String {
    if install.trim().is_empty() {
        return String::new();
    }
    let root = PathBuf::from(install.trim());
    crate::mods::deploy::find_pak_dir(&root)
        .unwrap_or_else(|| root.join("SCUM").join("Content").join("Paks").join("~mod"))
        .to_string_lossy()
        .into_owned()
}

#[cfg(test)]
mod tests {
    use super::AppState;
    use crate::test_support::TempRoot;
    use std::fs;

    #[test]
    fn persists_mod_order_tags_notes_and_enabled_state() {
        let temp = TempRoot::new("state-persistence");
        let paths = temp.paths();
        fs::write(paths.local_mods.join("Alpha.pak"), b"alpha").unwrap();
        fs::write(paths.local_mods.join("Beta.pak"), b"beta").unwrap();
        let state = AppState::from_paths(paths.clone()).unwrap();
        let initial = state.scan(false).unwrap();
        assert_eq!(
            initial
                .mods
                .iter()
                .map(|item| item.file_name.as_str())
                .collect::<Vec<_>>(),
            vec!["Alpha.pak", "Beta.pak"]
        );
        let alpha = initial
            .mods
            .iter()
            .find(|item| item.file_name == "Alpha.pak")
            .unwrap()
            .id
            .clone();
        let beta = initial
            .mods
            .iter()
            .find(|item| item.file_name == "Beta.pak")
            .unwrap()
            .id
            .clone();

        state.reorder_mods(&[beta.clone(), alpha.clone()]).unwrap();
        state
            .update_mod_metadata(
                &beta,
                vec!["server".to_string(), "balance".to_string()],
                "保留这条备注".to_string(),
            )
            .unwrap();
        state.set_mod_enabled(&beta, false).unwrap();

        let reloaded = AppState::from_paths(paths).unwrap();
        assert_eq!(
            reloaded
                .mods
                .read()
                .unwrap()
                .iter()
                .map(|item| item.file_name.as_str())
                .collect::<Vec<_>>(),
            vec!["Beta.pak", "Alpha.pak"]
        );
        let beta = reloaded
            .mods
            .read()
            .unwrap()
            .iter()
            .find(|item| item.id == beta)
            .unwrap()
            .clone();
        assert!(!beta.enabled);
        assert_eq!(beta.tags, vec!["server", "balance"]);
        assert_eq!(beta.notes, "保留这条备注");
        assert!(
            reloaded
                .mods
                .read()
                .unwrap()
                .iter()
                .find(|item| item.id == alpha)
                .unwrap()
                .enabled
        );
    }
}
