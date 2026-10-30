import { useEffect, useState } from "react";
import type { RemoteFile, SftpAccount, SftpConnectionResult } from "../../types";
import { useI18n } from "../../i18n";
import { formatBytes, formatDate } from "../../lib/format";
import { parseSftpConnectionUrl } from "../../lib/sftpUrl";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { Icon, type IconName } from "../ui/Icon";

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
  scan: SftpConnectionResult | null;
  connectedAccountId: string | null;
  onSaveAccount: (
    account: Omit<SftpAccount, "id" | "hasPassword">,
    password: string,
  ) => void;
  onTestAccount: (accountId: string) => void;
  onTrustHost: () => void;
  onDismissTrust: () => void;
  onLoadFiles: (accountId: string, path: string) => void;
  onUpload: (accountId: string, localPaths: string[]) => void;
  onOpenSettings: () => void;
}

interface ScanGroupProps {
  icon: IconName;
  title: string;
  path?: string | null;
  files: RemoteFile[];
}

function ScanGroup({ icon, title, path, files }: ScanGroupProps) {
  const { t, language } = useI18n();
  return (
    <article className="server-scan-group">
      <header>
        <span className="file-symbol is-folder">
          <Icon name={icon} size={16} />
        </span>
        <div>
          <b>{title}</b>
          <code title={path ?? undefined}>{path || t("server.scanNotLocated")}</code>
        </div>
        <span>{t("server.scanCount", { count: files.length })}</span>
      </header>
      {files.length > 0 ? (
        <div className="server-scan-list">
          {files.map((file) => (
            <div className="server-scan-row" key={file.path}>
              <span>{file.name}</span>
              <small>
                {file.isDirectory
                  ? t("common.directory")
                  : `${formatBytes(file.size)} · ${formatDate(file.modifiedAt, language)}`}
              </small>
            </div>
          ))}
        </div>
      ) : (
        <p className="server-scan-empty">{t("server.scanEmpty")}</p>
      )}
    </article>
  );
}

