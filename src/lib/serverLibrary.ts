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
}

interface ServerLibraryLabels {
  mergedName: string;
  mergedTag: string;
  mergedDescription: (sources: string[]) => string;
}

const STORAGE_PREFIX = "scum-server-library-v1:";

function serverPaths(scan: SftpConnectionResult): string[] {
  return [...scan.pakMods, ...scan.ue4ssMods].map((file) => file.path);
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
  return { order: requestedOrder, enabled, winners };
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

export function buildServerLibrarySnapshot({
  base,
  scan,
  report,
  state,
  manifest,
  labels,
  now = new Date().toISOString(),
}: {
  base: LibrarySnapshot;
  scan: SftpConnectionResult;
  report: SftpConflictReport | null;
  state: ServerLibraryState;
  manifest: SftpManagedManifest | null;
  labels: ServerLibraryLabels;
  now?: string;
}): { snapshot: LibrarySnapshot; state: ServerLibraryState; conflicts: ConflictGroup[] } {
  const normalized = normalizeServerLibraryState(state, scan);
  const orderIndex = new Map(normalized.order.map((path, index) => [path, index]));
  const mergedPath = manifest?.mergedPath ?? null;
  const files = [
    ...scan.pakMods.map((file) => ({ ...file, type: "clientPak" as const })),
    ...scan.ue4ssMods.map((file) => ({ ...file, type: "ue4ssMod" as const })),
  ].sort(
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
      notes: "",
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
