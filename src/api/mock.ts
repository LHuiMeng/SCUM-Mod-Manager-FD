import type {
  AppInfo,
  AppSettings,
  AppUpdateInfo,
  ConflictGroup,
  GameStatus,
  ImportConflict,
  Language,
  LibrarySnapshot,
  LocaleBundle,
  ModEntry,
  RemoteFile,
  RemoteMod,
  RuntimeLog,
} from "../types";

const now = Date.now();

function mockCover(kind: "weapons" | "vehicles" | "storage" | "weather") {
  const themes = {
    weapons: { sky: "#5c3b2c", ground: "#b06a42", accent: "#d18a5f" },
    vehicles: { sky: "#405d59", ground: "#8b9b76", accent: "#d9a35f" },
    storage: { sky: "#5a5247", ground: "#a78358", accent: "#d9b26f" },
    weather: { sky: "#4b5862", ground: "#84919a", accent: "#d7c5a2" },
  }[kind];
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360"><rect width="640" height="360" fill="${themes.sky}"/><circle cx="510" cy="92" r="58" fill="${themes.accent}" opacity=".34"/><path d="M0 270 150 170l105 67 120-104 265 147v80H0z" fill="${themes.ground}"/><path d="M0 304 185 225l105 51 188-82 162 84v82H0z" fill="${themes.accent}" opacity=".24"/><text x="34" y="315" fill="#f7f0e5" font-family="sans-serif" font-size="28" font-weight="600">SCUM MOD</text></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

const sampleMods: ModEntry[] = [
  {
    id: "scum_weaponpack_elite",
    name: "SCUM_WeaponPack_Elite",
    author: "RuinDream",
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
    fileCount: 18,
    overriddenFileCount: 0,
    overridingFileCount: 0,
    fullyOverridden: false,
    coverUrl: mockCover("weapons"),
    duplicateCount: 1,
    duplicateAliases: ["~mods/SCUM_WeaponPack_Elite Copy.pak"],
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
    fileCount: 1,
    overriddenFileCount: 0,
    overridingFileCount: 0,
    fullyOverridden: false,
    coverUrl: mockCover("vehicles"),
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
    fileCount: 9,
    overriddenFileCount: 0,
    overridingFileCount: 0,
    fullyOverridden: false,
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
    fileCount: 20,
    overriddenFileCount: 0,
    overridingFileCount: 0,
    fullyOverridden: false,
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
    fileCount: 12,
    overriddenFileCount: 0,
    overridingFileCount: 0,
    fullyOverridden: false,
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
    fileCount: 0,
    overriddenFileCount: 0,
    overridingFileCount: 0,
    fullyOverridden: false,
    coverUrl: mockCover("storage"),
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
    fileCount: 3,
    overriddenFileCount: 0,
    overridingFileCount: 0,
    fullyOverridden: false,
  },
];

let mods = structuredClone(sampleMods);
let conflictWinners = new Map<string, string>();
let conflicts: ConflictGroup[] = [];

const mockConflictDefinitions = [
  {
    key: "scum/content/assets/weapons/shared",
    paths: [
      "SCUM/Content/Assets/Weapons/Shared.uasset",
      "SCUM/Content/Assets/Weapons/Shared.uexp",
    ],
    ownerIds: ["scum_weaponpack_elite", "lootbalance_plus"],
  },
  {
    key: "scum/content/assets/vehicles/wheel",
    paths: ["SCUM/Content/Assets/Vehicles/Wheel.uasset"],
    ownerIds: ["vehicleoverhaul_v3", "mapextensions_north"],
  },
];

function recomputeMockConflicts() {
  mods = mods.map((mod) => ({
    ...mod,
    conflictCount: 0,
    overriddenFileCount: 0,
    overridingFileCount: 0,
    fullyOverridden: false,
  }));
  conflicts = mockConflictDefinitions.flatMap((definition) => {
    const owners = definition.ownerIds
      .map((id) => mods.find((mod) => mod.id === id))
      .filter(
        (mod): mod is ModEntry =>
          Boolean(mod && mod.enabled && mod.type === "clientPak"),
      )
      .sort(
        (left, right) =>
          left.loadOrder - right.loadOrder || left.id.localeCompare(right.id),
      );
    if (owners.length < 2) {
      conflictWinners.delete(definition.key);
      return [];
    }
    const defaultWinner = owners[owners.length - 1];
    const selectedCandidate = conflictWinners.get(definition.key);
    const selectedOwner = selectedCandidate
      ? owners.find((owner) => owner.id === selectedCandidate)
      : undefined;
    if (selectedCandidate && !selectedOwner) {
      conflictWinners.delete(definition.key);
    }
    const selected = selectedOwner?.id;
    const winner = selectedOwner || defaultWinner;
    if (!winner) return [];
    return [
      {
        key: definition.key,
        paths: [...definition.paths],
        owners: owners.map((owner) => ({
          id: owner.id,
          name: owner.name,
          loadOrder: owner.loadOrder,
          type: owner.type,
        })),
        defaultWinnerId: defaultWinner.id,
        winnerId: winner.id,
        selectedWinnerId: selected ?? null,
      },
    ];
  });
  const stats = new Map<
    string,
    { overridden: number; overriding: number }
  >();
  for (const group of conflicts) {
    for (const owner of group.owners) {
      const current = stats.get(owner.id) ?? { overridden: 0, overriding: 0 };
      if (owner.id === group.winnerId) {
        current.overriding += group.paths.length;
      } else {
        current.overridden += group.paths.length;
      }
      stats.set(owner.id, current);
    }
  }
  mods = mods.map((mod) => {
    const current = stats.get(mod.id) ?? { overridden: 0, overriding: 0 };
    return {
      ...mod,
      overriddenFileCount: current.overridden,
      overridingFileCount: current.overriding,
      conflictCount: current.overridden + current.overriding,
      fullyOverridden:
        mod.type === "clientPak" &&
        mod.fileCount > 0 &&
        current.overridden === mod.fileCount,
    };
  });
}
let settings: AppSettings = {
  scumInstallPath: "X:/SteamLibrary/steamapps/common/SCUM",
  serverInstallPath: "X:/SteamLibrary/steamapps/common/SCUM Server",
  theme: "light",
  language: "zh-CN",
  keepDeployedModsOnExit: false,
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
    coverUrl: mockCover("storage"),
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
    coverUrl: mockCover("vehicles"),
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
    coverUrl: mockCover("weather"),
  },
];

