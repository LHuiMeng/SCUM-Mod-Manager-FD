/** 端口只有 1–65535 有意义；非法值一律回落到 SCUM 默认端口，避免把脏值写进配置。 */
export function normalizePort(value: string, fallback = "7777"): string {
  const parsed = Number.parseInt(value.trim(), 10);
  if (!Number.isFinite(parsed) || parsed < 1 || parsed > 65535) return fallback;
  return String(parsed);
}
