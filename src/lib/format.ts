import type { ModType } from "../types";

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / 1024 ** index;
  return `${value.toFixed(index >= 3 ? 2 : index === 0 ? 0 : 1)} ${units[index]}`;
}

export function modTypeLabel(type: ModType): string {
  switch (type) {
    case "clientPak":
      return "客户端 PAK";
    case "serverPak":
      return "服务端 PAK";
    case "ue4ssMod":
      return "UE4SS MOD";
    case "configFile":
      return "配置文件";
    case "script":
      return "脚本";
    default:
      return "其他";
  }
}

export function modMonogram(name: string): string {
  const parts = name.replace(/[^a-zA-Z0-9_]/g, "_").split("_").filter(Boolean);
  if (parts.length >= 2) return `${parts[0][0]}${parts[1][0]}`.toUpperCase();
  return name.slice(0, 2).toUpperCase();
}

export function formatDate(value: string | null | undefined, todayLabel = "今天"): string {
  if (!value) return "未记录";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "未记录";
  const now = new Date();
  if (date.toDateString() === now.toDateString()) return todayLabel;
  return `${date.getMonth() + 1} 月 ${date.getDate()} 日`;
}

export function formatClock(value: string | null | undefined): string {
  if (!value) return "--:--";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "--:--";
  return date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false });
}

export function compactHash(hash: string): string {
  if (!hash) return "尚未计算";
  return hash.length > 12 ? `${hash.slice(0, 4)}…${hash.slice(-4)}` : hash;
}
