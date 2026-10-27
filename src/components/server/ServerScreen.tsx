import { useEffect, useState } from "react";
import type { RemoteFile, SftpAccount } from "../../types";
import { formatBytes, formatDate } from "../../lib/format";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { Icon } from "../ui/Icon";

interface ServerScreenProps {
  accounts: SftpAccount[];
  activeAccountId: string | null;
  files: RemoteFile[];
  loading: boolean;
  error: string | null;
  trustPrompt: {
    accountId: string;
    fingerprint: string;
    message: string;
  } | null;
  onSaveAccount: (account: Omit<SftpAccount, "id" | "hasPassword">, password: string) => void;
  onTestAccount: (accountId: string) => void;
  onTrustHost: () => void;
  onDismissTrust: () => void;
  onLoadFiles: (accountId: string, path: string) => void;
  onUpload: (accountId: string, localPaths: string[]) => void;
  onOpenSettings: () => void;
}

export function ServerScreen({
  accounts,
  activeAccountId,
  files,
  loading,
  error,
  trustPrompt,
  onSaveAccount,
  onTestAccount,
  onTrustHost,
  onDismissTrust,
  onLoadFiles,
  onUpload,
  onOpenSettings,
}: ServerScreenProps) {
  const active = accounts.find((account) => account.id === activeAccountId) ?? accounts[0] ?? null;
  const [name, setName] = useState(active?.name ?? "主服务器");
  const [host, setHost] = useState(active?.host ?? "");
  const [port, setPort] = useState(active?.port ?? 22);
  const [username, setUsername] = useState(active?.username ?? "");
  const [password, setPassword] = useState("");
  const [modsPath, setModsPath] = useState(active?.modsPath ?? "");

  useEffect(() => {
    if (!active) return;
    setName(active.name);
    setHost(active.host);
    setPort(active.port);
    setUsername(active.username);
    setModsPath(active.modsPath);
    setPassword("");
  }, [active]);

  return (
    <section className="page page-server">
      <header className="page-header">
        <div>
          <h1>远程服务器</h1>
          <p>通过 SFTP 管理服务器端 `~mods`。密码由 Windows DPAPI 加密，不进入前端存储。</p>
        </div>
        <div className="heading-tools">
          {active ? (
            <Button icon="server" onClick={() => onTestAccount(active.id)} disabled={loading}>
              测试连接
            </Button>
          ) : null}
          <Button icon="settings" onClick={onOpenSettings}>
            账户设置
          </Button>
        </div>
      </header>

      <div className="server-layout">
        <form
          className="server-form"
          onSubmit={(event) => {
            event.preventDefault();
            onSaveAccount(
              { name, host, port, username, modsPath },
              password,
            );
          }}
        >
          <div className="section-title">
            <span>连接账户</span>
            <b>{accounts.length > 0 ? `${accounts.length} 个已保存账户` : "新账户"}</b>
          </div>
          <div className="form-grid">
            <label>
              <span>账户名称</span>
              <input value={name} onChange={(event) => setName(event.target.value)} />
            </label>
            <label>
              <span>服务器地址</span>
              <input
                value={host}
                onChange={(event) => setHost(event.target.value)}
                placeholder="sftp.example.com"
                required
              />
            </label>
            <label>
              <span>端口</span>
              <input
                type="number"
                value={port}
                min={1}
                max={65535}
                onChange={(event) => setPort(Number(event.target.value))}
              />
            </label>
            <label>
              <span>用户名</span>
              <input
                value={username}
                onChange={(event) => setUsername(event.target.value)}
                autoComplete="username"
                required
              />
            </label>
            <label className="form-span-2">
              <span>密码 {active?.hasPassword ? "（留空则保持原密码）" : ""}</span>
              <input
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                autoComplete="current-password"
                placeholder={active?.hasPassword ? "已安全保存" : "输入 SFTP 密码"}
              />
            </label>
            <label className="form-span-2">
              <span>远端 ~mods 路径</span>
              <input
                value={modsPath}
                onChange={(event) => setModsPath(event.target.value)}
                placeholder="/srv/scum/SCUM/Content/Paks/~mods"
              />
            </label>
          </div>
          <div className="form-actions">
            <Button type="submit" variant="primary" icon="lock">
              安全保存账户
            </Button>
          </div>
          {trustPrompt && trustPrompt.accountId === active?.id ? (
            <div className="sftp-trust-prompt" role="alert">
              <div>
                <b>请核对服务器主机密钥</b>
                <p>{trustPrompt.message}</p>
                <code>{trustPrompt.fingerprint}</code>
              </div>
              <div className="sftp-trust-actions">
                <Button size="sm" onClick={onDismissTrust}>
                  取消
                </Button>
                <Button size="sm" icon="lock" onClick={onTrustHost}>
                  信任此主机
                </Button>
              </div>
            </div>
          ) : null}
        </form>

        <section className="server-browser">
          <div className="section-title">
            <span>远程文件</span>
            <b>{modsPath || "未定位 ~mods"}</b>
          </div>
          {!active ? (
            <EmptyState
              icon="server"
              title="还没有服务器账户"
              description="填写左侧表单并安全保存后即可浏览远程文件。"
            />
          ) : error ? (
            <EmptyState
              icon="serverOff"
              title="远程连接失败"
              description={error}
              action={
                <Button onClick={() => onTestAccount(active.id)}>
                  重新测试
                </Button>
              }
            />
          ) : files.length === 0 ? (
            <EmptyState
              icon="folder"
              title="尚未读取远程目录"
              description="请先测试连接，然后刷新服务器端 `~mods`。"
              action={
                <Button
                  icon="refresh"
                  onClick={() => onLoadFiles(active.id, active.modsPath)}
                  disabled={!active.modsPath || loading}
                >
                  读取目录
                </Button>
              }
            />
          ) : (
            <div className="remote-file-list">
              {files.map((file) => (
                <div className="remote-file-row" key={file.path}>
                  <span className={`file-symbol ${file.isDirectory ? "is-folder" : ""}`}>
                    <Icon name={file.isDirectory ? "folder" : "box"} size={16} />
                  </span>
                  <div>
                    <b>{file.name}</b>
                    <span>{file.isDirectory ? "目录" : formatBytes(file.size)}</span>
                  </div>
                  <span>{formatDate(file.modifiedAt)}</span>
                </div>
              ))}
            </div>
          )}
          <div className="server-browser-actions">
            <Button
              icon="refresh"
              onClick={() => active && onLoadFiles(active.id, active.modsPath)}
              disabled={!active?.modsPath || loading}
            >
              刷新目录
            </Button>
            <Button
              icon="upload"
              onClick={() => active && onUpload(active.id, [])}
              disabled={!active || loading}
            >
              上传本地 PAK
            </Button>
          </div>
        </section>
      </div>
    </section>
  );
}
