export type ServerPanelId = "account" | "files" | "viewer";

export interface ServerPanelRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface ServerLayout {
  rects: Record<ServerPanelId, ServerPanelRect>;
}

export interface ServerStageSize {
  width: number;
  height: number;
}

export const SERVER_PANEL_ORDER: ServerPanelId[] = ["account", "files", "viewer"];

export const SERVER_PANEL_MIN_SIZE: Record<
  ServerPanelId,
  { width: number; height: number }
> = {
  account: { width: 280, height: 240 },
  files: { width: 320, height: 260 },
  viewer: { width: 420, height: 280 },
};

export const DEFAULT_SERVER_LAYOUT: ServerLayout = {
  rects: {
    account: { x: 0.01, y: 0.01, w: 0.4, h: 0.47 },
    files: { x: 0.42, y: 0.01, w: 0.57, h: 0.47 },
    viewer: { x: 0.01, y: 0.5, w: 0.98, h: 0.49 },
  },
};

const STORAGE_KEY = "scum-server-layout-v2";

function finiteOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}

function defaultRect(panel: ServerPanelId): ServerPanelRect {
  return { ...DEFAULT_SERVER_LAYOUT.rects[panel] };
}

/**
 * Keep a normalized rectangle inside the stage and above the panel's usable
 * minimum. The minimum is converted to stage-relative units so the same
 * persisted layout can be reused at every window size.
 */
export function clampServerPanelRect(
  panel: ServerPanelId,
  rect: ServerPanelRect,
  stage?: ServerStageSize,
): ServerPanelRect {
  const fallback = defaultRect(panel);
  const rawW = clamp(finiteOr(rect.w, fallback.w), 0.001, 1);
  const rawH = clamp(finiteOr(rect.h, fallback.h), 0.001, 1);
  const minimum = SERVER_PANEL_MIN_SIZE[panel];
  const minW =
    stage && stage.width > 0
      ? Math.min(1, minimum.width / stage.width)
      : Math.min(1, rawW);
  const minH =
    stage && stage.height > 0
      ? Math.min(1, minimum.height / stage.height)
      : Math.min(1, rawH);
  const w = clamp(rawW, minW, 1);
  const h = clamp(rawH, minH, 1);
  return {
    x: clamp(finiteOr(rect.x, fallback.x), 0, Math.max(0, 1 - w)),
    y: clamp(finiteOr(rect.y, fallback.y), 0, Math.max(0, 1 - h)),
    w,
    h,
  };
}

export function moveServerPanelRect(
  panel: ServerPanelId,
  rect: ServerPanelRect,
  deltaX: number,
  deltaY: number,
  stage?: ServerStageSize,
): ServerPanelRect {
  return clampServerPanelRect(
    panel,
    {
      ...rect,
      x: rect.x + deltaX,
      y: rect.y + deltaY,
    },
    stage,
  );
}

export function resizeServerPanelRect(
  panel: ServerPanelId,
  rect: ServerPanelRect,
  deltaW: number,
  deltaH: number,
  stage?: ServerStageSize,
): ServerPanelRect {
  return clampServerPanelRect(
    panel,
    {
      ...rect,
      w: rect.w + deltaW,
      h: rect.h + deltaH,
    },
    stage,
  );
}

export function normalizeServerLayout(value: unknown): ServerLayout {
  const input =
    value && typeof value === "object"
      ? (value as { rects?: Partial<Record<ServerPanelId, Partial<ServerPanelRect>>> })
      : {};
  const rects = {} as Record<ServerPanelId, ServerPanelRect>;
  for (const panel of SERVER_PANEL_ORDER) {
    const candidate = input.rects?.[panel];
    const fallback = defaultRect(panel);
    rects[panel] = clampServerPanelRect(panel, {
      x: finiteOr(candidate?.x, fallback.x),
      y: finiteOr(candidate?.y, fallback.y),
      w: finiteOr(candidate?.w, fallback.w),
      h: finiteOr(candidate?.h, fallback.h),
    });
  }
  return { rects };
}

export function fitServerLayoutToStage(
  layout: ServerLayout,
  stage: ServerStageSize,
): ServerLayout {
  const normalized = normalizeServerLayout(layout);
  const rects = {} as Record<ServerPanelId, ServerPanelRect>;
  for (const panel of SERVER_PANEL_ORDER) {
    rects[panel] = clampServerPanelRect(panel, normalized.rects[panel], stage);
  }
  return { rects };
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
