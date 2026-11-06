import type { TranslationKey } from "../i18n";
import type { SftpOperationProgress } from "../types";

export interface OperationEntry extends SftpOperationProgress {
  id: number;
  receivedAt: number;
}

export interface OperationState {
  current: OperationEntry | null;
  history: OperationEntry[];
}

export const emptyOperations: OperationState = { current: null, history: [] };

const HISTORY_LIMIT = 12;

/** 所有长操作共用一条流：finished 的进历史并清空 current，未完的顶上 current。 */
export function applyOperationEvent(
  state: OperationState,
  event: SftpOperationProgress,
  now: number,
): OperationState {
  const entry: OperationEntry = {
    ...event,
    id: (state.history.at(-1)?.id ?? 0) + 1,
    receivedAt: now,
  };
  const history = [...state.history, entry].slice(-HISTORY_LIMIT);
  return event.finished ? { current: null, history } : { current: entry, history };
}

/** 命令返回后兜底：即使后端漏发 finished（断连/被杀），操作条也不会一直转。 */
export function clearOperation(state: OperationState, kind?: string): OperationState {
  if (!state.current) return state;
  if (kind && state.current.kind !== kind) return state;
  return { ...state, current: null };
}

export function operationPercent(entry: OperationEntry | null): number | null {
  if (!entry || entry.total <= 0) return null;
  return Math.min(100, Math.round((entry.completed / entry.total) * 100));
}

export function formatElapsed(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const pad = (value: number) => String(value).padStart(2, "0");
  return hours > 0
    ? `${hours}:${pad(minutes)}:${pad(seconds)}`
    : `${pad(minutes)}:${pad(seconds)}`;
}

const OPERATION_KIND_KEYS: Record<string, TranslationKey> = {
  analyze: "operation.kind.analyze",
  prepare: "operation.kind.prepare",
  apply: "operation.kind.apply",
  upload: "operation.kind.upload",
  download: "operation.kind.download",
  restore: "operation.kind.restore",
};

/** 后端只发 kind 字符串，这里收敛成可被 t() 接受的文案键。 */
export function operationKindKey(kind: string): TranslationKey {
  return OPERATION_KIND_KEYS[kind] ?? "operation.kind.other";
}
