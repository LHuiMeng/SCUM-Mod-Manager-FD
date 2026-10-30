export interface ParsedSftpConnection {
  protocol: "sftp";
  username: string;
  host: string;
  port: number;
  password: string;
  path: string;
}

function decodeUrlPart(value: string, label: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    throw new Error(`${label}包含无效的 URL 编码`);
  }
}

export function parseSftpConnectionUrl(input: string): ParsedSftpConnection {
  const trimmed = input.trim();
  if (!trimmed) throw new Error("请输入 SFTP 连接链接");

  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    throw new Error("连接链接格式无效");
  }
  if (url.protocol !== "sftp:") {
    throw new Error("仅支持 sftp:// 连接链接");
  }
  if (!url.hostname) throw new Error("连接链接缺少服务器地址");

  const username = decodeUrlPart(url.username, "用户名");
  if (!username.trim()) throw new Error("连接链接缺少用户名");
  const password = url.password ? decodeUrlPart(url.password, "密码") : "";
  const path = url.pathname && url.pathname !== "/" ? decodeUrlPart(url.pathname, "路径") : "";
  const port = url.port ? Number(url.port) : 22;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("连接链接中的端口无效");
  }

  return {
    protocol: "sftp",
    username: username.trim(),
    host: url.hostname,
    port,
    password,
    path,
  };
}
