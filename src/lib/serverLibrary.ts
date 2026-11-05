import type {
  ConflictGroup,
  LibrarySnapshot,
  ModEntry,
  SftpConflictReport,
  SftpConnectionResult,
  SftpManagedManifest,
} from "../types";

export interface ServerLibraryState {
  order: string[];
  enabled: Record<string, boolean>;
  winners: Record<string, string>;
  /** 待上传的删除动作：文件仍留在服务器上，上传时才移入备份目录。 */
  deleted: string[];
}

interface ServerLibraryLabels {
  mergedName: string;
  mergedTag: string;
  mergedDescription: (sources: string[]) => string;
  disabledTag: string;
  disabledDescription: string;
  deletedTag: string;
  deletedDescription: string;
}

const STORAGE_PREFIX = "scum-server-library-v1:";

function serverPaths(scan: SftpConnectionResult): string[] {
  const paths = new Set([...scan.pakMods, ...scan.ue4ssMods].map((file) => file.path));
  // 被移进备份批次的条目仍算「可用路径」：否则 normalize 会把禁用/删除状态删掉，
  // 下一次 apply 先 restore 再按 disabled 列表处理时，用户关掉的模组会被静默重新启用。
  // merged / previous-merged / signature 不并进来——它们是融合产物，不是独立模组。
  for (const backup of scan.managedManifest?.backups ?? []) {
    if (backup.reason === "disabled" || backup.reason === "deleted") {
      paths.add(backup.originalPath);
    }
  }
  return [...paths];
}

function displayServerPakName(fileName: string): string {
  const match = fileName.match(/^\d{3,}_(.+\.pak)$/i);
  return match?.[1] ?? fileName;
}

export function normalizeServerLibraryState(
  value: unknown,
  scan: SftpConnectionResult,
): ServerLibraryState {
  const input =
    value && typeof value === "object"
      ? (value as Partial<ServerLibraryState>)
      : {};
  const available = serverPaths(scan);
  const availableSet = new Set(available);
  const requestedOrder = Array.isArray(input.order)
    ? input.order.filter(
        (path, index, list): path is string =>
          typeof path === "string" &&
          availableSet.has(path) &&
          list.indexOf(path) === index,
      )
    : [];
  for (const path of available) {
    if (!requestedOrder.includes(path)) requestedOrder.push(path);
  }
  const enabled: Record<string, boolean> = {};
  for (const path of available) {
    enabled[path] = input.enabled?.[path] !== false;
  }
  const winners =
    input.winners && typeof input.winners === "object"
      ? Object.fromEntries(
          Object.entries(input.winners).filter(
            (entry): entry is [string, string] =>
              typeof entry[0] === "string" && typeof entry[1] === "string",
          ),
        )
      : {};
  const deleted = Array.isArray(input.deleted)
    ? input.deleted.filter(
        (path): path is string =>
          typeof path === "string" && availableSet.has(path),
      )
    : [];
  return { order: requestedOrder, enabled, winners, deleted };
}

export function readStoredServerLibraryState(
  accountId: string,
  scan: SftpConnectionResult,
): ServerLibraryState {
  if (typeof localStorage === "undefined") {
    return normalizeServerLibraryState(null, scan);
  }
  try {
    const raw = localStorage.getItem(`${STORAGE_PREFIX}${accountId}`);
    return normalizeServerLibraryState(raw ? JSON.parse(raw) : null, scan);
  } catch {
    return normalizeServerLibraryState(null, scan);
  }
}

export function storeServerLibraryState(
  accountId: string,
  state: ServerLibraryState,
  scan: SftpConnectionResult,
) {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(
    `${STORAGE_PREFIX}${accountId}`,
    JSON.stringify(normalizeServerLibraryState(state, scan)),
  );
}

export function serverLibraryDisabledPaths(state: ServerLibraryState): string[] {
  return Object.entries(state.enabled)
    .filter(([, enabled]) => !enabled)
    .map(([path]) => path);
}

/** 上一轮被禁用、但用户这次打开了开关的路径：必须显式告诉后端，否则它会继续继承禁用。 */
export function serverLibraryReleasedPaths(
  state: ServerLibraryState,
  scan: SftpConnectionResult,
): string[] {
  return (scan.managedManifest?.backups ?? [])
    .filter((item) => item.reason === "disabled")
    .map((item) => item.originalPath)
    .filter((path) => state.enabled[path] === true);
}

