import type {
  AppInfo,
  AppSettings,
  AppUpdateInfo,
  GameStatus,
  LibrarySnapshot,
  ModEntry,
  RemoteFile,
  RemoteMod,
  RuntimeLog,
} from "../types";

const now = Date.now();

const sampleMods: ModEntry[] = [
  {
    id: "scum_weaponpack_elite",
    name: "SCUM_WeaponPack_Elite",
    fileName: "SCUM_WeaponPack_Elite.pak",
    filePath: "~mods/SCUM_WeaponPack_Elite.pak",
    fileSize: 1374389535,
    lastModified: new Date(now - 2 * 86400000).toISOString(),
    enabled: true,
    type: "clientPak",
    loadOrder: 0,
    tags: ["战斗", "武器", "平衡性"],
    notes: "服务器开荒使用。与 LootBalance_Plus 一起测试过，目前没有资源冲突。",
    sha256: "4c81a71f0df5e38e29e922fa64a2c6bc7a92",
    originSource: "local",
    deployed: false,
    description: "武器与战斗平衡扩展",
    conflictCount: 0,
  },
  {
    id: "vehicleoverhaul_v3",
    name: "VehicleOverhaul_V3",
    fileName: "VehicleOverhaul_V3.pak",
    filePath: "~mods/VehicleOverhaul_V3.pak",
    fileSize: 664797184,
    lastModified: new Date(now - 3 * 86400000).toISOString(),
    enabled: true,
    type: "clientPak",
    loadOrder: 1,
    tags: ["载具"],
    notes: "",
    sha256: "879f6f7b4a62",
    originSource: "local",
    deployed: false,
    description: "载具操控与外观重制",
    conflictCount: 0,
  },
  {
    id: "lootbalance_plus",
    name: "LootBalance_Plus",
    fileName: "LootBalance_Plus.pak",
    filePath: "~mods/LootBalance_Plus.pak",
    fileSize: 13421772,
    lastModified: new Date(now - 4 * 86400000).toISOString(),
    enabled: true,
    type: "clientPak",
    loadOrder: 2,
    tags: ["生存"],
    notes: "",
    sha256: "83d8a36f99b2",
    originSource: "local",
    deployed: false,
    description: "物资刷新与生存平衡",
    conflictCount: 0,
  },
  {
    id: "mapextensions_north",
    name: "MapExtensions_North",
    fileName: "MapExtensions_North.pak",
    filePath: "~mods/MapExtensions_North.pak",
    fileSize: 1503238553,
    lastModified: new Date(now - 5 * 86400000).toISOString(),
    enabled: true,
    type: "clientPak",
    loadOrder: 3,
    tags: ["地图"],
    notes: "",
    sha256: "7a23c16b90d1",
    originSource: "local",
    deployed: false,
    description: "北部岛屿地图扩展",
    conflictCount: 0,
  },
  {
    id: "hd_character_textures",
    name: "HD_Character_Textures",
    fileName: "HD_Character_Textures.pak",
    filePath: "~mods/HD_Character_Textures.pak",
    fileSize: 882900992,
    lastModified: new Date(now - 12 * 3600000).toISOString(),
    enabled: true,
    type: "clientPak",
    loadOrder: 4,
    tags: ["材质"],
    notes: "",
    sha256: "7c3fa44d23cf",
    originSource: "local",
    deployed: false,
    description: "角色材质高清重制",
    conflictCount: 0,
    updateVersion: "2.4.1",
  },
  {
    id: "betterai_core",
    name: "BetterAI_Core",
    fileName: "BetterAI_Core",
    filePath: "ue4ss_runtime/ue4ss/Mods/BetterAI_Core",
    fileSize: 19503513,
    lastModified: new Date(now - 7 * 86400000).toISOString(),
    enabled: true,
    type: "ue4ssMod",
    loadOrder: 5,
    tags: ["AI"],
    notes: "",
    sha256: "",
    originSource: "local",
    deployed: false,
    description: "AI 行为与感知优化",
    conflictCount: 0,
  },
  {
    id: "ui_cleanhud",
    name: "UI_CleanHUD",
    fileName: "UI_CleanHUD.pak",
    filePath: "~mods/UI_CleanHUD.pak",
    fileSize: 3250585,
    lastModified: new Date(now - 8 * 86400000).toISOString(),
    enabled: false,
    type: "clientPak",
    loadOrder: 6,
    tags: ["界面"],
    notes: "",
    sha256: "09fe8b5a2ab2",
    originSource: "local",
    deployed: false,
    description: "精简 HUD 与界面元素",
    conflictCount: 0,
  },
];

