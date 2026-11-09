use crate::cloud;
use crate::config;
use crate::edition;
use crate::launcher::ManagedProcess;
use crate::metadata::{self, MetadataFile};
use crate::models::{
    AppInfo, AppSettings, ConflictGroup, ConflictMergeResult, GameStatus, LibrarySnapshot,
    ModEntry, RenameModResult, RuntimeLog, SftpAccount, SftpAccountInput,
};
use crate::mods::deploy::{
    deployed_file_names, read_manifest, reclaim_mods, reclaim_mods_with_wait,
    rescue_mods_from_game, sync_ue4ss_state, ReclaimWait,
};
use crate::mods::links::{find_pending_links, reclaim_pending_links, PendingLink};
use crate::mods::{refresh_conflicts, scan_local_mods_with_diagnostics};
use crate::paths::{is_within, is_within_resolved, path_string, safe_disk_name, AppPaths};
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
    /// 启动时发现的、可能因异常关机没被回收的目录链接。
    pub pending_links: Mutex<Vec<PendingLink>>,
    /// 最近一次异常退出的取证结果，供前端弹窗展示。
    pub last_crash: Mutex<Option<crate::crash::CrashReport>>,
    /// 部署回收互斥：监控线程与 kill_game/window_close 可能同时回收同一份清单。
    pub reclaim_lock: Mutex<()>,
    /// 启动互斥：并发的 launch_game 会双开游戏并把部署清单写成两次。
    pub launch_lock: Mutex<()>,
}

impl AppState {
    pub fn new(app: &AppHandle) -> Result<Self> {
        Self::from_paths(AppPaths::init(app)?)
    }