export function ServerScreen({
  accounts,
  activeAccountId,
  files,
  loading,
  error,
  trustPrompt,
  scan,
  connectedAccountId,
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
  const connected = Boolean(scan?.ok && connectedAccountId === active?.id);
  const [formExpanded, setFormExpanded] = useState(true);
  const [connectionUrl, setConnectionUrl] = useState("");
  const [connectionMessage, setConnectionMessage] = useState<string | null>(null);
  const [connectionError, setConnectionError] = useState<string | null>(null);
  const [name, setName] = useState(editing?.name ?? "");
  const [host, setHost] = useState(editing?.host ?? "");
  const [port, setPort] = useState(editing?.port ?? 22);
  const [username, setUsername] = useState(editing?.username ?? "");
  const [secretInput, setSecretInput] = useState("");
  const [modsPath, setModsPath] = useState(editing?.modsPath ?? "");
  const [ue4ssPath, setUe4ssPath] = useState(editing?.ue4ssPath ?? "");
  const [browsePath, setBrowsePath] = useState(active?.modsPath ?? "");

  useEffect(() => {
    const source = accounts.find((account) => account.id === editingId) ?? null;
    setName(source?.name ?? "");
    setHost(source?.host ?? "");
    setPort(source?.port ?? 22);
    setUsername(source?.username ?? "");
    setModsPath(source?.modsPath ?? "");
    setUe4ssPath(source?.ue4ssPath ?? "");
    setSecretInput("");
    setConnectionUrl("");
    setConnectionMessage(null);
    setConnectionError(null);
  }, [accounts, editingId]);

  // 保存后账户 id 可能被重建，编辑目标不能停在已失效的 id 上。
  useEffect(() => {
    if (editingId === "__new__") return;
    if (editingId && accounts.some((account) => account.id === editingId)) return;
    setEditingId(active?.id ?? null);
  }, [accounts, active?.id, editingId]);

  useEffect(() => {
    setFormExpanded(editingId !== active?.id ? true : !connected);
  }, [active?.id, connected, editingId]);

  useEffect(() => {
    setBrowsePath(active?.modsPath ?? "");
  }, [active?.id, active?.modsPath]);

  useEffect(() => {
    const candidate = connectionUrl.trim();
    if (!/^sftp:\/\/[^@\s]+@[^/\s]+:\d+(?:\/.*)?$/i.test(candidate)) return;
    const timer = window.setTimeout(() => applyConnectionUrl(candidate), 450);
    return () => window.clearTimeout(timer);
  }, [connectionUrl]);

  function startNewAccount() {
    setEditingId("__new__");
    setFormExpanded(true);
  }

  function applyConnectionUrl(raw: string) {
    try {
      const parsed = parseSftpConnectionUrl(raw);
      setHost(parsed.host);
      setPort(parsed.port);
      setUsername(parsed.username);
      if (parsed.password) setSecretInput(parsed.password);
      if (parsed.path) setModsPath(parsed.path);
      if (!name.trim()) setName(parsed.username);
      setConnectionUrl("");
      setConnectionError(null);
      setConnectionMessage(t("server.parsedConnection"));
    } catch (parseError) {
      setConnectionMessage(null);
      setConnectionError(String(parseError));
    }
  }

  const displayPath = browsePath || active?.modsPath || "";
  const canGoBackToMods = Boolean(
    active?.modsPath && displayPath && displayPath !== active.modsPath,
  );

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

      <div className="server-workspace">
        <div className="server-layout">
          <form
            className={`server-form ${!formExpanded && connected ? "is-collapsed" : ""}`}
            onSubmit={(event) => {
              event.preventDefault();
              const finalName = name.trim() || host.trim() || t("server.defaultAccount");
              if (finalName !== name) setName(finalName);
              onSaveAccount(
                {
                  name: finalName,
                  host,
                  port,
                  username,
                  modsPath,
                  ue4ssPath,
                },
                secretInput,
              );
            }}
          >
            <div className="section-title server-form-title">
              <span>{t("server.accounts")}</span>
              <div>
                {connected ? (
                  <span className="sftp-connection-state">
                    <i />
                    {t("server.connectionReady")}
                  </span>
                ) : (
                  <b>
                    {accounts.length > 0
                      ? t("server.savedCount", { count: accounts.length })
                      : t("server.notSaved")}
                  </b>
                )}
                {connected ? (
                  <Button
                    size="sm"
                    icon={formExpanded ? "chevronDown" : "chevronRight"}
                    onClick={() => setFormExpanded((current) => !current)}
                  >
                    {t(formExpanded ? "server.collapseAccount" : "server.expandAccount")}
                  </Button>
                ) : null}
              </div>
            </div>

            {!formExpanded && connected && active ? (
              <div className="sftp-account-summary">
                <div>
                  <b>{active.name}</b>
                  <span>
                    {t("server.connectedAs", {
                      username: active.username,
                      host: active.host,
                      port: active.port,
                    })}
                  </span>
                </div>
                <dl>
                  <div>
                    <dt>PAK</dt>
                    <dd>
                      {scan?.detectedModsPath ||
                        active.modsPath ||
                        t("server.scanNotLocated")}
                    </dd>
                  </div>
                  <div>
                    <dt>UE4SS</dt>
                    <dd>
                      {scan?.detectedUe4ssPath ||
                        active.ue4ssPath ||
                        t("server.scanNotLocated")}
                    </dd>
                  </div>
                </dl>
              </div>
            ) : (
              <>
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

                <div className="sftp-url-import">
                  <label>
                    <span>
                      {t("server.connectionUrl")}
                      <small>{t("server.connectionUrlHint")}</small>
                    </span>
                    <div>
                      <input
                        value={connectionUrl}
                        onChange={(event) => {
                          setConnectionUrl(event.target.value);
                          setConnectionMessage(null);
                          setConnectionError(null);
                        }}
                        onPaste={(event) => {
                          const pasted = event.clipboardData.getData("text");
                          if (!pasted.trim()) return;
                          event.preventDefault();
                          setConnectionUrl(pasted);
                          applyConnectionUrl(pasted);
                        }}
                        onKeyDown={(event) => {
                          if (event.key !== "Enter" || !connectionUrl.trim()) return;
                          event.preventDefault();
                          applyConnectionUrl(connectionUrl);
                        }}
                        placeholder={t("server.connectionUrlPlaceholder")}
                        spellCheck={false}
                      />
                      <Button
                        size="sm"
                        icon="arrow"
                        onClick={() => applyConnectionUrl(connectionUrl)}
                        disabled={!connectionUrl.trim()}
                      >
                        {t("server.parseConnection")}
                      </Button>
                    </div>
                  </label>
                  {connectionMessage ? (
                    <p className="sftp-import-message" role="status">
                      {connectionMessage}
                    </p>
                  ) : null}
                  {connectionError ? (
                    <p className="sftp-import-message is-error" role="alert">
                      {connectionError}
                    </p>
                  ) : null}
                </div>

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
                      value={secretInput}
                      onChange={(event) => setSecretInput(event.target.value)}
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
                  <label className="form-span-2">
                    <span>{t("server.ue4ssPath")}</span>
                    <input
                      value={ue4ssPath}
                      onChange={(event) => setUe4ssPath(event.target.value)}
                      placeholder="/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods"
                    />
                  </label>
                </div>
                <div className="form-actions">
                  <Button type="submit" variant="primary" icon="lock">
                    {t("server.saveAccount")}
                  </Button>
                </div>
              </>
            )}

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
              <b title={displayPath || undefined}>
                {displayPath || t("server.modsNotLocated")}
              </b>
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
                    onClick={() => {
                      const path = active.modsPath;
                      setBrowsePath(path);
                      onLoadFiles(active.id, path);
                    }}
                    disabled={!active.modsPath || loading}
                  >
                    {t("server.readDirectory")}
                  </Button>
                }
              />
            ) : (
              <div className="remote-file-list">
                {files.map((file) => {
                  const content = (
                    <>
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
                    </>
                  );
                  return file.isDirectory ? (
                    <button
                      type="button"
                      className="remote-file-row is-browsable"
                      key={file.path}
                      aria-label={`${t("server.openFolder")} ${file.name}`}
                      onClick={() => {
                        setBrowsePath(file.path);
                        onLoadFiles(active.id, file.path);
                      }}
                    >
                      {content}
                    </button>
                  ) : (
                    <div className="remote-file-row" key={file.path}>
                      {content}
                    </div>
                  );
                })}
              </div>
            )}
            <div className="server-browser-actions">
              {canGoBackToMods ? (
                <Button
                  icon="chevronRight"
                  onClick={() => {
                    if (!active?.modsPath) return;
                    setBrowsePath(active.modsPath);
                    onLoadFiles(active.id, active.modsPath);
                  }}
                  disabled={loading}
                >
                  {t("server.browseRoot")}
                </Button>
              ) : null}
              <Button
                icon="refresh"
                onClick={() => active && onLoadFiles(active.id, displayPath || active.modsPath)}
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

        {connected && scan ? (
          <section className="server-mod-scan">
            <div className="section-title">
              <span>{t("server.scanTitle")}</span>
              <b>
                {scan.scannedDirectories > 0
                  ? t("server.scanChecked", { count: scan.scannedDirectories })
                  : t("server.connectionReady")}
              </b>
            </div>
            <div className="server-scan-grid">
              <ScanGroup
                icon="box"
                title={t("server.scanPak")}
                path={scan.detectedModsPath}
                files={scan.pakMods}
              />
              <ScanGroup
                icon="folder"
                title={t("server.scanUe4ss")}
                path={scan.detectedUe4ssPath}
                files={scan.ue4ssMods}
              />
            </div>
          </section>
        ) : null}
      </div>
    </section>
  );
}