let mods = structuredClone(sampleMods);
let settings: AppSettings = {
  scumInstallPath: "X:/SteamLibrary/steamapps/common/SCUM",
  serverInstallPath: "X:/SteamLibrary/steamapps/common/SCUM Server",
  theme: "light",
  launchOptions: {
    log: false,
    fileOpenLog: true,
    noBattlEye: true,
    port: "7042",
  },
  cloud: {
    baseUrls: [],
    activeBaseUrl: "",
    maxDownloadSegments: 16,
  },
  sftpAccounts: [],
  activeSftpAccountId: null,
};

let gameStatus: GameStatus = {
  running: false,
  mode: null,
  pid: null,
  startedAt: null,
};

let runtimeLogs: RuntimeLog[] = [
  {
    id: 1,
    timestamp: new Date(now - 240000).toISOString(),
    level: "info",
    target: "library",
    message: "本地模组扫描完成，共发现 12 个条目",
  },
  {
    id: 2,
    timestamp: new Date(now - 180000).toISOString(),
    level: "info",
    target: "conflict",
    message: "8 个已启用 PAK 未发现资源冲突",
  },
  {
    id: 3,
    timestamp: new Date(now - 90000).toISOString(),
    level: "debug",
    target: "paths",
    message: "客户端路径检测通过",
  },
];

const remoteMods: RemoteMod[] = [
  {
    id: "chest-max-weight",
    name: "Chest Max Weight",
    author: "RuinDream",
    version: "1.6.0",
    description: "提高容器最大承重，适合服务器长期物资储存。",
    fileSize: 43285,
    downloadUrl: "",
    sha256: "f338f15f",
    tags: ["生存", "服务器"],
    updatedAt: new Date(now - 86400000).toISOString(),
    type: "clientPak",
    installed: false,
  },
  {
    id: "vehicle-overhaul",
    name: "Vehicle Overhaul",
    author: "IslandWorks",
    version: "3.2.1",
    description: "载具动力、悬挂与操控参数重制。",
    fileSize: 664797184,
    downloadUrl: "",
    sha256: "ab9e0a11",
    tags: ["载具"],
    updatedAt: new Date(now - 3 * 86400000).toISOString(),
    type: "clientPak",
    installed: true,
  },
  {
    id: "fog-weather-pack",
    name: "Dynamic Fog Weather",
    author: "Northstar",
    version: "1.1.4",
    description: "增加动态海雾与天气过渡。",
    fileSize: 12845056,
    downloadUrl: "",
    sha256: "66c01efe",
    tags: ["天气", "画面"],
    updatedAt: new Date(now - 6 * 86400000).toISOString(),
    type: "clientPak",
    installed: false,
  },
];

const remoteFiles: RemoteFile[] = [
  { name: "~mods", path: "/srv/scum/SCUM/Content/Paks/~mods", isDirectory: true, size: 0, modifiedAt: null },
  { name: "SCUM_WeaponPack_Elite.pak", path: "/srv/scum/SCUM/Content/Paks/~mods/SCUM_WeaponPack_Elite.pak", isDirectory: false, size: 1374389535, modifiedAt: new Date(now - 2 * 86400000).toISOString() },
  { name: "LootBalance_Plus.pak", path: "/srv/scum/SCUM/Content/Paks/~mods/LootBalance_Plus.pak", isDirectory: false, size: 13421772, modifiedAt: new Date(now - 4 * 86400000).toISOString() },
];

export function mockSnapshot(): LibrarySnapshot {
  return structuredClone({
    mods,
    settings,
    gameStatus,
    lastDeployedAt: null,
    lastScannedAt: new Date().toISOString(),
    localModsPath: "W:/hermes/SCUM_Mod_Desk_v3/app-data/~mods",
    clientModsPath: "X:/SteamLibrary/steamapps/common/SCUM/SCUM/Content/Paks/~mods",
  });
}