let remoteFiles: RemoteFile[] = [
  { name: "~mods", path: "/srv/scum/SCUM/Content/Paks/~mods", isDirectory: true, size: 0, modifiedAt: null },
  { name: "SCUM_WeaponPack_Elite.pak", path: "/srv/scum/SCUM/Content/Paks/~mods/SCUM_WeaponPack_Elite.pak", isDirectory: false, size: 1374389535, modifiedAt: new Date(now - 2 * 86400000).toISOString() },
  { name: "LootBalance_Plus.pak", path: "/srv/scum/SCUM/Content/Paks/~mods/LootBalance_Plus.pak", isDirectory: false, size: 13421772, modifiedAt: new Date(now - 4 * 86400000).toISOString() },
];
let remoteManagedFiles: RemoteFile[] | null = null;

let remoteUe4ssMods: RemoteFile[] = [
  {
    name: "BPModLoaderMod",
    path: "/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods/BPModLoaderMod",
    isDirectory: true,
    size: 0,
    modifiedAt: new Date(now - 3 * 86400000).toISOString(),
  },
  {
    name: "SCUMTweaks",
    path: "/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods/SCUMTweaks",
    isDirectory: true,
    size: 0,
    modifiedAt: new Date(now - 5 * 86400000).toISOString(),
  },
];

