export type ServerPanelId = "account" | "files" | "viewer";

export interface ServerLayout {
  order: ServerPanelId[];
  heights: Record<ServerPanelId, number>;
}

export const SERVER_PANEL_ORDER: ServerPanelId[] = ["account", "files", "viewer"];

const PANEL_HEIGHT_LIMITS: Record<ServerPanelId, { min: number; max: number }> = {
  account: { min: 260, max: 760 },
  files: { min: 300, max: 760 },
  viewer: { min: 260, max: 760 },
};

export const DEFAULT_SERVER_LAYOUT: ServerLayout = {
  order: [...SERVER_PANEL_ORDER],
  heights: {
    account: 300,
    files: 330,
    viewer: 320,
  },
};

const STORAGE_KEY = "scum-server-layout-v1";

export function clampServerPanelHeight(panel: ServerPanelId, value: number): number {
  const limits = PANEL_HEIGHT_LIMITS[panel];
  if (!Number.isFinite(value)) return DEFAULT_SERVER_LAYOUT.heights[panel];
  return Math.round(Math.min(limits.max, Math.max(limits.min, value)));
}

export function normalizeServerLayout(value: unknown): ServerLayout {
  const input =
    value && typeof value === "object" ? (value as Partial<ServerLayout>) : {};
  const order = Array.isArray(input.order)
    ? input.order.filter(
        (panel, index, list): panel is ServerPanelId =>
          SERVER_PANEL_ORDER.includes(panel as ServerPanelId) &&
          list.indexOf(panel) === index,
      )
    : [];
  for (const panel of SERVER_PANEL_ORDER) {
    if (!order.includes(panel)) order.push(panel);
  }
  const heights = {} as Record<ServerPanelId, number>;
  for (const panel of SERVER_PANEL_ORDER) {
    const candidate = input.heights?.[panel];
    heights[panel] = clampServerPanelHeight(
      panel,
      typeof candidate === "number" ? candidate : DEFAULT_SERVER_LAYOUT.heights[panel],
    );
  }
  return { order, heights };
}

export function moveServerPanel(
  order: ServerPanelId[],
  panel: ServerPanelId,
  target: ServerPanelId,
): ServerPanelId[] {
  if (panel === target) return [...order];
  const next = order.filter((item) => item !== panel);
  const targetIndex = next.indexOf(target);
  if (targetIndex < 0) return [...order];
  next.splice(targetIndex, 0, panel);
  return next;
}

export function moveServerPanelBy(
  order: ServerPanelId[],
  panel: ServerPanelId,
  delta: number,
): ServerPanelId[] {
  const index = order.indexOf(panel);
  const targetIndex = index + delta;
  if (index < 0 || targetIndex < 0 || targetIndex >= order.length) return [...order];
  const next = [...order];
  [next[index], next[targetIndex]] = [next[targetIndex], next[index]];
  return next;
}

export function readStoredServerLayout(): ServerLayout {
  if (typeof localStorage === "undefined") return normalizeServerLayout(DEFAULT_SERVER_LAYOUT);
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return normalizeServerLayout(raw ? JSON.parse(raw) : DEFAULT_SERVER_LAYOUT);
  } catch {
    return normalizeServerLayout(DEFAULT_SERVER_LAYOUT);
  }
}

export function storeServerLayout(layout: ServerLayout) {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(STORAGE_KEY, JSON.stringify(normalizeServerLayout(layout)));
}