export async function mockInvoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  await new Promise((resolve) => setTimeout(resolve, 80));
  switch (command) {
    case "get_library_snapshot":
      return mockSnapshot() as T;
    case "scan_library":
      runtimeLogs.unshift({
        id: Date.now(),
        timestamp: new Date().toISOString(),
        level: "info",
        target: "library",
        message: "扫描完成，本地模组状态已刷新",
      });
      return mockSnapshot() as T;
    case "set_mod_enabled": {
      const id = String(args?.id ?? "");
      const enabled = Boolean(args?.enabled);
      mods = mods.map((mod) => (mod.id === id ? { ...mod, enabled } : mod));
      return mockSnapshot() as T;
    }
    case "reorder_mods": {
      const ids = (args?.ids as string[] | undefined) ?? [];
      const byId = new Map(mods.map((mod) => [mod.id, mod]));
      mods = ids
        .map((id, index) => {
          const mod = byId.get(id);
          return mod ? { ...mod, loadOrder: index } : null;
        })
        .filter((mod): mod is ModEntry => mod !== null);
      return mockSnapshot() as T;
    }
    case "update_mod_metadata": {
      const id = String(args?.id ?? "");
      const tags = (args?.tags as string[] | undefined) ?? [];
      const notes = String(args?.notes ?? "");
      mods = mods.map((mod) => (mod.id === id ? { ...mod, tags, notes } : mod));
      return mockSnapshot() as T;
    }
    case "save_settings":
      settings = structuredClone(args?.settings as AppSettings);
      return settings as T;
    case "detect_paths":
      return {
        scumInstallPath: "X:/SteamLibrary/steamapps/common/SCUM",
        serverInstallPath: "X:/SteamLibrary/steamapps/common/SCUM Server",
      } as T;
    case "launch_game":
      gameStatus = {
        running: true,
        mode: String(args?.mode ?? "client") as GameStatus["mode"],
        pid: 31416,
        startedAt: new Date().toISOString(),
      };
      return gameStatus as T;
    case "kill_game":
      gameStatus = { running: false, mode: null, pid: null, startedAt: null };
      return gameStatus as T;
    case "fetch_cloud_catalog":
      return structuredClone(remoteMods) as T;
    case "download_remote_mod":
      return { message: "演示环境已完成下载" } as T;
    case "get_logs":
      return structuredClone(runtimeLogs) as T;
    case "clear_logs":
      runtimeLogs = [];
      return undefined as T;
    case "get_app_info":
      return {
        version: "3.0.0-preview",
        dataRoot: "W:/hermes/SCUM_Mod_Desk_v3/app-data",
        secretsPath: "W:/hermes/SCUM_Mod_Desk_v3/app-data/secrets",
        platform: "browser-preview",
        edition: "server",
      } as AppInfo as T;
    case "check_app_update":
      return {
        configured: true,
        currentVersion: "3.0.0",
        available: true,
        version: "3.0.1",
        publishedAt: new Date(now - 2 * 60 * 60 * 1000).toISOString(),
        notes:
          "提高列表、检查器与设置页的字号可读性。\n优化 1100×720 窗口下的表格列宽与更新提示。\n修复安装器签名版本校验链路。",
        size: 89456640,
      } as AppUpdateInfo as T;
    case "install_app_update":
      await new Promise((resolve) => setTimeout(resolve, 900));
      return { message: "演示环境已完成更新校验" } as T;
    case "list_remote_files":
      return structuredClone(remoteFiles) as T;
    case "test_sftp_connection":
      return {
        ok: true,
        message: "连接成功（演示环境）",
        detectedModsPath: "/srv/scum/SCUM/Content/Paks/~mods",
        hostKeyFingerprint: "SHA256:demo-fingerprint",
        requiresTrust: false,
      } as T;
    case "trust_sftp_host":
      return {
        ok: true,
        message: "已信任服务器主机密钥（演示环境）",
        detectedModsPath: null,
        hostKeyFingerprint: String(args?.fingerprint ?? "SHA256:demo-fingerprint"),
        requiresTrust: false,
      } as T;
    case "save_sftp_account": {
      const account = args?.account as
        | { name: string; host: string; port: number; username: string; modsPath: string }
        | undefined;
      if (!account) throw new Error("Missing account");
      const existing = settings.sftpAccounts.find((item) => item.name === account.name);
      const saved = {
        ...account,
        id: existing?.id ?? crypto.randomUUID(),
        hasPassword: Boolean(args?.password) || Boolean(existing?.hasPassword),
      };
      settings = {
        ...settings,
        sftpAccounts: existing
          ? settings.sftpAccounts.map((item) => (item.id === existing.id ? saved : item))
          : [...settings.sftpAccounts, saved],
        activeSftpAccountId: saved.id,
      };
      return mockSnapshot() as T;
    }
    case "upload_server_mods":
      return { uploaded: 0, message: "演示环境未执行上传" } as T;
    case "import_mods":
      return { imported: 0, skipped: 0, message: "演示环境不执行真实文件导入" } as T;
    case "open_path":
    case "open_mod_folder":
    case "window_minimize":
    case "window_toggle_maximize":
    case "window_close":
      return undefined as T;
    default:
      throw new Error(`Mock command not implemented: ${command}`);
  }
}
