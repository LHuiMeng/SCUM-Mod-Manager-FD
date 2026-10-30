use crate::cloud;
use crate::config;
use crate::edition;
use crate::launcher::ManagedProcess;
use crate::metadata::{self, MetadataFile};
use crate::models::{
    AppInfo, AppSettings, ConflictGroup, GameStatus, LibrarySnapshot, ModEntry, RuntimeLog,
    SftpAccount, SftpAccountInput,
};
use crate::mods::deploy::{
    deployed_file_names, read_manifest, reclaim_mods, rescue_mods_from_game, sync_ue4ss_state,
};
use crate::mods::{refresh_conflicts, scan_local_mods_with_diagnostics};
use crate::paths::{is_within, path_string, safe_disk_name, AppPaths};
use crate::secrets::{load_runtime_secrets, RuntimeSecrets};
use anyhow::{Context, Result};
use chrono::Utc;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, RwLock};
use tauri::AppHandle;
use uuid::Uuid;

pub struct AppState {
    pub paths: AppPaths,
    pub settings: Mutex<AppSettings>,
    pub metadata: Mutex<MetadataFile>,
    pub mods: RwLock<Vec<ModEntry>>,
    pub conflicts: RwLock<Vec<ConflictGroup>>,
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
        let secrets = load_runtime_secrets(&paths, edition::current());
        let settings = config::load_settings_with_cloud_defaults(&paths, &secrets.cloud_base_urls)
            .unwrap_or_else(|error| {
                eprintln!("读取配置失败，使用默认值：{error:#}");
                let mut settings = AppSettings::default();
                config::apply_default_cloud_sources(&mut settings, &secrets.cloud_base_urls);
                settings
            });
        if !settings.keep_deployed_mods_on_exit {
            let _ = reclaim_mods(&paths);
        }
        let mut metadata = metadata::load_metadata(&paths).unwrap_or_else(|error| {
            eprintln!("读取模组元数据失败，使用默认值：{error:#}");
            MetadataFile::default()
        });
        let deployed = deployed_file_names(&paths);
        let scan =
            scan_local_mods_with_diagnostics(&paths, &mut metadata, &deployed).unwrap_or_default();
        let mut mods = scan.mods;
        let _ = cloud::apply_catalog_names(&paths, &mut metadata, &mut mods);
        let conflicts = refresh_conflicts(&mut metadata, &mut mods);
        let _ = metadata::save_metadata(&paths, &metadata);
        let deployed_at = read_manifest(&paths).map(|manifest| manifest.deployed_at);
        let state = Self {
            paths,
            settings: Mutex::new(settings),
            metadata: Mutex::new(metadata),
            mods: RwLock::new(mods),
            conflicts: RwLock::new(conflicts),
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
        log_pak_diagnostics(&state, &scan.diagnostics);
        Ok(state)
    }

    pub fn snapshot(&self) -> LibrarySnapshot {
        let settings = self.settings.lock().unwrap().clone();
        let client_mods_path = suggested_pak_dir(&settings.scum_install_path);
        LibrarySnapshot {
            mods: self.mods.read().unwrap().clone(),
            conflicts: self.conflicts.read().unwrap().clone(),
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
                if rescued.rescued > 0 || rescued.skipped > 0 {
                    self.log(
                        "info",
                        "library",
                        &format!(
                            "从游戏目录抢救 {} 个 PAK 到本地模组库，跳过 {} 个同名文件",
                            rescued.rescued, rescued.skipped
                        ),
                    );
                }
            }
            if let Some(reclaimed) = self.reclaim_deployments_after_exit()? {
                if reclaimed > 0 {
                    self.log(
                        "info",
                        "library",
                        &format!("回收 {reclaimed} 个上次部署的文件"),
                    );
                }
            }
        }

