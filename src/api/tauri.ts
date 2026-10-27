import { invoke } from "@tauri-apps/api/core";
import { mockInvoke } from "./mock";
import type {
  AppInfo,
  AppSettings,
  AppUpdateInfo,
  ImportResult,
  LibrarySnapshot,
  RemoteFile,
  RemoteMod,
  RuntimeLog,
  SftpConnectionResult,
  ThemeMode,
} from "../types";

export const isTauri = () => typeof window !== "undefined" && Boolean(window.__TAURI_INTERNALS__);

async function call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (isTauri()) {
    return invoke<T>(command, args);
  }
  return mockInvoke<T>(command, args);
}

export const api = {
  getSnapshot: () => call<LibrarySnapshot>("get_library_snapshot"),
  scanLibrary: () => call<LibrarySnapshot>("scan_library"),
  setModEnabled: (id: string, enabled: boolean) =>
    call<LibrarySnapshot>("set_mod_enabled", { id, enabled }),
  reorderMods: (ids: string[]) => call<LibrarySnapshot>("reorder_mods", { ids }),
  updateModMetadata: (id: string, tags: string[], notes: string) =>
    call<LibrarySnapshot>("update_mod_metadata", { id, tags, notes }),
  saveSettings: (settings: AppSettings) =>
    call<AppSettings>("save_settings", { settings }),
  setTheme: (theme: ThemeMode) => call<void>("set_theme", { theme }),
  detectPaths: () =>
    call<{ scumInstallPath: string; serverInstallPath: string }>("detect_paths"),
  launchGame: (mode: "client" | "server") =>
    call<LibrarySnapshot["gameStatus"]>("launch_game", { mode }),
  killGame: () => call<LibrarySnapshot["gameStatus"]>("kill_game"),
  importMods: (paths: string[]) => call<ImportResult>("import_mods", { paths }),
  openPath: (path: string) => call<void>("open_path", { path }),
  openModFolder: (id: string) => call<void>("open_mod_folder", { id }),
  getLogs: () => call<RuntimeLog[]>("get_logs"),
  clearLogs: () => call<void>("clear_logs"),
  getAppInfo: () => call<AppInfo>("get_app_info"),
  checkAppUpdate: () => call<AppUpdateInfo>("check_app_update"),
  installAppUpdate: () => call<{ message: string }>("install_app_update"),
  fetchCloudCatalog: () => call<RemoteMod[]>("fetch_cloud_catalog"),
  downloadRemoteMod: (id: string) => call<{ message: string }>("download_remote_mod", { id }),
  listRemoteFiles: (path: string) =>
    call<RemoteFile[]>("list_remote_files", { path }),
  testSftpConnection: (accountId: string) =>
    call<SftpConnectionResult>("test_sftp_connection", { accountId }),
  trustSftpHost: (accountId: string, fingerprint: string) =>
    call<SftpConnectionResult>("trust_sftp_host", { accountId, fingerprint }),
  saveSftpAccount: (
    account: { name: string; host: string; port: number; username: string; modsPath: string },
    password: string,
  ) => call<LibrarySnapshot>("save_sftp_account", { account, password }),
  uploadServerMods: (accountId: string, paths: string[]) =>
    call<{ uploaded: number; message: string }>("upload_server_mods", { accountId, paths }),
  minimize: () => call<void>("window_minimize"),
  toggleMaximize: () => call<void>("window_toggle_maximize"),
  close: () => call<void>("window_close"),
};

export async function chooseFiles(): Promise<string[]> {
  if (!isTauri()) return [];
  const { open } = await import("@tauri-apps/plugin-dialog");
  const selected = await open({
    multiple: true,
    directory: false,
    filters: [{ name: "SCUM 模组", extensions: ["pak", "zip"] }],
  });
  if (!selected) return [];
  return Array.isArray(selected) ? selected : [selected];
}

export async function chooseDirectory(): Promise<string | null> {
  if (!isTauri()) return null;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const selected = await open({ directory: true, multiple: false });
  return typeof selected === "string" ? selected : null;
}