    fn from_paths(paths: AppPaths) -> Result<Self> {
        let secrets = load_runtime_secrets(&paths, edition::current());
        let mut settings =
            config::load_settings_with_cloud_defaults(&paths, &secrets.cloud_base_urls)
                .unwrap_or_else(|error| {
                    eprintln!("读取配置失败，使用默认值：{error:#}");
                    let mut settings = AppSettings::default();
                    config::apply_default_cloud_sources(&mut settings, &secrets.cloud_base_urls);
                    settings
                });
        // 首次启动，或配置里还没有绑定安装目录时，直接检测 Steam 库并落盘。
        // 不要让用户先点「自动检测」再点「保存设置」。
        let detected_paths = crate::steam::detect_game_paths();
        let auto_detected_paths =
            crate::steam::fill_missing_settings_paths(&mut settings, detected_paths);
        if auto_detected_paths {
            if let Err(error) = config::save_settings(&paths, &settings) {
                eprintln!("自动检测路径后保存配置失败：{error:#}");
            }
        }
        let installs = vec![
            settings.scum_install_path.clone(),
            settings.server_install_path.clone(),
        ];
        // 「退出后保留部署文件」是明确的用户选择，链接本来就该在，不再打扰。
        let pending_before = if settings.keep_deployed_mods_on_exit {
            Vec::new()
        } else {
            find_pending_links(&paths, &installs)
        };
        // 发现上次残留的链接就先不自动回收，等用户在界面上确认；
        // 没有残留时才走正常的启动清理。
        if !settings.keep_deployed_mods_on_exit && pending_before.is_empty() {
            if let Err(error) = reclaim_mods(&paths) {
                eprintln!("启动时回收上次部署失败：{error:#}");
            }
        }
        let pending_links = if settings.keep_deployed_mods_on_exit {
            Vec::new()
        } else {
            find_pending_links(&paths, &installs)
        };
        let mut metadata = metadata::load_metadata(&paths).unwrap_or_else(|error| {
            eprintln!("读取模组元数据失败，使用默认值：{error:#}");
            MetadataFile::default()
        });
        let deployed = deployed_file_names(&paths);
        let scan =
            scan_local_mods_with_diagnostics(&paths, &mut metadata, &deployed).unwrap_or_default();
        let mut mods = scan.mods;
        // 只用于补显示名，失败时保持原有名称（返回 0）。
        let _ = cloud::apply_catalog_names(&paths, &mut metadata, &mut mods);
        let conflicts = refresh_conflicts(&mut metadata, &mut mods);
        if let Err(error) = metadata::save_metadata(&paths, &metadata) {
            eprintln!("启动时保存模组元数据失败：{error:#}");
        }
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
            pending_links: Mutex::new(pending_links),
            last_crash: Mutex::new(None),
            reclaim_lock: Mutex::new(()),
            launch_lock: Mutex::new(()),
        };
        state.log("info", "app", "Rust 后端已初始化，本地模组扫描完成");
        if auto_detected_paths {
            let (client_path, server_path) = {
                let settings = state.settings.lock().unwrap();
                (
                    settings.scum_install_path.clone(),
                    settings.server_install_path.clone(),
                )
            };
            state.log(
                "info",
                "settings",
                &format!(
                    "已自动检测安装路径并保存：客户端 {}；服务端 {}",
                    if client_path.trim().is_empty() {
                        "未找到"
                    } else {
                        &client_path
                    },
                    if server_path.trim().is_empty() {
                        "未找到"
                    } else {
                        &server_path
                    }
                ),
            );
        }
        log_pak_diagnostics(&state, &scan.diagnostics);
        let pending = state.pending_links.lock().unwrap().clone();
        if let Some(links) = pending.first() {
            let first = format!("{} → {}", links.path, links.target);
            state.log(
                "warn",
                "deploy",
                &format!(
                    "发现 {} 个上次未回收的目录链接（{first}），等待用户确认回收",
                    pending.len()
                ),
            );
        }
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
        let started = std::time::Instant::now();
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
            &format!(
                "扫描完成，共发现 {count} 个本地模组（耗时 {}ms）",
                started.elapsed().as_millis()
            ),
        );
        Ok(self.snapshot())
    }

    pub fn refresh_files(&self) -> Result<LibrarySnapshot> {
        let started = std::time::Instant::now();
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
        self.log(
            "info",
            "library",
            &format!("文件刷新完成（耗时 {}ms）", started.elapsed().as_millis()),
        );
        Ok(self.snapshot())
    }

    pub fn set_mod_enabled(&self, id: &str, enabled: bool) -> Result<LibrarySnapshot> {
        if self.process_running() {
            anyhow::bail!("游戏运行期间不能更改模组启用状态");
        }
        // 在克隆上改，落盘成功后才写回线上列表：落盘失败时不能留下「界面已改、磁盘没改」的分叉。
        let mut mods_snapshot = self.mods.read().unwrap().clone();
        {
            let item = mods_snapshot
                .iter_mut()
                .find(|item| item.id == id)
                .context("找不到指定模组")?;
            item.enabled = enabled;
        }
        let mut metadata = self.metadata.lock().unwrap();
        let previous_enabled = metadata.entry_mut(id).enabled;
        metadata.entry_mut(id).enabled = enabled;
        let conflicts = refresh_conflicts(&mut metadata, &mut mods_snapshot);
        if let Err(error) = metadata::save_metadata(&self.paths, &metadata) {
            metadata.entry_mut(id).enabled = previous_enabled;
            return Err(error);
        }
        drop(metadata);
        *self.mods.write().unwrap() = mods_snapshot.clone();
        *self.conflicts.write().unwrap() = conflicts;
        if let Err(error) = sync_ue4ss_state(&self.paths, &mods_snapshot) {
            self.log("warn", "ue4ss", &format!("同步 mods.txt 失败：{error:#}"));
        }
        Ok(self.snapshot())
    }

    /// 批量启停：一次落盘、一次刷新冲突，避免“全选”时反复写 mods_meta.json。
    pub fn set_mods_enabled(&self, ids: &[String], enabled: bool) -> Result<LibrarySnapshot> {
        if self.process_running() {
            anyhow::bail!("游戏运行期间不能更改模组启用状态");
        }
        let requested: std::collections::HashSet<&str> = ids
            .iter()
            .map(String::as_str)
            .filter(|id| !id.is_empty())
            .collect();
        if requested.is_empty() {
            return Ok(self.snapshot());
        }

        let mut mods_snapshot = self.mods.read().unwrap().clone();
        let mut changed = 0usize;
        for item in &mut mods_snapshot {
            if requested.contains(item.id.as_str()) && item.enabled != enabled {
                item.enabled = enabled;
                changed += 1;
            }
        }
        if changed == 0 {
            return Ok(self.snapshot());
        }

        let mut metadata = self.metadata.lock().unwrap();
        let mut previous = Vec::new();
        for item in &mods_snapshot {
            if !requested.contains(item.id.as_str()) {
                continue;
            }
            let entry = metadata.entry_mut(&item.id);
            if entry.enabled != enabled {
                previous.push((item.id.clone(), entry.enabled));
                entry.enabled = enabled;
            }
        }
        let conflicts = refresh_conflicts(&mut metadata, &mut mods_snapshot);
        if let Err(error) = metadata::save_metadata(&self.paths, &metadata) {
            for (id, previous_enabled) in previous {
                metadata.entry_mut(&id).enabled = previous_enabled;
            }
            return Err(error);
        }
        drop(metadata);
        *self.mods.write().unwrap() = mods_snapshot.clone();
        *self.conflicts.write().unwrap() = conflicts;
        if let Err(error) = sync_ue4ss_state(&self.paths, &mods_snapshot) {
            self.log("warn", "ue4ss", &format!("同步 mods.txt 失败：{error:#}"));
        }
        self.log(
            "info",
            "library",
            &format!(
                "已{} {} 个模组",
                if enabled { "启用" } else { "停用" },
                changed
            ),
        );
        Ok(self.snapshot())
    }

    /// 重命名本地模组文件或 UE4SS 目录，并把启停、标签、备注等元数据迁移到新 ID。
    pub fn rename_mod(&self, id: &str, new_name: &str) -> Result<RenameModResult> {
        if self.process_running() {
            anyhow::bail!("游戏运行期间不能重命名模组");
        }
        let item = self
            .mods
            .read()
            .unwrap()
            .iter()
            .find(|item| item.id == id)
            .cloned()
            .context("找不到指定模组")?;
        let (root, extension) = match item.mod_type.as_str() {
            "clientPak" => (self.paths.local_mods.as_path(), Some("pak")),
            "ue4ssMod" => (self.paths.ue4ss_mods.as_path(), None),
            _ => anyhow::bail!("这个模组类型不支持重命名"),
        };
        let old_path = PathBuf::from(&item.file_path);
        if !is_direct_child(&old_path, root) {
            anyhow::bail!("拒绝重命名模组库之外的路径");
        }
        if extension.is_some() && !old_path.is_file() {
            anyhow::bail!("PAK 模组文件不存在");
        }
        if extension.is_none() && !old_path.is_dir() {
            anyhow::bail!("UE4SS 模组目录不存在");
        }

        let new_file_name = normalized_mod_file_name(new_name, extension)?;
        let new_path = root.join(&new_file_name);
        if new_path == old_path {
            return Ok(RenameModResult {
                snapshot: self.snapshot(),
                previous_id: id.to_string(),
                id: id.to_string(),
                name: item.name.clone(),
            });
        }
        let same_path_ignoring_case =
            path_string(&new_path).eq_ignore_ascii_case(&path_string(&old_path));
        if new_path.exists() && !same_path_ignoring_case {
            anyhow::bail!("模组库里已经存在同名文件：{new_file_name}");
        }

        rename_local_entry(&old_path, &new_path)?;
        let new_id = crate::mods::stable_id(root, &new_file_name);
        let mut metadata = self.metadata.lock().unwrap();
        let previous_metadata = metadata.clone();
        let mut migrated = metadata.entries.remove(id).unwrap_or_default();
        // 物理改名后应让库里的名称跟随磁盘；清掉云端显示名缓存，避免看起来“没改名”。
        migrated.name = None;
        migrated.name_from_file_name = true;
        migrated.file_size = None;
        migrated.modified_at = None;
        metadata.entries.insert(new_id.clone(), migrated);
        for entry in &mut metadata.order {
            if entry == id {
                *entry = new_id.clone();
            }
        }
        for winner in metadata.conflict_winners.values_mut() {
            if winner == id {
                *winner = new_id.clone();
            }
        }
        if let Err(error) = metadata::save_metadata(&self.paths, &metadata) {
            *metadata = previous_metadata;
            drop(metadata);
            let rollback = rename_local_entry(&new_path, &old_path);
            return match rollback {
                Ok(()) => Err(error.context("保存模组元数据失败，已恢复原文件名")),
                Err(rollback_error) => Err(error.context(format!(
                    "保存模组元数据失败，且无法恢复原文件名：{rollback_error:#}"
                ))),
            };
        }
        drop(metadata);

        let snapshot = match self.refresh_files() {
            Ok(snapshot) => snapshot,
            Err(error) => {
                self.log(
                    "warn",
                    "library",
                    &format!("改名已写入磁盘，但刷新模组库失败：{error:#}"),
                );
                self.snapshot()
            }
        };
        let result_id = if snapshot.mods.iter().any(|mod_entry| mod_entry.id == new_id) {
            new_id
        } else {
            id.to_string()
        };
        let display_name = Path::new(&new_file_name)
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        self.log(
            "info",
            "library",
            &format!("已将模组 {} 重命名为 {}", item.name, display_name),
        );
        Ok(RenameModResult {
            snapshot,
            previous_id: id.to_string(),
            id: result_id,
            name: display_name,
        })
    }

    pub fn reorder_mods(&self, ids: &[String]) -> Result<LibrarySnapshot> {
        // 在克隆上排序，落盘成功后才替换线上列表：落盘失败时不能把内存里的模组清空。
        let current = self.mods.read().unwrap().clone();
        let mut by_id: HashMap<String, ModEntry> = current
            .into_iter()
            .map(|item| (item.id.clone(), item))
            .collect();
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
        let order = ordered
            .iter()
            .map(|item| item.id.clone())
            .collect::<Vec<_>>();
        let mut metadata = self.metadata.lock().unwrap();
        let conflicts = refresh_conflicts(&mut metadata, &mut ordered);
        let previous_order = metadata.order.clone();
        metadata.order = order;
        if let Err(error) = metadata::save_metadata(&self.paths, &metadata) {
            metadata.order = previous_order;
            return Err(error);
        }
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

    pub fn prepare_conflict_merge(&self) -> Result<ConflictMergeResult> {
        if self.process_running() {
            anyhow::bail!("游戏运行期间不能重新融合冲突模组");
        }
        let mods = self.mods.read().unwrap().clone();
        let metadata = self.metadata.lock().unwrap().clone();
        let result = crate::mods::merge_cache::prepare(&self.paths, &mods, &metadata)?;
        let message = if result.rebuilt {
            format!(
                "已重建冲突融合缓存：{} 个模组，{} 个资源",
                result.source_mods, result.entries
            )
        } else if result.required {
            "冲突融合缓存已是最新".to_string()
        } else {
            "当前没有资源冲突，无需融合".to_string()
        };
        self.log("info", "conflict", &message);
        Ok(result)
    }

    pub fn update_mod_metadata(
        &self,
        id: &str,
        tags: Vec<String>,
        notes: String,
    ) -> Result<LibrarySnapshot> {
        // 同样先改克隆、落盘成功后再写回，失败时线上列表保持原样。
        let mut mods_snapshot = self.mods.read().unwrap().clone();
        {
            let item = mods_snapshot
                .iter_mut()
                .find(|item| item.id == id)
                .context("找不到指定模组")?;
            item.tags = tags.clone();
            item.notes = notes.clone();
        }
        let mut metadata = self.metadata.lock().unwrap();
        let entry = metadata.entry_mut(id);
        let previous_tags = entry.tags.clone();
        let previous_notes = entry.notes.clone();
        entry.tags = tags;
        entry.notes = notes;
        if let Err(error) = metadata::save_metadata(&self.paths, &metadata) {
            let entry = metadata.entry_mut(id);
            entry.tags = previous_tags;
            entry.notes = previous_notes;
            return Err(error);
        }
        drop(metadata);
        *self.mods.write().unwrap() = mods_snapshot;
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
        // 持锁写盘：避免与 set_theme / set_language / set_cloud_settings 的并发写
        // 互相截断 config.json，产生无法解析的坏文件。
        let mut current = self.settings.lock().unwrap();
        config::save_settings(&self.paths, &settings)?;
        let saved = config::load_settings(&self.paths)?;
        *current = saved.clone();
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

    pub fn last_crash(&self) -> Option<crate::crash::CrashReport> {
        self.last_crash.lock().unwrap().clone()
    }

    pub fn take_last_crash(&self) -> Option<crate::crash::CrashReport> {
        self.last_crash.lock().unwrap().take()
    }

    pub fn clear_logs(&self) {
        self.logs.lock().unwrap().clear();
        let _ = std::fs::write(self.paths.logs_dir.join("runtime.jsonl"), "");
    }

    /// 统一的「游戏是否在运行」判定。
    ///
    /// 必须走 `launcher::is_running`：它额外检查 SCUM.exe/SCUMServer.exe 是否仍在运行，
    /// 覆盖「被启动的只是引导进程、它退出后游戏主进程还在跑」的情况。只看子进程句柄会让
    /// 运行期的写操作（改启用状态、删除模组、回收部署）在游戏真正运行时被放行。
    pub fn process_running(&self) -> bool {
        crate::launcher::is_running(self)
    }

    pub fn pending_links(&self) -> Vec<PendingLink> {
        self.pending_links.lock().unwrap().clone()
    }

    /// 用户确认后回收残留链接，并把「文件被占用、正在等待」的进度交给调用方。
    pub fn reclaim_pending_links_notified(
        &self,
        notify: impl FnMut(&ReclaimWait),
    ) -> Result<usize> {
        let settings = self.settings.lock().unwrap().clone();
        let installs = vec![settings.scum_install_path, settings.server_install_path];
        // 链接模式下部署目录里还有硬链接与清单，先按清单回收，再断链接。
        if let Err(error) = reclaim_mods_with_wait(&self.paths, notify) {
            self.log(
                "warn",
                "deploy",
                &format!("回收部署文件未完全成功，继续断开残留链接：{error:#}"),
            );
        }
        let removed = reclaim_pending_links(&self.paths, &installs)?;
        *self.pending_links.lock().unwrap() = find_pending_links(&self.paths, &installs);
        self.log(
            "info",
            "deploy",
            &format!("已回收 {removed} 个残留目录链接，游戏目录恢复为真实目录"),
        );
        Ok(removed)
    }

    /// 用户选择“先保留”时只清空本次提醒，不动链接。
    pub fn dismiss_pending_links(&self) {
        self.pending_links.lock().unwrap().clear();
        self.log("warn", "deploy", "用户选择保留残留目录链接，未做回收");
    }

    pub fn reclaim_deployments_after_exit(&self) -> Result<Option<usize>> {
        self.reclaim_deployments_after_exit_notified(|_| {})
    }

    /// 回收部署文件；被占用时把等待信息交给调用方（用于前端提示“正在回收”）。
    pub fn reclaim_deployments_after_exit_notified(
        &self,
        notify: impl FnMut(&ReclaimWait),
    ) -> Result<Option<usize>> {
        // 监控线程与 stop_with_notice 可能同时走到这里：互斥可以避免两边删同一批文件、
        // 各自写出不同的剩余清单，甚至交错写坏 deployment_manifest.json。
        let _reclaim_guard = self.reclaim_lock.lock().unwrap();
        let settings = self.settings.lock().unwrap().clone();
        // 两种模式默认都在退出后回收：复制模式删文件，链接模式只断链接（毫秒级，不搬数据）。
        if settings.keep_deployed_mods_on_exit {
            return Ok(None);
        }
        let installs = vec![settings.scum_install_path, settings.server_install_path];
        let reclaimed = reclaim_mods_with_wait(&self.paths, notify);
        *self.pending_links.lock().unwrap() = find_pending_links(&self.paths, &installs);
        let reclaimed = reclaimed?;
        *self.last_deployed_at.lock().unwrap() = None;
        Ok(Some(reclaimed))
    }

    #[cfg(test)]
    pub fn shutdown_cleanup(&self) {
        self.shutdown_cleanup_notified(|_| {});
    }

    pub fn shutdown_cleanup_notified(&self, notify: impl FnMut(&ReclaimWait)) {
        if self.process.lock().unwrap().is_some() {
            let _ = crate::launcher::stop_with_notice(self, notify);
        } else {
            if let Err(error) = self.reclaim_deployments_after_exit_notified(notify) {
                self.log(
                    "warn",
                    "deploy",
                    &format!("退出回收部署文件失败：{error:#}"),
                );
            }
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
        // 目标可能是指向根外的 junction/符号链接，解析后再确认一次。
        && (!path.exists() || is_within_resolved(path, root))
        && path.parent().is_some_and(|parent| is_within(parent, root))
        && path
            .parent()
            .is_some_and(|parent| normalize_path(parent) == normalize_path(root))
}

fn normalize_path(path: &Path) -> PathBuf {
    std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf())
}

const MAX_MOD_RENAME_CHARS: usize = 80;
const WINDOWS_RESERVED_MOD_NAMES: [&str; 22] = [
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

fn normalized_mod_file_name(raw: &str, extension: Option<&str>) -> Result<String> {
    let trimmed = raw.trim();
    let suffix = extension.map(|value| format!(".{value}"));
    let lower = trimmed.to_ascii_lowercase();
    let name = match suffix.as_deref() {
        Some(suffix) if lower.ends_with(suffix) => {
            &trimmed[..trimmed.len().saturating_sub(suffix.len())]
        }
        _ => trimmed,
    };
    if name.is_empty() {
        anyhow::bail!("模组名称不能为空");
    }
    if name.chars().count() > MAX_MOD_RENAME_CHARS {
        anyhow::bail!("模组名称不能超过 {MAX_MOD_RENAME_CHARS} 个字符");
    }
    if name == "." || name == ".." || name.starts_with('.') {
        anyhow::bail!("模组名称不能以点开头");
    }
    if name.ends_with('.') || name.ends_with(' ') {
        anyhow::bail!("模组名称不能以点或空格结尾");
    }
    if name.chars().any(|ch| {
        ch.is_control() || matches!(ch, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')
    }) {
        anyhow::bail!("模组名称不能包含 \\ / : * ? \" < > | 或控制字符");
    }
    let stem = name
        .split('.')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_uppercase();
    if WINDOWS_RESERVED_MOD_NAMES.contains(&stem.as_str()) {
        anyhow::bail!("“{stem}”是 Windows 保留名称，请换一个名称");
    }
    Ok(match extension {
        Some("pak") => format!("{name}.pak"),
        Some(other) => format!("{name}.{other}"),
        None => name.to_string(),
    })
}

fn rename_local_entry(source: &Path, destination: &Path) -> Result<()> {
    if source == destination {
        return Ok(());
    }
    let same_path_ignoring_case =
        path_string(source).eq_ignore_ascii_case(&path_string(destination));
    if !same_path_ignoring_case {
        return std::fs::rename(source, destination).with_context(|| {
            format!(
                "无法将 {} 重命名为 {}",
                source.display(),
                destination.display()
            )
        });
    }
    // Windows 只改大小写时，直接 rename 可能被当成同一个路径；用临时名中转一次。
    let temporary = source.with_file_name(format!(".scum-rename-{}", Uuid::new_v4()));
    std::fs::rename(source, &temporary)
        .with_context(|| format!("无法重命名 {}", source.display()))?;
    match std::fs::rename(&temporary, destination) {
        Ok(()) => Ok(()),
        Err(error) => {
            let _ = std::fs::rename(&temporary, source);
            Err(error).with_context(|| {
                format!(
                    "无法将 {} 重命名为 {}",
                    source.display(),
                    destination.display()
                )
            })
        }
    }
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
    use super::{ensure_deletion_allowed, is_direct_child, normalized_mod_file_name, AppState};
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

    /// 落盘失败时不能把内存里的模组列表清空（旧实现会 drain 掉 self.mods 后提前返回）。
    #[test]
    fn reorder_failure_keeps_the_in_memory_mod_list() {
        let temp = TempRoot::new("reorder-rollback");
        let paths = temp.paths();
        fs::write(paths.local_mods.join("Alpha.pak"), b"alpha").unwrap();
        fs::write(paths.local_mods.join("Beta.pak"), b"beta").unwrap();
        let state = AppState::from_paths(paths.clone()).unwrap();
        let initial = state.scan(false).unwrap();
        let ids = initial
            .mods
            .iter()
            .map(|item| item.id.clone())
            .collect::<Vec<_>>();
        assert_eq!(ids.len(), 2);

        // 把元数据文件及其 .bak 都换成非空目录，让 save_metadata 一定失败。
        for target in [
            paths.metadata_file.clone(),
            crate::paths::backup_path_of(&paths.metadata_file),
        ] {
            let _ = fs::remove_file(&target);
            fs::create_dir_all(&target).unwrap();
            fs::write(target.join("blocker"), b"x").unwrap();
        }

        let reordered = vec![ids[1].clone(), ids[0].clone()];
        assert!(state.reorder_mods(&reordered).is_err());
        assert_eq!(
            state.snapshot().mods.len(),
            2,
            "落盘失败后内存里的模组不能被清空"
        );
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
    fn batch_toggle_updates_all_requested_mods_and_persists() {
        let temp = TempRoot::new("state-batch-toggle");
        let paths = temp.paths();
        for name in ["Alpha.pak", "Beta.pak", "Gamma.pak"] {
            fs::write(paths.local_mods.join(name), name.as_bytes()).unwrap();
        }
        let state = AppState::from_paths(paths.clone()).unwrap();
        let initial = state.scan(false).unwrap();
        let ids = initial
            .mods
            .iter()
            .map(|item| item.id.clone())
            .collect::<Vec<_>>();

        let snapshot = state
            .set_mods_enabled(&ids[..2], false)
            .expect("批量停用应成功");

        assert_eq!(snapshot.mods.iter().filter(|item| item.enabled).count(), 1);
        let reloaded = AppState::from_paths(paths).unwrap();
        assert_eq!(
            reloaded
                .mods
                .read()
                .unwrap()
                .iter()
                .filter(|item| item.enabled)
                .count(),
            1,
            "批量启停必须写入 mods_meta.json"
        );
    }

    #[test]
    fn renames_a_pak_mod_and_migrates_its_metadata() {
        let temp = TempRoot::new("state-rename-pak");
        let paths = temp.paths();
        fs::write(paths.local_mods.join("Alpha.pak"), b"alpha").unwrap();
        let state = AppState::from_paths(paths.clone()).unwrap();
        let initial = state.scan(false).unwrap();
        let id = initial.mods[0].id.clone();
        state
            .update_mod_metadata(&id, vec!["server".to_string()], "保留备注".to_string())
            .unwrap();
        state.set_mod_enabled(&id, false).unwrap();

        let result = state.rename_mod(&id, "Renamed Weapon").unwrap();

        assert!(!paths.local_mods.join("Alpha.pak").exists());
        assert!(paths.local_mods.join("Renamed Weapon.pak").is_file());
        assert_ne!(result.id, id);
        let renamed = result
            .snapshot
            .mods
            .iter()
            .find(|item| item.id == result.id)
            .expect("改名后应能在快照里找到新模组");
        assert_eq!(renamed.name, "Renamed Weapon");
        assert!(!renamed.enabled);
        assert_eq!(renamed.tags, vec!["server"]);
        assert_eq!(renamed.notes, "保留备注");

        let reloaded = AppState::from_paths(paths).unwrap();
        let renamed = reloaded
            .mods
            .read()
            .unwrap()
            .iter()
            .find(|item| item.file_name == "Renamed Weapon.pak")
            .cloned()
            .expect("重新加载后仍应保留新文件名");
        assert!(!renamed.enabled);
        assert_eq!(renamed.tags, vec!["server"]);
        assert_eq!(renamed.notes, "保留备注");
    }

    #[test]
    fn renames_a_ue4ss_directory() {
        let temp = TempRoot::new("state-rename-ue4ss");
        let paths = temp.paths();
        let module = paths.ue4ss_mods.join("BetterAI");
        fs::create_dir_all(module.join("Scripts")).unwrap();
        fs::write(module.join("Scripts").join("main.lua"), b"print('ok')").unwrap();
        let state = AppState::from_paths(paths.clone()).unwrap();
        let initial = state.scan(false).unwrap();
        let id = initial.mods[0].id.clone();

        let result = state.rename_mod(&id, "Better AI").unwrap();

        assert!(!module.exists());
        assert!(paths
            .ue4ss_mods
            .join("Better AI")
            .join("Scripts")
            .join("main.lua")
            .is_file());
        assert_eq!(result.name, "Better AI");
    }

    #[test]
    fn rename_rejects_an_existing_target_and_invalid_names() {
        let temp = TempRoot::new("state-rename-conflict");
        let paths = temp.paths();
        fs::write(paths.local_mods.join("Alpha.pak"), b"alpha").unwrap();
        fs::write(paths.local_mods.join("Beta.pak"), b"beta").unwrap();
        let state = AppState::from_paths(paths).unwrap();
        let initial = state.scan(false).unwrap();
        let alpha = initial
            .mods
            .iter()
            .find(|item| item.file_name == "Alpha.pak")
            .unwrap()
            .id
            .clone();

        assert!(state.rename_mod(&alpha, "Beta").is_err());
        assert!(state.rename_mod(&alpha, "../Escape").is_err());
        assert!(state.rename_mod(&alpha, "CON").is_err());
    }

    #[test]
    fn normalizes_rename_extensions_without_allowing_traversal() {
        assert_eq!(
            normalized_mod_file_name("  My Mod.PAK  ", Some("pak")).unwrap(),
            "My Mod.pak"
        );
        assert_eq!(
            normalized_mod_file_name("Better AI", None).unwrap(),
            "Better AI"
        );
        assert!(normalized_mod_file_name("", Some("pak")).is_err());
        assert!(normalized_mod_file_name("bad/name", Some("pak")).is_err());
        assert!(normalized_mod_file_name(".hidden", None).is_err());
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