        let mut metadata = self.metadata.lock().unwrap();
        let deployed = deployed_file_names(&self.paths);
        let scan = scan_local_mods_with_diagnostics(&self.paths, &mut metadata, &deployed)?;
        let mut mods = scan.mods;
        let named = cloud::apply_catalog_names(&self.paths, &mut metadata, &mut mods);
        let conflicts = refresh_conflicts(&mut metadata, &mut mods);
        metadata::save_metadata(&self.paths, &metadata)?;
        let count = mods.len();
        *self.mods.write().unwrap() = mods;
        *self.conflicts.write().unwrap() = conflicts;
        *self.last_scanned_at.lock().unwrap() = Some(Utc::now().to_rfc3339());
        drop(metadata);
        log_pak_diagnostics(self, &scan.diagnostics);
        if named > 0 {
            self.log(
                "info",
                "cloud",
                &format!("已按云端目录回填 {named} 个模组的显示名"),
            );
        }
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
        let scan = scan_local_mods_with_diagnostics(&self.paths, &mut metadata, &deployed)?;
        let mut mods = scan.mods;
        let named = cloud::apply_catalog_names(&self.paths, &mut metadata, &mut mods);
        let conflicts = refresh_conflicts(&mut metadata, &mut mods);
        metadata::save_metadata(&self.paths, &metadata)?;
        *self.mods.write().unwrap() = mods;
        *self.conflicts.write().unwrap() = conflicts;
        *self.last_scanned_at.lock().unwrap() = Some(Utc::now().to_rfc3339());
        log_pak_diagnostics(self, &scan.diagnostics);
        if named > 0 {
            self.log(
                "info",
                "cloud",
                &format!("已按云端目录回填 {named} 个模组的显示名"),
            );
        }
        Ok(self.snapshot())
    }

    pub fn set_mod_enabled(&self, id: &str, enabled: bool) -> Result<LibrarySnapshot> {
        if self.process_running() {
            anyhow::bail!("游戏运行期间不能更改模组启用状态");
        }
        let mut mods_snapshot = {
            let mut mods = self.mods.write().unwrap();
            let item = mods
                .iter_mut()
                .find(|item| item.id == id)
                .context("找不到指定模组")?;
            item.enabled = enabled;
            mods.clone()
        };
        let mut metadata = self.metadata.lock().unwrap();
        metadata.entry_mut(id).enabled = enabled;
        let conflicts = refresh_conflicts(&mut metadata, &mut mods_snapshot);
        metadata::save_metadata(&self.paths, &metadata)?;
        drop(metadata);
        *self.mods.write().unwrap() = mods_snapshot.clone();
        *self.conflicts.write().unwrap() = conflicts;
        if let Err(error) = sync_ue4ss_state(&self.paths, &mods_snapshot) {
            self.log("warn", "ue4ss", &format!("同步 mods.txt 失败：{error:#}"));
        }
        Ok(self.snapshot())
    }

    pub fn reorder_mods(&self, ids: &[String]) -> Result<LibrarySnapshot> {
        let mut ordered = {
            let mut mods = self.mods.write().unwrap();
            let mut by_id: HashMap<String, ModEntry> =
                mods.drain(..).map(|item| (item.id.clone(), item)).collect();
            let mut ordered = Vec::new();
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
            ordered
        };
        let order = ordered
            .iter()
            .map(|item| item.id.clone())
            .collect::<Vec<_>>();
        let mut metadata = self.metadata.lock().unwrap();
        let conflicts = refresh_conflicts(&mut metadata, &mut ordered);
        metadata.order = order;
        metadata::save_metadata(&self.paths, &metadata)?;
        drop(metadata);
        *self.mods.write().unwrap() = ordered;
        *self.conflicts.write().unwrap() = conflicts;
        Ok(self.snapshot())
    }

    pub fn save_conflict_winners(
        &self,
        winners: BTreeMap<String, String>,
    ) -> Result<LibrarySnapshot> {
        let mut mods = self.mods.read().unwrap().clone();
        let mut metadata = self.metadata.lock().unwrap();
        let analysis = crate::mods::analyze_conflicts(&metadata, &mods);
        crate::mods::validate_conflict_winners(&analysis.groups, &winners)?;
        let previous_metadata = metadata.clone();
        metadata.conflict_winners = winners;
        let conflicts = refresh_conflicts(&mut metadata, &mut mods);
        if let Err(error) = metadata::save_metadata(&self.paths, &metadata) {
            *metadata = previous_metadata;
            return Err(error);
        }
        drop(metadata);
        *self.mods.write().unwrap() = mods;
        *self.conflicts.write().unwrap() = conflicts;
        self.log("info", "conflict", "冲突覆盖选择已保存");
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

    pub fn delete_mod(&self, id: &str) -> Result<LibrarySnapshot> {
        ensure_deletion_allowed(self.process_running())?;

        let item = self
            .mods
            .read()
            .unwrap()
            .iter()
            .find(|item| item.id == id)
            .cloned()
            .context("找不到指定模组")?;
        let mut sources = Vec::new();
        let source = PathBuf::from(&item.file_path);
        sources.push(source.clone());
        for alias in &item.duplicate_aliases {
            let alias = PathBuf::from(alias);
            if alias.exists() {
                sources.push(alias);
            }
        }
        let mut seen = std::collections::HashSet::new();
        sources.retain(|path| {
            seen.insert(
                std::path::absolute(path)
                    .unwrap_or_else(|_| path.clone())
                    .to_string_lossy()
                    .to_ascii_lowercase(),
            )
        });

        for path in &sources {
            let is_pak = is_direct_child(path, &self.paths.local_mods) && path.is_file();
            let is_ue4ss = is_direct_child(path, &self.paths.ue4ss_mods) && path.is_dir();
            if !is_pak && !is_ue4ss {
                anyhow::bail!("拒绝删除模组库之外的路径或不受支持的文件");
            }
        }

        let deleted_dir = self.paths.backups_dir.join("deleted");
        std::fs::create_dir_all(&deleted_dir)
            .with_context(|| format!("无法创建删除备份目录 {}", deleted_dir.display()))?;
        let timestamp = Utc::now().format("%Y%m%d-%H%M%S-%3f");
        let file_name = source
            .file_name()
            .context("模组路径缺少文件名")?
            .to_string_lossy();
        let mut moved: Vec<(PathBuf, PathBuf)> = Vec::new();
        for (index, path) in sources.iter().enumerate() {
            let name = path
                .file_name()
                .context("模组路径缺少文件名")?
                .to_string_lossy();
            let backup = deleted_dir.join(format!(
                "{timestamp}-{index}-{}",
                safe_disk_name(&name, &safe_disk_name(&file_name, "mod"))
            ));
            if let Err(error) = move_entry(path, &backup) {
                for (original, moved_to) in moved.iter().rev() {
                    let _ = move_entry(moved_to, original);
                }
                return Err(error);
            }
            moved.push((path.clone(), backup));
        }

        let metadata_result = (|| -> Result<()> {
            let mut metadata = self.metadata.lock().unwrap();
            let previous = metadata.clone();
            metadata.entries.remove(id);
            metadata.order.retain(|entry| entry != id);
            if let Err(error) = metadata::save_metadata(&self.paths, &metadata) {
                *metadata = previous;
                return Err(error);
            }
            Ok(())
        })();
        if let Err(error) = metadata_result {
            let mut rollback_errors = Vec::new();
            for (original, moved_to) in moved.iter().rev() {
                if let Err(rollback_error) = move_entry(moved_to, original) {
                    rollback_errors.push(rollback_error.to_string());
                }
            }
            return Err(if rollback_errors.is_empty() {
                error.context("删除模组元数据失败，已恢复原文件")
            } else {
                error.context(format!(
                    "删除模组元数据失败，且部分文件无法恢复：{}",
                    rollback_errors.join("；")
                ))
            });
        }

        self.log(
            "info",
            "library",
            &format!(
                "已将模组 {} 的 {} 个文件移入 backups/deleted",
                item.name,
                moved.len()
            ),
        );
        match self.refresh_files() {
            Ok(snapshot) => Ok(snapshot),
            Err(error) => {
                self.log(
                    "warn",
                    "library",
                    &format!("模组已移入备份，但刷新列表失败：{error:#}"),
                );
                Ok(self.snapshot())
            }
        }
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

    pub fn set_language(&self, language: &str) -> Result<()> {
        if language != "zh-CN" && language != "en-US" {
            anyhow::bail!("无效语言");
        }
        let mut settings = self.settings.lock().unwrap();
        settings.language = language.to_string();
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
            ue4ss_path: input.ue4ss_path.trim().to_string(),
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

    pub fn reclaim_deployments_after_exit(&self) -> Result<Option<usize>> {
        if self.settings.lock().unwrap().keep_deployed_mods_on_exit {
            return Ok(None);
        }
        let reclaimed = reclaim_mods(&self.paths)?;
        *self.last_deployed_at.lock().unwrap() = None;
        Ok(Some(reclaimed))
    }

    pub fn shutdown_cleanup(&self) {
        if self.process.lock().unwrap().is_some() {
            let _ = crate::launcher::stop(self);
        } else {
            let _ = self.reclaim_deployments_after_exit();
        }
    }
}

fn log_pak_diagnostics(state: &AppState, diagnostics: &[crate::mods::PakScanDiagnostic]) {
    for diagnostic in diagnostics {
        state.log(
            "warn",
            "pak",
            &format!(
                "PAK 清单扫描失败：{}（{}），已保留旧缓存或使用空清单：{}",
                diagnostic.file_name, diagnostic.mod_id, diagnostic.message
            ),
        );
    }
}

fn suggested_pak_dir(install: &str) -> String {
    if install.trim().is_empty() {
        return String::new();
    }
    let root = PathBuf::from(install.trim());
    crate::mods::deploy::find_pak_dir(&root)
        .unwrap_or_else(|| root.join("SCUM").join("Content").join("Paks").join("~mods"))
        .to_string_lossy()
        .into_owned()
}

fn is_direct_child(path: &Path, root: &Path) -> bool {
    is_within(path, root)
        && path.parent().is_some_and(|parent| is_within(parent, root))
        && path
            .parent()
            .is_some_and(|parent| normalize_path(parent) == normalize_path(root))
}

fn normalize_path(path: &Path) -> PathBuf {
    std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf())
}

fn move_entry(source: &Path, destination: &Path) -> Result<()> {
    std::fs::rename(source, destination).with_context(|| {
        format!(
            "无法将 {} 移动到 {}",
            source.display(),
            destination.display()
        )
    })
}

fn ensure_deletion_allowed(running: bool) -> Result<()> {
    if running {
        anyhow::bail!("游戏运行期间不能删除模组");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{ensure_deletion_allowed, is_direct_child, AppState};
    use crate::models::ModEntry;
    use crate::paths::{path_string, AppPaths};
    use crate::test_support::TempRoot;
    use std::collections::BTreeMap;
    use std::fs;
    use std::path::PathBuf;

    fn write_retained_deployment(paths: &AppPaths) -> (PathBuf, PathBuf) {
        let install = paths.root.join("fake-scum");
        let deployed = install
            .join("SCUM")
            .join("Content")
            .join("Paks")
            .join("~mods")
            .join("000_Alpha.pak");
        fs::create_dir_all(deployed.parent().unwrap()).unwrap();
        fs::write(&deployed, b"deployed").unwrap();
        let manifest = serde_json::json!({
            "deployedAt": "2026-10-29T00:00:00Z",
            "roots": [path_string(&install)],
            "files": [path_string(&deployed)],
            "directories": [path_string(deployed.parent().unwrap())],
            "backups": []
        });
        fs::write(
            &paths.deployment_manifest,
            serde_json::to_vec_pretty(&manifest).unwrap(),
        )
        .unwrap();
        (deployed, paths.deployment_manifest.clone())
    }

    fn write_retention_config(paths: &AppPaths, keep: bool) {
        fs::write(
            &paths.config_file,
            serde_json::to_vec_pretty(&serde_json::json!({
                "keepDeployedModsOnExit": keep
            }))
            .unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn startup_scan_preserves_retained_deployment_when_setting_is_enabled() {
        let temp = TempRoot::new("state-retained-startup");
        let paths = temp.paths();
        write_retention_config(&paths, true);
        let (deployed, manifest) = write_retained_deployment(&paths);
        let manifest_before = fs::read(&manifest).unwrap();

        let state = AppState::from_paths(paths.clone()).unwrap();
        state.scan(false).unwrap();

        assert!(deployed.exists());
        assert!(manifest.exists());
        assert_eq!(fs::read(&manifest).unwrap(), manifest_before);
    }

    #[test]
    fn startup_reclaims_existing_deployment_when_setting_is_disabled() {
        let temp = TempRoot::new("state-cleanup-startup");
        let paths = temp.paths();
        write_retention_config(&paths, false);
        let (deployed, manifest) = write_retained_deployment(&paths);

        let _state = AppState::from_paths(paths.clone()).unwrap();

        assert!(!deployed.exists());
        assert!(!manifest.exists());
    }

    #[test]
    fn scan_reclaims_existing_deployment_when_setting_is_disabled() {
        let temp = TempRoot::new("state-cleanup-disabled");
        let paths = temp.paths();
        write_retention_config(&paths, false);
        let (deployed, manifest) = write_retained_deployment(&paths);

        let state = AppState::from_paths(paths.clone()).unwrap();
        state.scan(false).unwrap();

        assert!(!deployed.exists());
        assert!(!manifest.exists());
    }

    #[test]
    fn shutdown_preserves_deployment_when_setting_is_enabled() {
        let temp = TempRoot::new("state-retained-shutdown");
        let paths = temp.paths();
        write_retention_config(&paths, true);
        let (deployed, manifest) = write_retained_deployment(&paths);
        let manifest_before = fs::read(&manifest).unwrap();
        let state = AppState::from_paths(paths.clone()).unwrap();

        state.shutdown_cleanup();

        assert!(deployed.exists());
        assert!(manifest.exists());
        assert_eq!(fs::read(&manifest).unwrap(), manifest_before);
    }

    #[test]
    fn manual_stop_preserves_deployment_when_setting_is_enabled() {
        let temp = TempRoot::new("state-retained-stop");
        let paths = temp.paths();
        write_retention_config(&paths, true);
        let (deployed, manifest) = write_retained_deployment(&paths);
        let manifest_before = fs::read(&manifest).unwrap();
        let state = AppState::from_paths(paths.clone()).unwrap();

        crate::launcher::stop(&state).unwrap();

        assert!(deployed.exists());
        assert!(manifest.exists());
        assert_eq!(fs::read(&manifest).unwrap(), manifest_before);
    }

    #[test]
    fn manual_stop_reclaims_deployment_when_setting_is_disabled() {
        let temp = TempRoot::new("state-cleanup-stop");
        let paths = temp.paths();
        write_retention_config(&paths, false);
        let (deployed, manifest) = write_retained_deployment(&paths);
        let state = AppState::from_paths(paths.clone()).unwrap();

        crate::launcher::stop(&state).unwrap();

        assert!(!deployed.exists());
        assert!(!manifest.exists());
    }

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

    #[test]
    fn applies_runtime_cloud_sources_on_startup_and_persists_them() {
        let temp = TempRoot::new("state-default-cloud");
        let paths = temp.paths();
        fs::write(
            paths.secrets.join("runtime.toml"),
            concat!(
                "[cloud]\n",
                "base_urls = [\"https://primary.example.test\", \"https://backup.example.test\"]\n"
            ),
        )
        .unwrap();

        let state = AppState::from_paths(paths.clone()).unwrap();

        let settings = state.settings.lock().unwrap();
        assert_eq!(
            settings.cloud.base_urls,
            vec![
                "https://primary.example.test",
                "https://backup.example.test"
            ]
        );
        assert_eq!(
            settings.cloud.active_base_url,
            "https://primary.example.test"
        );
        let saved = fs::read_to_string(&paths.config_file).unwrap();
        assert!(saved.contains("https://primary.example.test"));
    }

    #[test]
    fn moves_deleted_mod_to_backup_and_clears_metadata() {
        let temp = TempRoot::new("state-delete-backup");
        let paths = temp.paths();
        fs::write(paths.local_mods.join("Alpha.pak"), b"alpha").unwrap();
        fs::write(paths.local_mods.join("Beta.pak"), b"beta").unwrap();
        let state = AppState::from_paths(paths.clone()).unwrap();
        let initial = state.scan(false).unwrap();
        let alpha = initial
            .mods
            .iter()
            .find(|item| item.file_name == "Alpha.pak")
            .unwrap()
            .id
            .clone();

        let snapshot = state.delete_mod(&alpha).unwrap();

        assert!(!paths.local_mods.join("Alpha.pak").exists());
        assert!(snapshot.mods.iter().all(|item| item.id != alpha));
        assert!(fs::read_dir(paths.backups_dir.join("deleted"))
            .unwrap()
            .flatten()
            .any(|entry| entry.file_name().to_string_lossy().ends_with("-Alpha.pak")));
        assert!(!state.metadata.lock().unwrap().entries.contains_key(&alpha));
    }

    #[test]
    fn deleting_a_merged_mod_moves_all_identical_copies_to_backup() {
        let temp = TempRoot::new("state-delete-identical-copies");
        let paths = temp.paths();
        fs::write(paths.local_mods.join("Alpha.pak"), b"same-content").unwrap();
        fs::write(paths.local_mods.join("Alpha Copy.pak"), b"same-content").unwrap();
        let state = AppState::from_paths(paths.clone()).unwrap();
        let initial = state.scan(false).unwrap();

        assert_eq!(initial.mods.len(), 1);
        assert_eq!(initial.mods[0].duplicate_count, 1);
        let id = initial.mods[0].id.clone();

        let snapshot = state.delete_mod(&id).unwrap();

        assert!(snapshot.mods.is_empty());
        assert!(!paths.local_mods.join("Alpha.pak").exists());
        assert!(!paths.local_mods.join("Alpha Copy.pak").exists());
        let backups = fs::read_dir(paths.backups_dir.join("deleted"))
            .unwrap()
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert_eq!(backups.len(), 2);
        assert!(backups.iter().any(|name| name.ends_with("-Alpha.pak")));
        assert!(backups.iter().any(|name| name.ends_with("-Alpha Copy.pak")));
    }

    #[test]
    fn moves_ue4ss_directory_to_backup_as_a_whole() {
        let temp = TempRoot::new("state-delete-ue4ss");
        let paths = temp.paths();
        let module = paths.ue4ss_mods.join("BetterAI");
        fs::create_dir_all(module.join("Scripts")).unwrap();
        fs::write(module.join("Scripts").join("main.lua"), b"print('ok')").unwrap();
        let state = AppState::from_paths(paths.clone()).unwrap();
        let initial = state.scan(false).unwrap();
        let id = initial
            .mods
            .iter()
            .find(|item| item.file_name == "BetterAI")
            .unwrap()
            .id
            .clone();

        let snapshot = state.delete_mod(&id).unwrap();

        assert!(!module.exists());
        assert!(snapshot.mods.iter().all(|item| item.id != id));
        assert!(fs::read_dir(paths.backups_dir.join("deleted"))
            .unwrap()
            .flatten()
            .any(|entry| entry.path().join("Scripts/main.lua").is_file()));
    }

    #[test]
    fn deletion_requires_a_direct_child_of_a_mod_root() {
        let temp = TempRoot::new("state-delete-containment");
        let paths = temp.paths();
        let escaped = temp.path().join("outside").join("Escape.pak");
        fs::create_dir_all(escaped.parent().unwrap()).unwrap();
        fs::write(&escaped, b"keep").unwrap();

        assert!(is_direct_child(
            &paths.local_mods.join("Alpha.pak"),
            &paths.local_mods
        ));
        assert!(is_direct_child(
            &paths.ue4ss_mods.join("BetterAI"),
            &paths.ue4ss_mods
        ));
        assert!(!is_direct_child(&escaped, &paths.local_mods));
        assert!(!is_direct_child(
            &paths
                .local_mods
                .join("..")
                .join("outside")
                .join("Escape.pak"),
            &paths.local_mods
        ));
        assert!(!is_direct_child(&paths.local_mods, &paths.local_mods));
    }

    #[test]
    fn deletion_is_rejected_while_a_game_process_is_running() {
        let error = ensure_deletion_allowed(true).unwrap_err();
        assert!(error.to_string().contains("游戏运行期间"));
        assert!(ensure_deletion_allowed(false).is_ok());
    }

    #[test]
    fn persists_the_interface_language() {
        let temp = TempRoot::new("state-language");
        let paths = temp.paths();
        let state = AppState::from_paths(paths.clone()).unwrap();

        state.set_language("en-US").unwrap();
        let saved = fs::read_to_string(&paths.config_file).unwrap();
        assert!(saved.contains("\"language\": \"en-US\""));

        let reloaded = AppState::from_paths(paths).unwrap();
        assert_eq!(reloaded.settings.lock().unwrap().language, "en-US");
    }

    #[test]
    fn saves_conflict_winners_and_refreshes_override_statistics() {
        let temp = TempRoot::new("state-conflict-winners");
        let paths = temp.paths();
        let state = AppState::from_paths(paths.clone()).unwrap();
        {
            let mut metadata = state.metadata.lock().unwrap();
            metadata.entry_mut("alpha").pak_entries =
                vec!["SCUM/Content/Shared.uasset".to_string()];
            metadata.entry_mut("beta").pak_entries = vec!["SCUM/Content/Shared.uasset".to_string()];
        }
        *state.mods.write().unwrap() = vec![
            ModEntry {
                id: "alpha".to_string(),
                name: "Alpha".to_string(),
                enabled: true,
                mod_type: "clientPak".to_string(),
                load_order: 0,
                ..ModEntry::default()
            },
            ModEntry {
                id: "beta".to_string(),
                name: "Beta".to_string(),
                enabled: true,
                mod_type: "clientPak".to_string(),
                load_order: 1,
                ..ModEntry::default()
            },
        ];
        let mut winners = BTreeMap::new();
        winners.insert("scum/content/shared".to_string(), "alpha".to_string());

        let snapshot = state.save_conflict_winners(winners).unwrap();

        assert_eq!(snapshot.conflicts.len(), 1);
        assert_eq!(snapshot.conflicts[0].default_winner_id, "beta");
        assert_eq!(snapshot.conflicts[0].winner_id, "alpha");
        assert_eq!(
            snapshot.conflicts[0].selected_winner_id.as_deref(),
            Some("alpha")
        );
        let alpha = snapshot
            .mods
            .iter()
            .find(|item| item.id == "alpha")
            .unwrap();
        let beta = snapshot.mods.iter().find(|item| item.id == "beta").unwrap();
        assert_eq!(alpha.overriding_file_count, 1);
        assert_eq!(beta.overridden_file_count, 1);
        assert!(beta.fully_overridden);
        let saved = crate::metadata::load_metadata(&paths).unwrap();
        assert_eq!(
            saved.conflict_winners["scum/content/shared"],
            "alpha".to_string()
        );

        let mut invalid = BTreeMap::new();
        invalid.insert("scum/content/shared".to_string(), "missing".to_string());
        assert!(state.save_conflict_winners(invalid).is_err());
        assert_eq!(
            state.metadata.lock().unwrap().conflict_winners["scum/content/shared"],
            "alpha"
        );

        let cleared = state.save_conflict_winners(BTreeMap::new()).unwrap();
        assert_eq!(cleared.conflicts[0].winner_id, "beta");
        assert_eq!(cleared.conflicts[0].selected_winner_id, None);
        assert!(state.metadata.lock().unwrap().conflict_winners.is_empty());
    }
}
