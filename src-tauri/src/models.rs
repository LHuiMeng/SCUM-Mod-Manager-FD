use serde::{Deserialize, Serialize};

pub const MIN_CLOUD_DOWNLOAD_SEGMENTS: usize = 8;
pub const DEFAULT_CLOUD_DOWNLOAD_SEGMENTS: usize = 16;
pub const MAX_CLOUD_DOWNLOAD_SEGMENTS: usize = 128;

fn default_theme() -> String {
    "light".to_string()
}

fn default_language() -> String {
    "zh-CN".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LaunchOptions {
    pub log: bool,
    #[serde(alias = "fileOpenLog", alias = "file_open_log")]
    pub file_open_log: bool,
    #[serde(alias = "noBattlEye", alias = "no_battl_eye")]
    pub no_battl_eye: bool,
    pub port: String,
}

impl Default for LaunchOptions {
    fn default() -> Self {
        Self {
            log: false,
            file_open_log: true,
            no_battl_eye: true,
            port: "7042".to_string(),
        }
    }
}
impl LaunchOptions {
    pub fn build_args(&self, is_server: bool, has_pak_mods: bool) -> Vec<String> {
        let mut args = Vec::new();
        if self.log {
            args.push("-log".to_string());
        }
        if self.file_open_log || has_pak_mods {
            args.push("-fileopenlog".to_string());
        }
        if self.no_battl_eye || has_pak_mods {
            args.push("-nobattleye".to_string());
        }
        if is_server {
            if let Ok(port) = self.port.parse::<u16>() {
                if port > 0 {
                    args.push(format!("-port={port}"));
                }
            }
        }
        args
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CloudSettings {
    #[serde(alias = "baseUrls", alias = "base_urls")]
    pub base_urls: Vec<String>,
    #[serde(alias = "activeBaseUrl", alias = "active_base_url")]
    pub active_base_url: String,
    #[serde(alias = "max_download_segments")]
    pub max_download_segments: usize,
}

impl Default for CloudSettings {
    fn default() -> Self {
        Self {
            base_urls: Vec::new(),
            active_base_url: String::new(),
            max_download_segments: DEFAULT_CLOUD_DOWNLOAD_SEGMENTS,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SftpAccount {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    #[serde(alias = "modsPath", alias = "mods_path")]
    pub mods_path: String,
    #[serde(default)]
    pub ue4ss_path: String,
    #[serde(alias = "hasPassword", alias = "has_password")]
    pub has_password: bool,
}

impl Default for SftpAccount {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: "主服务器".to_string(),
            host: String::new(),
            port: 22,
            username: String::new(),
            mods_path: String::new(),
            ue4ss_path: String::new(),
            has_password: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    #[serde(alias = "scumInstallPath", alias = "scum_install_path")]
    pub scum_install_path: String,
    #[serde(alias = "serverInstallPath", alias = "server_install_path")]
    pub server_install_path: String,
    pub theme: String,
    #[serde(default = "default_language")]
    pub language: String,
    #[serde(alias = "launchOptions", alias = "launch_options")]
    pub launch_options: LaunchOptions,
    #[serde(alias = "cloud", alias = "cloud_sources")]
    pub cloud: CloudSettings,
    pub keep_deployed_mods_on_exit: bool,
    #[serde(alias = "sftpAccounts", alias = "sftp_accounts")]
    pub sftp_accounts: Vec<SftpAccount>,
    #[serde(
        alias = "activeSftpAccountId",
        alias = "active_sftp_account_id",
        alias = "sftp_active"
    )]
    pub active_sftp_account_id: Option<String>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            scum_install_path: String::new(),
            server_install_path: String::new(),
            theme: default_theme(),
            language: default_language(),
            launch_options: LaunchOptions::default(),
            cloud: CloudSettings::default(),
            keep_deployed_mods_on_exit: false,
            sftp_accounts: Vec::new(),
            active_sftp_account_id: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ModEntry {
    pub id: String,
    pub name: String,
    pub author: String,
    pub file_name: String,
    pub file_path: String,
    pub file_size: u64,
    pub last_modified: String,
    pub enabled: bool,
    #[serde(rename = "type")]
    pub mod_type: String,
    pub load_order: usize,
    pub tags: Vec<String>,
    pub notes: String,
    pub sha256: String,
    pub origin_source: String,
    pub deployed: bool,
    pub description: String,
    pub conflict_count: usize,
    #[serde(default)]
    pub file_count: usize,
    #[serde(default)]
    pub overridden_file_count: usize,
    #[serde(default)]
    pub overriding_file_count: usize,
    #[serde(default)]
    pub fully_overridden: bool,
    pub update_version: Option<String>,
    pub cover_url: Option<String>,
    #[serde(default)]
    pub duplicate_count: usize,
    #[serde(default)]
    pub duplicate_aliases: Vec<String>,
}

impl Default for ModEntry {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            author: String::new(),
            file_name: String::new(),
            file_path: String::new(),
            file_size: 0,
            last_modified: String::new(),
            enabled: false,
            mod_type: String::new(),
            load_order: 0,
            tags: Vec::new(),
            notes: String::new(),
            sha256: String::new(),
            origin_source: "local".to_string(),
            deployed: false,
            description: String::new(),
            conflict_count: 0,
            file_count: 0,
            overridden_file_count: 0,
            overriding_file_count: 0,
            fully_overridden: false,
            update_version: None,
            cover_url: None,
            duplicate_count: 0,
            duplicate_aliases: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ConflictOwner {
    pub id: String,
    pub name: String,
    pub load_order: usize,
    #[serde(rename = "type")]
    pub mod_type: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ConflictGroup {
    pub key: String,
    pub paths: Vec<String>,
    pub owners: Vec<ConflictOwner>,
    pub default_winner_id: String,
    pub winner_id: String,
    pub selected_winner_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GameStatus {
    pub running: bool,
    pub mode: Option<String>,
    pub pid: Option<u32>,
    pub started_at: Option<String>,
}

impl Default for GameStatus {
    fn default() -> Self {
        Self {
            running: false,
            mode: None,
            pid: None,
            started_at: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibrarySnapshot {
    pub mods: Vec<ModEntry>,
    pub conflicts: Vec<ConflictGroup>,
    pub settings: AppSettings,
    pub game_status: GameStatus,
    pub last_deployed_at: Option<String>,
    pub last_scanned_at: Option<String>,
    pub local_mods_path: String,
    pub client_mods_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeLog {
    pub id: u64,
    pub timestamp: String,
    pub level: String,
    pub target: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RemoteMod {
    pub id: String,
    pub name: String,
    pub author: String,
    pub version: String,
    pub description: String,
    pub file_size: u64,
    pub download_url: String,
    pub sha256: String,
    pub tags: Vec<String>,
    pub updated_at: String,
    #[serde(rename = "type")]
    pub mod_type: String,
    pub installed: bool,
    pub cover_url: Option<String>,
}

impl Default for RemoteMod {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            author: String::new(),
            version: String::new(),
            description: String::new(),
            file_size: 0,
            download_url: String::new(),
            sha256: String::new(),
            tags: Vec::new(),
            updated_at: String::new(),
            mod_type: String::new(),
            installed: false,
            cover_url: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudDownloadProgress {
    pub id: String,
    pub phase: String,
    pub downloaded: u64,
    pub total: Option<u64>,
    pub segments: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteFile {
    pub name: String,
    pub path: String,
    pub is_directory: bool,
    pub size: u64,
    pub modified_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SftpAccountInput {
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub mods_path: String,
    #[serde(default)]
    pub ue4ss_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SftpConnectionResult {
    pub ok: bool,
    pub message: String,
    pub detected_mods_path: Option<String>,
    #[serde(default)]
    pub detected_ue4ss_path: Option<String>,
    #[serde(default)]
    pub pak_mods: Vec<RemoteFile>,
    #[serde(default)]
    pub ue4ss_mods: Vec<RemoteFile>,
    #[serde(default)]
    pub scanned_directories: usize,
    #[serde(default)]
    pub host_key_fingerprint: Option<String>,
    #[serde(default)]
    pub requires_trust: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadResult {
    pub uploaded: usize,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportResult {
    pub imported: usize,
    pub skipped: usize,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ImportConflict {
    pub source_path: String,
    pub file_name: String,
    pub target_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadResult {
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectPathsResult {
    pub scum_install_path: String,
    pub server_install_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppInfo {
    pub version: String,
    pub data_root: String,
    pub secrets_path: String,
    pub platform: String,
    pub edition: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdateInfo {
    pub configured: bool,
    pub current_version: String,
    pub available: bool,
    pub version: Option<String>,
    pub published_at: Option<String>,
    pub notes: Option<String>,
    pub size: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdateProgress {
    pub phase: String,
    pub downloaded: u64,
    pub total: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallUpdateResult {
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocaleBundle {
    pub language: String,
    pub messages: std::collections::BTreeMap<String, String>,
    pub source: String,
    pub locale_directory: String,
    pub warnings: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::{ConflictGroup, ConflictOwner, LaunchOptions};

    #[test]
    fn client_args_include_pak_compatibility_flags() {
        let options = LaunchOptions {
            log: false,
            file_open_log: false,
            no_battl_eye: false,
            port: "7042".to_string(),
        };
        assert_eq!(
            options.build_args(false, true),
            vec!["-fileopenlog", "-nobattleye"]
        );
    }

    #[test]
    fn server_args_only_add_a_valid_port() {
        let options = LaunchOptions {
            log: true,
            file_open_log: false,
            no_battl_eye: false,
            port: "7777".to_string(),
        };
        assert_eq!(options.build_args(true, false), vec!["-log", "-port=7777"]);
    }

    #[test]
    fn conflict_contract_serializes_camel_case_and_type() {
        let group = ConflictGroup {
            key: "scum/content/shared".to_string(),
            paths: vec!["SCUM/Content/Shared.uasset".to_string()],
            owners: vec![ConflictOwner {
                id: "alpha".to_string(),
                name: "Alpha".to_string(),
                load_order: 0,
                mod_type: "clientPak".to_string(),
            }],
            default_winner_id: "alpha".to_string(),
            winner_id: "alpha".to_string(),
            selected_winner_id: None,
        };

        let value = serde_json::to_value(group).unwrap();

        assert_eq!(value["defaultWinnerId"], "alpha");
        assert_eq!(value["winnerId"], "alpha");
        assert_eq!(value["selectedWinnerId"], serde_json::Value::Null);
        assert_eq!(value["owners"][0]["loadOrder"], 0);
        assert_eq!(value["owners"][0]["type"], "clientPak");
    }
}
