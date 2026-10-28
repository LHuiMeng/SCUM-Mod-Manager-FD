import type { CloudDownloadPhase, CloudDownloadProgress } from "../types";
import { formatBytes } from "./format";

export const MIN_CLOUD_DOWNLOAD_SEGMENTS = 8;
export const MAX_CLOUD_DOWNLOAD_SEGMENTS = 128;

const phaseLabels: Record<CloudDownloadPhase, string> = {
  queued: "等待下载槽位",
  preparing: "正在分析分片",
  downloading: "正在分片下载",
  verifying: "正在校验文件",
  installing: "正在安装模组",
  completed: "下载完成",
  error: "下载失败",
};

export function cloudDownloadPhaseLabel(
  phase: CloudDownloadPhase,
): string {
  return phaseLabels[phase];
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

export function cloudDownloadDetail(progress: CloudDownloadProgress): string {
  if (progress.phase === "queued") return "正在等待空闲下载槽位";
  if (progress.phase === "preparing") return "正在探测 Range 支持并规划动态分片";
  if (progress.phase === "verifying") return "正在合并分片并校验 SHA-256";
  if (progress.phase === "installing") return "正在解压或写入本地模组库";
  if (progress.phase === "completed") return "模组已写入本地模组库";
  if (progress.phase === "error") return progress.message || "下载任务未完成";
  const downloaded = formatBytes(progress.downloaded);
  const total = progress.total ? formatBytes(progress.total) : "大小待确认";
  return `${downloaded} / ${total} · ${progress.segments} 路并发`;
}
