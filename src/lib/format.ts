import type { ModType } from "../types";
import type { Language } from "../types";
import type { TranslationKey } from "../i18n";

const TYPE_KEYS: Record<ModType, TranslationKey> = {
  clientPak: "modType.clientPak",
  serverPak: "modType.serverPak",
  ue4ssMod: "modType.ue4ssMod",
  configFile: "modType.configFile",
  script: "modType.script",
  other: "modType.other",
};

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

export function modTypeKey(type: ModType): TranslationKey {
  return TYPE_KEYS[type] ?? TYPE_KEYS.other;
}

/** 列表、检查器与云端卡片共用同一套字母块规则：优先取词首字母，中文名取前两字。 */
export function modMonogram(name: string): string {
  const trimmed = name.trim();
  if (!trimmed) return "?";
  const ascii = trimmed.replace(/[^a-zA-Z0-9_]/g, "_").split("_").filter(Boolean);
  if (ascii.length >= 2) return `${ascii[0][0]}${ascii[1][0]}`.toUpperCase();
  return trimmed.slice(0, 2).toUpperCase();
}

export function formatDate(
  value: string | null | undefined,
  language: Language = "zh-CN",
  todayLabel = language === "en-US" ? "Today" : "今天",
): string {
  if (!value) return language === "en-US" ? "Not recorded" : "未记录";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return language === "en-US" ? "Not recorded" : "未记录";
  }
  const now = new Date();
  if (date.toDateString() === now.toDateString()) return todayLabel;
  if (date.getFullYear() !== now.getFullYear()) {
    return language === "en-US"
      ? date.toLocaleDateString("en-US", {
          year: "numeric",
          month: "short",
          day: "numeric",
        })
      : `${date.getFullYear()} 年 ${date.getMonth() + 1} 月 ${date.getDate()} 日`;
  }
  return language === "en-US"
    ? date.toLocaleDateString("en-US", { month: "short", day: "numeric" })
    : `${date.getMonth() + 1} 月 ${date.getDate()} 日`;
}

export function formatClock(
  value: string | null | undefined,
  language: Language = "zh-CN",
): string {
  if (!value) return "--:--";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "--:--";
  return date.toLocaleTimeString(language, {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

/** 日志用：同日只显示时分，跨天补日期，跨年补年份。 */
export function formatTimestamp(
  value: string | null | undefined,
  language: Language = "zh-CN",
): string {
  if (!value) return "--:--";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "--:--";
  const now = new Date();
  const clock = formatClock(value, language);
  if (date.toDateString() === now.toDateString()) return clock;
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  if (date.getFullYear() !== now.getFullYear()) {
    return `${date.getFullYear()}-${month}-${day} ${clock}`;
  }
  return `${month}-${day} ${clock}`;
}

export function compactHash(hash: string, emptyLabel = "尚未计算"): string {
  if (!hash) return emptyLabel;
  return hash.length > 12 ? `${hash.slice(0, 4)}…${hash.slice(-4)}` : hash;
}
