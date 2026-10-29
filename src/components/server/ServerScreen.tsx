import { useEffect, useState } from "react";
import type { RemoteFile, SftpAccount } from "../../types";
import { useI18n } from "../../i18n";
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
  const { t, language } = useI18n();
  const active = accounts.find((account) => account.id === activeAccountId) ?? accounts[0] ?? null;
  const [editingId, setEditingId] = useState<string | null>(active?.id ?? null);
  const editing = accounts.find((account) => account.id === editingId) ?? null;
  const [name, setName] = useState(editing?.name ?? "");
  const [host, setHost] = useState(editing?.host ?? "");
  const [port, setPort] = useState(editing?.port ?? 22);
  const [username, setUsername] = useState(editing?.username ?? "");
  const [password, setPassword] = useState("");
  const [modsPath, setModsPath] = useState(editing?.modsPath ?? "");

  useEffect(() => {
    const source = accounts.find((account) => account.id === editingId) ?? null;
    setName(source?.name ?? "");
    setHost(source?.host ?? "");
    setPort(source?.port ?? 22);
    setUsername(source?.username ?? "");
    setModsPath(source?.modsPath ?? "");
    setPassword("");
  }, [accounts, editingId]);

  // 保存后账户 id 可能被重建，编辑目标不能停在已失效的 id 上。
  useEffect(() => {
    if (editingId === "__new__") return;
    if (editingId && accounts.some((account) => account.id === editingId)) return;
    setEditingId(active?.id ?? null);
  }, [accounts, active?.id, editingId]);

  function startNewAccount() {
    setEditingId("__new__");
  }

  return (
    <section className="page page-server">
      <header className="page-header">
        <div>
          <h1>{t("server.title")}</h1>
          <p>{t("server.subtitle")}</p>
        </div>
        <div className="heading-tools">
          {active ? (
            <Button icon="server" onClick={() => onTestAccount(active.id)} disabled={loading}>
              {t("server.testConnection")}
            </Button>
          ) : null}
          <Button icon="settings" onClick={onOpenSettings}>
            {t("server.accountSettings")}
          </Button>
        </div>
      </header>

      <div className="server-layout">
        <form
          className="server-form"
          onSubmit={(event) => {
            event.preventDefault();
            const finalName = name.trim() || host.trim() || t("server.defaultAccount");
            if (finalName !== name) setName(finalName);
            onSaveAccount(
              { name: finalName, host, port, username, modsPath },
              password,
            );
          }}
        >
          <div className="section-title">
            <span>{t("server.accounts")}</span>
            <b>
              {accounts.length > 0
                ? t("server.savedCount", { count: accounts.length })
                : t("server.notSaved")}
            </b>
          </div>
          {accounts.length > 0 ? (
            <div className="server-account-bar">
              <select
                aria-label={t("server.selectAccount")}
                value={editingId ?? ""}
                onChange={(event) => setEditingId(event.target.value || null)}
              >
                {accounts.map((account) => (
                  <option key={account.id} value={account.id}>
                    {account.name}
                  </option>
                ))}
                {editingId === "__new__" ? (
                  <option value="__new__">{t("server.newAccount")}</option>
                ) : null}
              </select>
              <Button size="sm" icon="plus" onClick={startNewAccount}>
                {t("server.new")}
              </Button>
            </div>
          ) : null}
          <div className="form-grid">
            <label>
              <span>{t("server.accountName")}</span>
              <input value={name} onChange={(event) => setName(event.target.value)} />
            </label>
            <label>
              <span>{t("server.host")}</span>
              <input
                value={host}
                onChange={(event) => setHost(event.target.value)}
                placeholder="sftp.example.com"
                required
              />
            </label>
            <label>
              <span>{t("server.port")}</span>
              <input
                type="number"
                value={port}
                min={1}
                max={65535}
                onChange={(event) => setPort(Number(event.target.value))}
              />
            </label>
            <label>
              <span>{t("server.username")}</span>
              <input
                value={username}
                onChange={(event) => setUsername(event.target.value)}
                autoComplete="username"
                required
              />
            </label>
            <label className="form-span-2">
              <span>
                {t("server.password")}
                {editing?.hasPassword ? t("server.passwordKeep") : ""}
              </span>
              <input
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                autoComplete="current-password"
                placeholder={t(
                  editing?.hasPassword
                    ? "server.passwordSaved"
                    : "server.passwordPlaceholder",
                )}
              />
            </label>
            <label className="form-span-2">
              <span>{t("server.modsPath")}</span>
              <input
                value={modsPath}
                onChange={(event) => setModsPath(event.target.value)}
                placeholder="/srv/scum/SCUM/Content/Paks/~mods"
              />
            </label>
          </div>
          <div className="form-actions">
            <Button type="submit" variant="primary" icon="lock">
              {t("server.saveAccount")}
            </Button>
          </div>
          {trustPrompt && trustPrompt.accountId === editing?.id ? (
            <div className="sftp-trust-prompt" role="alert">
              <div>
                <b>{t("server.trustTitle")}</b>
                <p>{trustPrompt.message}</p>
                <code>{trustPrompt.fingerprint}</code>
              </div>
              <div className="sftp-trust-actions">
                <Button size="sm" onClick={onDismissTrust}>
                  {t("common.cancel")}
                </Button>
                <Button size="sm" icon="lock" onClick={onTrustHost}>
                  {t("server.trust")}
                </Button>
              </div>
            </div>
          ) : null}
        </form>

        <section className="server-browser">
          <div className="section-title">
            <span>{t("server.remoteFiles")}</span>
            <b>{modsPath || t("server.modsNotLocated")}</b>
          </div>
          {!active ? (
            <EmptyState
              icon="server"
              title={t("server.empty.noAccountTitle")}
              description={t("server.empty.noAccountDescription")}
            />
          ) : error ? (
            <EmptyState
              icon="serverOff"
              title={t("server.empty.failedTitle")}
              description={error}
              action={
                <Button onClick={() => onTestAccount(active.id)}>
                  {t("server.empty.retry")}
                </Button>
              }
            />
          ) : files.length === 0 ? (
            <EmptyState
              icon="folder"
              title={t("server.empty.noFilesTitle")}
              description={t("server.empty.noFilesDescription")}
              action={
                <Button
                  icon="refresh"
                  onClick={() => onLoadFiles(active.id, active.modsPath)}
                  disabled={!active.modsPath || loading}
                >
                  {t("server.readDirectory")}
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
                    <span>
                      {file.isDirectory ? t("common.directory") : formatBytes(file.size)}
                    </span>
                  </div>
                  <span>{formatDate(file.modifiedAt, language)}</span>
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
              {t("server.refreshDirectory")}
            </Button>
            <Button
              icon="upload"
              onClick={() => active && onUpload(active.id, [])}
              disabled={!active || loading}
            >
              {t("server.upload")}
            </Button>
          </div>
        </section>
      </div>
    </section>
  );
}
