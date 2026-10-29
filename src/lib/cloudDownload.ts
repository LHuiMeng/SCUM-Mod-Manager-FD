import type { CloudDownloadPhase, CloudDownloadProgress } from "../types";
import { translate, type Translator } from "../i18n";
import { formatBytes } from "./format";

export const MIN_CLOUD_DOWNLOAD_SEGMENTS = 8;
export const MAX_CLOUD_DOWNLOAD_SEGMENTS = 128;

const phaseKeys = {
  queued: "cloudDownload.queued",
  preparing: "cloudDownload.preparing",
  downloading: "cloudDownload.downloading",
  verifying: "cloudDownload.verifying",
  installing: "cloudDownload.installing",
  completed: "cloudDownload.completed",
  error: "cloudDownload.error",
} as const;

const fallbackT: Translator = (key, variables) => {
  return translate("zh-CN", null, key, variables);
};

export function cloudDownloadPhaseLabel(
  phase: CloudDownloadPhase,
  t: Translator = fallbackT,
): string {
  return t(phaseKeys[phase]);
}

export function clampCloudDownloadSegments(value: number): number {
  const normalized = Number.isFinite(value)
    ? Math.round(value)
    : MIN_CLOUD_DOWNLOAD_SEGMENTS;
  return Math.min(
    MAX_CLOUD_DOWNLOAD_SEGMENTS,
    Math.max(MIN_CLOUD_DOWNLOAD_SEGMENTS, normalized),
  );
}

export function cloudDownloadIsActive(progress: CloudDownloadProgress): boolean {
  return (
    progress.phase === "queued" ||
    progress.phase === "preparing" ||
    progress.phase === "downloading" ||
    progress.phase === "verifying" ||
    progress.phase === "installing"
  );
}

export function cloudDownloadPercent(progress: CloudDownloadProgress): number {
  if (
    progress.phase === "verifying" ||
    progress.phase === "installing" ||
    progress.phase === "completed"
  ) {
    return 100;
  }
  if (!progress.total || progress.total <= 0) return 0;
  return Math.min(100, Math.round((progress.downloaded / progress.total) * 100));
}

export function cloudDownloadDetail(
  progress: CloudDownloadProgress,
  t: Translator = fallbackT,
): string {
  if (progress.phase === "queued") return t("cloudDownload.detail.queued");
  if (progress.phase === "preparing") return t("cloudDownload.detail.preparing");
  if (progress.phase === "verifying") return t("cloudDownload.detail.verifying");
  if (progress.phase === "installing") return t("cloudDownload.detail.installing");
  if (progress.phase === "completed") return t("cloudDownload.detail.completed");
  if (progress.phase === "error") {
    return progress.message || t("cloudDownload.detail.error");
  }
  const downloaded = formatBytes(progress.downloaded);
  const total = progress.total
    ? formatBytes(progress.total)
    : t("common.sizePending");
  return t("cloudDownload.detail.active", {
    downloaded,
    total,
    segments: progress.segments,
  });
}