export function buildServerLibrarySnapshot({
  base,
  scan,
  report,
  state,
  manifest,
  notes,
  labels,
  now = new Date().toISOString(),
}: {
  base: LibrarySnapshot;
  scan: SftpConnectionResult;
  report: SftpConflictReport | null;
  state: ServerLibraryState;
  manifest: SftpManagedManifest | null;
  notes?: Record<string, string>;
  labels: ServerLibraryLabels;
  now?: string;
}): { snapshot: LibrarySnapshot; state: ServerLibraryState; conflicts: ConflictGroup[] } {
  const normalized = normalizeServerLibraryState(state, scan);
  const orderIndex = new Map(normalized.order.map((path, index) => [path, index]));
  const mergedPath = manifest?.mergedPath ?? null;
  const deleted = new Set(normalized.deleted);
  const files = [
    ...scan.pakMods.map((file) => ({ ...file, type: "clientPak" as const })),
    ...scan.ue4ssMods.map((file) => ({ ...file, type: "ue4ssMod" as const })),
  ]
    .filter((file) => !deleted.has(file.path))
    .sort(
    (left, right) =>
      (orderIndex.get(left.path) ?? Number.MAX_SAFE_INTEGER) -
        (orderIndex.get(right.path) ?? Number.MAX_SAFE_INTEGER) ||
      left.name.localeCompare(right.name) ||
      left.path.localeCompare(right.path),
  );

  const mods: ModEntry[] = files.map((file, loadOrder) => {
    const isMerged = Boolean(mergedPath && file.path === mergedPath);
    const sourceNames = isMerged
      ? (manifest?.sources ?? []).map((source) => source.name)
      : [];
    return {
      id: file.path,
      name: isMerged ? labels.mergedName : displayServerPakName(file.name),
      author: "",
      fileName: file.name,
      filePath: file.path,
      fileSize: file.size,
      lastModified: file.modifiedAt ?? now,
      enabled: isMerged || normalized.enabled[file.path] !== false,
      type: file.type,
      loadOrder,
      tags: isMerged ? [labels.mergedTag] : [],
      notes: isMerged ? "" : (notes?.[file.path] ?? ""),
      sha256: "",
      originSource: "cloud",
      deployed: false,
      description: isMerged ? labels.mergedDescription(sourceNames) : "",
      conflictCount: 0,
      fileCount: 0,
      overriddenFileCount: 0,
      overridingFileCount: 0,
      fullyOverridden: false,
      updateVersion: null,
      coverUrl: null,
      duplicateCount: 0,
      duplicateAliases: [],
    };
  });
  // 备份批次里的禁用/已删除条目：上传后它们不在扫描列表里，但仍要让用户看见并可以拨回开关。
  const backedUpPaths = new Set<string>();
  for (const backup of manifest?.backups ?? []) {
    if (backup.reason !== "disabled" && backup.reason !== "deleted") continue;
    backedUpPaths.add(backup.originalPath);
    if (mods.some((mod) => mod.id === backup.originalPath)) continue;
    const isPak = backup.name.toLowerCase().endsWith(".pak");
    mods.push({
      id: backup.originalPath,
      name: displayServerPakName(backup.name),
      author: "",
      fileName: backup.name,
      filePath: backup.originalPath,
      fileSize: 0,
      lastModified: manifest?.createdAt ?? now,
      enabled: false,
      type: isPak ? "clientPak" : "ue4ssMod",
      loadOrder: orderIndex.get(backup.originalPath) ?? mods.length,
      tags: [backup.reason === "deleted" ? labels.deletedTag : labels.disabledTag],
      notes: notes?.[backup.originalPath] ?? "",
      sha256: "",
      originSource: "cloud",
      deployed: false,
      description:
        backup.reason === "deleted" ? labels.deletedDescription : labels.disabledDescription,
      conflictCount: 0,
      fileCount: 0,
      overriddenFileCount: 0,
      overridingFileCount: 0,
      fullyOverridden: false,
      updateVersion: null,
      coverUrl: null,
      duplicateCount: 0,
      duplicateAliases: [],
    });
  }
  // 备份中的条目排在启用中的模组之后，不要混进正常列表里。
  mods.sort((left, right) => {
    const leftBacked = backedUpPaths.has(left.id) ? 1 : 0;
    const rightBacked = backedUpPaths.has(right.id) ? 1 : 0;
    return leftBacked - rightBacked || left.loadOrder - right.loadOrder;
  });
  mods.forEach((mod, index) => {
    mod.loadOrder = index;
  });
  const modsById = new Map(mods.map((mod) => [mod.id, mod]));
  const conflicts: ConflictGroup[] = [];
  const stats = new Map<
    string,
    { overridden: number; overriding: number }
  >();

  for (const sourceGroup of report?.groups ?? []) {
    const owners = sourceGroup.owners
      .flatMap((owner) => {
        const mod = modsById.get(owner.path);
        return mod?.enabled
          ? [
              {
                id: mod.id,
                name: mod.name,
                loadOrder: mod.loadOrder,
                type: mod.type,
              },
            ]
          : [];
      })
      .sort(
        (left, right) =>
          left.loadOrder - right.loadOrder ||
          left.name.localeCompare(right.name) ||
          left.id.localeCompare(right.id),
      );
    if (owners.length < 2) continue;
    const key = sourceGroup.resourcePath.toLocaleLowerCase();
    const defaultWinner = owners[owners.length - 1].id;
    const selectedWinner = owners.some(
      (owner) => owner.id === normalized.winners[key],
    )
      ? normalized.winners[key]
      : null;
    const winnerId = selectedWinner ?? defaultWinner;
    conflicts.push({
      key,
      paths: [sourceGroup.resourcePath],
      owners,
      defaultWinnerId: defaultWinner,
      winnerId,
      selectedWinnerId: selectedWinner,
    });
    for (const owner of owners) {
      const current = stats.get(owner.id) ?? {
        overridden: 0,
        overriding: 0,
      };
      if (owner.id === winnerId) current.overriding += 1;
      else current.overridden += 1;
      stats.set(owner.id, current);
    }
  }

  for (const mod of mods) {
    const itemStats = stats.get(mod.id);
    if (!itemStats) continue;
    mod.overriddenFileCount = itemStats.overridden;
    mod.overridingFileCount = itemStats.overriding;
    mod.conflictCount = itemStats.overridden + itemStats.overriding;
  }

  normalized.winners = Object.fromEntries(
    conflicts.flatMap((group) =>
      group.selectedWinnerId &&
      group.selectedWinnerId !== group.defaultWinnerId
        ? [[group.key, group.selectedWinnerId]]
        : [],
    ),
  );

  return {
    snapshot: {
      mods,
      conflicts,
      settings: base.settings,
      gameStatus: { running: false, mode: null, pid: null, startedAt: null },
      lastDeployedAt: manifest?.createdAt ?? null,
      lastScannedAt: now,
      localModsPath: scan.detectedModsPath ?? "",
      clientModsPath: scan.detectedModsPath ?? "",
    },
    state: normalized,
    conflicts,
  };
}