let remoteNotes: Record<string, string> = {
  "/srv/scum/SCUM/Content/Paks/~mods/SCUM_WeaponPack_Elite.pak":
    "服务器主武器包，更新前先备份。",
};

export function mockSnapshot(): LibrarySnapshot {
  recomputeMockConflicts();
  return structuredClone({
    mods,
    conflicts,
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
      recomputeMockConflicts();
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
      recomputeMockConflicts();
      return mockSnapshot() as T;
    }
    case "update_mod_metadata": {
      const id = String(args?.id ?? "");
      const tags = (args?.tags as string[] | undefined) ?? [];
      const notes = String(args?.notes ?? "");
      mods = mods.map((mod) => (mod.id === id ? { ...mod, tags, notes } : mod));
      return mockSnapshot() as T;
    }
    case "delete_mod": {
      if (gameStatus.running) {
        throw new Error("游戏运行期间不能删除模组");
      }
      const id = String(args?.id ?? "");
      const target = mods.find((mod) => mod.id === id);
      if (!target) throw new Error("找不到指定模组");
      mods = mods
        .filter((mod) => mod.id !== id)
        .map((mod, index) => ({ ...mod, loadOrder: index }));
      recomputeMockConflicts();
      runtimeLogs.unshift({
        id: Date.now(),
        timestamp: new Date().toISOString(),
        level: "info",
        target: "library",
        message: `已将模组 ${target.name} 移入删除备份`,
      });
      return mockSnapshot() as T;
    }
    case "save_conflict_winners": {
      const winners = (args?.winners as Record<string, string> | undefined) ?? {};
      for (const [key, winner] of Object.entries(winners)) {
        const definition = mockConflictDefinitions.find(
          (item) => item.key === key,
        );
        if (!definition) throw new Error(`冲突组不存在：${key}`);
        const enabledOwners = definition.ownerIds.filter((id) => {
          const mod = mods.find((item) => item.id === id);
          return Boolean(mod?.enabled && mod.type === "clientPak");
        });
        if (enabledOwners.length < 2 || !enabledOwners.includes(winner)) {
          throw new Error(`所选模组不属于冲突组 ${key}`);
        }
      }
      conflictWinners = new Map(Object.entries(winners));
      recomputeMockConflicts();
      return mockSnapshot() as T;
    }
    case "save_settings":
      settings = structuredClone(args?.settings as AppSettings);
      return settings as T;
    case "set_theme": {
      settings = { ...settings, theme: String(args?.theme ?? "light") as AppSettings["theme"] };
      return undefined as T;
    }
    case "set_language": {
      const language = (args?.language === "en-US" ? "en-US" : "zh-CN") as Language;
      settings = { ...settings, language };
      return undefined as T;
    }
    case "get_locale": {
      const language = (args?.language === "en-US" ? "en-US" : "zh-CN") as Language;
      return {
        language,
        messages: {},
        source: "bundled",
        localeDirectory: "W:/hermes/SCUM_Mod_Desk_v3/app-data/locales",
        warnings: [],
      } as LocaleBundle as T;
    }
    case "get_locales":
      return (["zh-CN", "en-US"] as Language[]).map((language) => ({
        language,
        messages: {},
        source: "bundled",
        localeDirectory: "W:/hermes/SCUM_Mod_Desk_v3/app-data/locales",
        warnings: [],
      })) as T;
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
    case "download_sftp_file":
      return {
        message: `演示环境已下载 ${String(args?.path ?? "").split("/").pop() ?? "文件"}`,
        path: String(args?.localPath ?? ""),
      } as T;
    case "test_sftp_connection":
      return {
        ok: true,
        message: "连接成功（演示环境）",
        detectedModsPath: "/srv/scum/SCUM/Content/Paks/~mods",
        detectedUe4ssPath: "/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods",
        pakMods: structuredClone(
          remoteFiles.filter((file) => !file.isDirectory && file.name.endsWith(".pak")),
        ),
        ue4ssMods: structuredClone(remoteUe4ssMods),
        scannedDirectories: 9,
        homePath: "/home/modder",
        managedManifest: remoteFiles.some((file) =>
          file.name.includes("SCUM_Mod_Desk_Merged"),
        )
          ? {
              version: 1,
              createdAt: now,
              mergedPath:
                "/srv/scum/SCUM/Content/Paks/~mods/999_SCUM_Mod_Desk_Merged.pak",
              mergedName: "999_SCUM_Mod_Desk_Merged.pak",
              sources: (remoteManagedFiles ?? [])
                .filter((file) => file.name.endsWith(".pak"))
                .slice(0, 2)
                .map((file) => ({ name: file.name, path: file.path })),
              backups: [],
              renames: [],
              createdPaths: [],
              winners: {},
            }
          : null,
        hostKeyFingerprint: "SHA256:demo-fingerprint",
        requiresTrust: false,
      } as T;
    case "trust_sftp_host":
      return {
        ok: true,
        message: "已信任服务器主机密钥（演示环境）",
        detectedModsPath: null,
        detectedUe4ssPath: null,
        pakMods: [],
        ue4ssMods: [],
        scannedDirectories: 0,
        homePath: null,
        managedManifest: null,
        hostKeyFingerprint: String(args?.fingerprint ?? "SHA256:demo-fingerprint"),
        requiresTrust: false,
      } as T;
    case "save_sftp_account": {
      const account = args?.account as
        | {
            name: string;
            host: string;
            port: number;
            username: string;
            modsPath: string;
            ue4ssPath: string;
          }
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
    case "rename_sftp_entry": {
      const path = String(args?.path ?? "");
      const newName = String(args?.newName ?? "").trim();
      const collection = remoteFiles.some((file) => file.path === path)
        ? remoteFiles
        : remoteUe4ssMods;
      const item = collection.find((file) => file.path === path);
      if (!item || !newName || /[\\/]/.test(newName)) {
        throw new Error("无法重命名远端模组");
      }
      const parent = path.slice(0, path.lastIndexOf("/"));
      const nextPath = `${parent}/${newName}`;
      item.name = newName;
      item.path = nextPath;
      if (remoteNotes[path]) {
        remoteNotes[nextPath] = remoteNotes[path];
        delete remoteNotes[path];
      }
      return { message: `已重命名为 ${newName}`, path: nextPath } as T;
    }
    case "delete_sftp_entry": {
      const path = String(args?.path ?? "");
      remoteFiles = remoteFiles.filter(
        (file) => file.path !== path && !file.path.startsWith(`${path}/`),
      );
      remoteUe4ssMods = remoteUe4ssMods.filter(
        (file) => file.path !== path && !file.path.startsWith(`${path}/`),
      );
      remoteNotes = Object.fromEntries(
        Object.entries(remoteNotes).filter(
          ([notePath]) => notePath !== path && !notePath.startsWith(`${path}/`),
        ),
      );
      return { message: "已删除远端模组", path } as T;
    }
    case "get_sftp_remote_notes":
      return structuredClone(remoteNotes) as T;
    case "save_sftp_remote_note": {
      const path = String(args?.path ?? "");
      const note = String(args?.note ?? "");
      if (note.trim()) remoteNotes[path] = note;
      else delete remoteNotes[path];
      return structuredClone(remoteNotes) as T;
    }
    case "analyze_sftp_conflicts": {
      const pakMods = remoteFiles.filter(
        (file) => !file.isDirectory && file.name.endsWith(".pak"),
      );
      const groups =
        pakMods.length >= 2
          ? [
              {
                resourcePath: "SCUM/Content/Items/Weapons/WeaponConfig",
                owners: pakMods.slice(0, 2).map((file) => ({
                  name: file.name,
                  path: file.path,
                  kind: "pak",
                })),
              },
            ]
          : [];
      return {
        groups,
        analyzedMods: pakMods.length,
        skippedMods: 0,
        message: groups.length
          ? `已分析 ${pakMods.length} 个远端 PAK，发现 ${groups.length} 组资源冲突`
          : `已分析 ${pakMods.length} 个远端 PAK，未发现资源冲突`,
      } as T;
    }
    case "apply_sftp_mod_layout": {
      const pakMods = remoteFiles.filter(
        (file) => !file.isDirectory && file.name.endsWith(".pak"),
      );
      const sources = pakMods.slice(0, 2).map((file) => ({
        name: file.name,
        path: file.path,
      }));
      if (sources.length > 0) {
        remoteManagedFiles = structuredClone(remoteFiles);
        remoteFiles = [
          ...remoteFiles.filter(
            (file) => !sources.some((source) => source.path === file.path),
          ),
          {
            name: "999_SCUM_Mod_Desk_Merged.pak",
            path: "/srv/scum/SCUM/Content/Paks/~mods/999_SCUM_Mod_Desk_Merged.pak",
            isDirectory: false,
            size: 1400000000,
            modifiedAt: new Date().toISOString(),
          },
        ];
      }
      return {
        message: "演示环境已备份冲突模组并上传合并包",
        manifest: {
          version: 1,
          createdAt: new Date().toISOString(),
          mergedPath: sources.length
            ? "/srv/scum/SCUM/Content/Paks/~mods/999_SCUM_Mod_Desk_Merged.pak"
            : null,
          mergedName: sources.length ? "999_SCUM_Mod_Desk_Merged.pak" : null,
          sources,
          backups: sources.map((source) => ({
            name: source.name,
            originalPath: source.path,
            backupPath: `/srv/scum/SCUM/Content/Paks/~mods/_SCUM_Mod_Desk_Backups/${source.name}.bak`,
            reason: "merged",
          })),
          renames: [],
          createdPaths: [],
          winners: (args?.winners as Record<string, string> | undefined) ?? {},
        },
      } as T;
    }
    case "restore_sftp_mod_layout":
      if (remoteManagedFiles) {
        remoteFiles = structuredClone(remoteManagedFiles);
        remoteManagedFiles = null;
      }
      return {
        message: "演示环境已恢复服务器原始模组",
        path: "/srv/scum/SCUM/Content/Paks/~mods",
      } as T;
    case "inspect_mod_import": {
      const paths = (args?.paths as string[] | undefined) ?? [];
      const conflicts = paths.flatMap((sourcePath) => {
        const fileName = sourcePath.split(/[\\/]/).pop() ?? sourcePath;
        const existing = mods.find(
          (mod) => mod.fileName.toLowerCase() === fileName.toLowerCase(),
        );
        return existing
          ? [{
              sourcePath,
              fileName,
              targetPath: existing.filePath,
            } satisfies ImportConflict]
          : [];
      });
      return conflicts as T;
    }
    case "import_mods": {
      const paths = (args?.paths as string[] | undefined) ?? [];
      const replaceExisting = Boolean(args?.replaceExisting);
      if (!replaceExisting) {
        return { imported: 0, skipped: paths.length, message: "演示环境不执行真实文件导入" } as T;
      }
      const names = new Set(
        paths.map((sourcePath) => (sourcePath.split(/[\\/]/).pop() ?? "").toLowerCase()),
      );
      let replaced = 0;
      mods = mods.map((mod) => {
        if (!names.has(mod.fileName.toLowerCase())) return mod;
        replaced += 1;
        return { ...mod, lastModified: new Date().toISOString() };
      });
      recomputeMockConflicts();
      return {
        imported: replaced,
        skipped: 0,
        message: `演示环境已覆盖 ${replaced} 个同名条目`,
      } as T;
    }
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
