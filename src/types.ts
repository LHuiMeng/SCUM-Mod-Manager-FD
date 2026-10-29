export type ThemeMode = "light" | "dark";
export type Language = "zh-CN" | "en-US";
export type NavSection = "library" | "cloud" | "server" | "logs" | "settings";
export type AppEdition = "public" | "server";
export type ModType =
  | "clientPak"
  | "serverPak"
  | "ue4ssMod"
  | "configFile"
  | "script"
  | "other";

export interface ModEntry {
  id: string;
  name: string;
  author?: string | null;
  fileName: string;
  filePath: string;
  fileSize: number;
  lastModified: string;
  enabled: boolean;
  type: ModType;
  loadOrder: number;
  tags: string[];
  notes: string;
  sha256: string;
  originSource: "local" | "cloud";
  deployed: boolean;
  description: string;
  conflictCount: number;
  fileCount: number;
  overriddenFileCount: number;
  overridingFileCount: number;
  fullyOverridden: boolean;
  updateVersion?: string | null;
  coverUrl?: string | null;
  duplicateCount?: number;
  duplicateAliases?: string[];
}

export interface ConflictOwner {
  id: string;
  name: string;
  loadOrder: number;
  type: ModType;
}

export interface ConflictGroup {
  key: string;
  paths: string[];
  owners: ConflictOwner[];
  defaultWinnerId: string;
  winnerId: string;
  selectedWinnerId?: string | null;
}

export interface LaunchOptions {
  log: boolean;
  fileOpenLog: boolean;
  noBattlEye: boolean;
  port: string;
}

export interface CloudSettings {
  baseUrls: string[];
  activeBaseUrl: string;
  maxDownloadSegments: number;
}

export interface SftpAccount {
  id: string;
  name: string;
  host: string;
  port: number;
  username: string;
  modsPath: string;
  hasPassword: boolean;
}

export interface AppSettings {
  scumInstallPath: string;
  serverInstallPath: string;
  theme: ThemeMode;
  language: Language;
  launchOptions: LaunchOptions;
  cloud: CloudSettings;
  sftpAccounts: SftpAccount[];
  activeSftpAccountId: string | null;
}

export interface GameStatus {
  running: boolean;
  mode: "client" | "server" | null;
  pid: number | null;
  startedAt: string | null;
}

export interface LibrarySnapshot {
  mods: ModEntry[];
  conflicts: ConflictGroup[];
  settings: AppSettings;
  gameStatus: GameStatus;
  lastDeployedAt: string | null;
  lastScannedAt: string | null;
  localModsPath: string;
  clientModsPath: string;
}

export interface RuntimeLog {
  id: number;
  timestamp: string;
  level: "info" | "warn" | "error" | "debug";
  target: string;
  message: string;
}

export interface RemoteMod {
  id: string;
  name: string;
  author: string;
  version: string;
  description: string;
  fileSize: number;
  downloadUrl: string;
  sha256: string;
  tags: string[];
  updatedAt: string;
  type: ModType;
  installed: boolean;
  coverUrl?: string | null;
}

export type CloudDownloadPhase =
  | "queued"
  | "preparing"
  | "downloading"
  | "verifying"
  | "installing"
  | "completed"
  | "error";

export interface CloudDownloadProgress {
  id: string;
  phase: CloudDownloadPhase;
  downloaded: number;
  total: number | null;
  segments: number;
  message?: string | null;
}

export interface RemoteFile {
  name: string;
  path: string;
  isDirectory: boolean;
  size: number;
  modifiedAt: string | null;
}

export interface SftpConnectionResult {
  ok: boolean;
  message: string;
  detectedModsPath?: string | null;
  hostKeyFingerprint: string | null;
  requiresTrust: boolean;
}

export interface ImportResult {
  imported: number;
  skipped: number;
  message: string;
}

export interface AppInfo {
  version: string;
  dataRoot: string;
  secretsPath: string;
  platform: string;
  edition: AppEdition;
}

export interface LocaleBundle {
  language: Language;
  messages: Record<string, string>;
  source: "bundled" | "user" | "mixed";
  localeDirectory: string;
  warnings: string[];
}

export interface AppUpdateInfo {
  configured: boolean;
  currentVersion: string;
  available: boolean;
  version: string | null;
  publishedAt: string | null;
  notes: string | null;
  size: number | null;
}

export type AppUpdatePhase =
  | "idle"
  | "checking"
  | "up-to-date"
  | "available"
  | "downloading"
  | "verifying"
  | "installing"
  | "unconfigured"
  | "error";

export interface AppUpdateProgress {
  phase: "downloading" | "verifying" | "installing";
  downloaded: number;
  total: number | null;
}

export interface ToastMessage {
  id: number;
  tone: "default" | "success" | "error";
  title: string;
  detail?: string;
}
