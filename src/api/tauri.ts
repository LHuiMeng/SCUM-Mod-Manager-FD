import { invoke } from "@tauri-apps/api/core";
import { mockInvoke } from "./mock";
import type {
  AppInfo,
  AppSettings,
  AppUpdateInfo,
  ImportConflict,
  ImportResult,
  Language,
  LibrarySnapshot,
  LocaleBundle,
  RemoteFile,
  RemoteMod,
  RuntimeLog,
  SftpConflictReport,
  SftpConnectionResult,
  SftpOperationResult,
  SftpUploadKind,
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
  saveConflictWinners: (winners: Record<string, string>) =>
    call<LibrarySnapshot>("save_conflict_winners", { winners }),
  deleteMod: (id: string) => call<LibrarySnapshot>("delete_mod", { id }),
  saveSettings: (settings: AppSettings) =>
    call<AppSettings>("save_settings", { settings }),
  setTheme: (theme: ThemeMode) => call<void>("set_theme", { theme }),
  setLanguage: (language: Language) =>
    call<void>("set_language", { language }),
  getLocale: (language: Language) =>
    call<LocaleBundle>("get_locale", { language }),
  getLocales: () => call<LocaleBundle[]>("get_locales"),
  detectPaths: () =>
    call<{ scumInstallPath: string; serverInstallPath: string }>("detect_paths"),
  launchGame: (mode: "client" | "server") =>
    call<LibrarySnapshot["gameStatus"]>("launch_game", { mode }),
  killGame: () => call<LibrarySnapshot["gameStatus"]>("kill_game"),
  inspectModImport: (paths: string[]) =>
    call<ImportConflict[]>("inspect_mod_import", { paths }),
  importMods: (paths: string[], replaceExisting = false) =>
    call<ImportResult>("import_mods", { paths, replaceExisting }),
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
  downloadSftpFile: (
    accountId: string,
    path: string,
    localPath: string,
  ) =>
    call<SftpOperationResult>("download_sftp_file", {
      accountId,
      path,
      localPath,
    }),
  testSftpConnection: (accountId: string) =>
    call<SftpConnectionResult>("test_sftp_connection", { accountId }),
  trustSftpHost: (accountId: string, fingerprint: string) =>
    call<SftpConnectionResult>("trust_sftp_host", { accountId, fingerprint }),
  saveSftpAccount: (
    account: {
      name: string;
      host: string;
      port: number;
      username: string;
      modsPath: string;
      ue4ssPath: string;
    },
    password: string,
  ) => call<LibrarySnapshot>("save_sftp_account", { account, password }),
  uploadServerMods: (accountId: string, kind: SftpUploadKind, paths: string[]) =>
    call<{ uploaded: number; message: string }>("upload_server_mods", {
      accountId,
      kind,
      paths,
    }),
  renameSftpEntry: (accountId: string, path: string, newName: string) =>
    call<SftpOperationResult>("rename_sftp_entry", { accountId, path, newName }),
  deleteSftpEntry: (accountId: string, path: string) =>
    call<SftpOperationResult>("delete_sftp_entry", { accountId, path }),
  getSftpRemoteNotes: (accountId: string) =>
    call<Record<string, string>>("get_sftp_remote_notes", { accountId }),
  saveSftpRemoteNote: (accountId: string, path: string, note: string) =>
    call<Record<string, string>>("save_sftp_remote_note", { accountId, path, note }),
  analyzeSftpConflicts: (accountId: string) =>
    call<SftpConflictReport>("analyze_sftp_conflicts", { accountId }),
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
    filters: [{ name: "SCUM Mods", extensions: ["pak", "zip"] }],
  });
  if (!selected) return [];
  return Array.isArray(selected) ? selected : [selected];
}

export async function chooseServerPakFiles(): Promise<string[]> {
  if (!isTauri()) return [];
  const { open } = await import("@tauri-apps/plugin-dialog");
  const selected = await open({
    multiple: true,
    directory: false,
    filters: [{ name: "SCUM PAK Mods", extensions: ["pak"] }],
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

export async function chooseSavePath(defaultName: string): Promise<string | null> {
  if (!isTauri()) return null;
  const { save } = await import("@tauri-apps/plugin-dialog");
  return save({
    defaultPath: defaultName,
  });
}
