export type ConnectionProtocol = "sftp" | "ftp" | "ftps";

export interface ParsedConnection {
  protocol: ConnectionProtocol;
  username: string;
  host: string;
  port: number;
  password: string;
  path: string;
}

const DEFAULT_PORTS: Record<ConnectionProtocol, number> = {
  sftp: 22,
  ftp: 21,
  ftps: 990,
};

const SCHEME_PATTERN = /^([a-z][a-z0-9+.-]*):\/\//i;
const HOST_PORT_PATTERN = /^(\[[0-9a-f:.]+\]|[^\s:@/]+):(\d{1,5})$/i;

function decodeUrlPart(value: string, label: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    throw new Error(`${label}包含无效的 URL 编码`);
  }
}

function normalizeProtocol(scheme: string | undefined): ConnectionProtocol {
  if (!scheme) return "sftp";
  const normalized = scheme.toLowerCase();
  if (normalized === "sftp" || normalized === "ftp" || normalized === "ftps") {
    return normalized;
  }
  throw new Error("仅支持 sftp://、ftp:// 与 ftps:// 连接链接");
}

/** 地址框里的内容是连接链接（而不是裸主机名）时才算需要拆分的输入。 */
export function looksLikeConnectionString(value: string): boolean {
  const trimmed = value.trim();
  if (!trimmed) return false;
  return SCHEME_PATTERN.test(trimmed) || trimmed.includes("@");
}

/** 只带了一个 `主机:端口` 的输入，单独拆端口用。 */
export function parseHostPort(
  value: string,
): { host: string; port: number } | null {
  const matched = HOST_PORT_PATTERN.exec(value.trim());
  if (!matched) return null;
  const port = Number(matched[2]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
  return { host: matched[1], port };
}

/**
 * 解析连接链接：协议由前缀决定（sftp / ftp / ftps），链接里写了端口就用链接里的端口，
 * 没写才回落到该协议的默认端口。省略前缀时按 sftp 处理，方便只粘贴 `用户@主机:端口`。
 */
export function parseConnectionString(input: string): ParsedConnection {
  const trimmed = input.trim();
  if (!trimmed) throw new Error("请输入连接地址");

  const schemeMatch = SCHEME_PATTERN.exec(trimmed);
  const protocol = normalizeProtocol(schemeMatch?.[1]);
  const candidate = schemeMatch ? trimmed : `sftp://${trimmed}`;

  let url: URL;
  try {
    url = new URL(candidate);
  } catch {
    throw new Error("连接地址格式无效");
  }
  if (!url.hostname) throw new Error("连接地址缺少服务器地址");

  const username = decodeUrlPart(url.username, "用户名");
  if (!username.trim()) throw new Error("连接链接缺少用户名");
  const password = url.password ? decodeUrlPart(url.password, "密码") : "";
  const path =
    url.pathname && url.pathname !== "/"
      ? decodeUrlPart(url.pathname, "路径")
      : "";
  const port = url.port ? Number(url.port) : DEFAULT_PORTS[protocol];
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("连接地址中的端口无效");
  }

  return {
    protocol,
    username: username.trim(),
    host: url.hostname,
    port,
    path,
    password,
  };
}
