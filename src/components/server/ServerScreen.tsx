import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent,
} from "react";
import type {
  RemoteFile,
  SftpAccount,
  SftpConflictProgress,
  SftpConflictReport,
  SftpConnectionResult,
  SftpUploadKind,
} from "../../types";
import { useI18n } from "../../i18n";
import { formatBytes, formatDate } from "../../lib/format";
import {
  isRemotePathWithin,
  normalizeRemotePath,
  remoteBreadcrumbs,
  remoteParent,
} from "../../lib/remotePath";
import { parseSftpConnectionUrl } from "../../lib/sftpUrl";
import {
  DEFAULT_SERVER_LAYOUT,
  fitServerLayoutToStage,
  moveServerPanelRect,
  normalizeServerLayout,
  readStoredServerLayout,
  resizeServerPanelRect,
  SERVER_PANEL_ORDER,
  storeServerLayout,
  type ServerPanelId,
  type ServerStageSize,
} from "../../lib/serverLayout";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { Icon, type IconName } from "../ui/Icon";
import { RemoteModViewer } from "./RemoteModViewer";

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
  notes: Record<string, string>;
  conflicts: SftpConflictReport | null;
  conflictLoading: boolean;
  conflictProgress: SftpConflictProgress | null;
  onSaveAccount: (
    account: Omit<SftpAccount, "id" | "hasPassword">,
    password: string,
  ) => void;
  onTestAccount: (accountId: string) => void;
  onTrustHost: () => void;
  onDismissTrust: () => void;
  onLoadFiles: (accountId: string, path: string) => void;
  onDownload: (
    accountId: string,
    path: string,
    name: string,
  ) => Promise<void> | void;
  onUpload: (accountId: string, kind: SftpUploadKind) => Promise<void> | void;
  onRename: (
    accountId: string,
    path: string,
    newName: string,
  ) => Promise<string | null>;
  onDelete: (accountId: string, path: string) => Promise<boolean>;
  onSaveNote: (
    accountId: string,
    path: string,
    note: string,
  ) => Promise<boolean>;
  onAnalyzeConflicts: (accountId: string) => Promise<void> | void;
  onOpenSettings: () => void;
}

const PANEL_LABEL_KEYS: Record<
  ServerPanelId,
  "serverLayout.account" | "serverLayout.files" | "serverLayout.viewer"
> = {
  account: "serverLayout.account",
  files: "serverLayout.files",
  viewer: "serverLayout.viewer",
};

const TEXT_FILE_EXTENSIONS = new Set([
  "cfg",
  "ini",
  "json",
  "lua",
  "md",
  "toml",
  "txt",
  "xml",
  "yaml",
  "yml",
]);

function remoteFileExtension(name: string): string {
  const index = name.lastIndexOf(".");
  return index > 0 && index < name.length - 1
    ? name.slice(index + 1).toLowerCase()
    : "";
}

function remoteFileIcon(file: RemoteFile): IconName {
  if (file.isDirectory) return "folder";
  const extension = remoteFileExtension(file.name);
  if (extension === "pak") return "box";
  if (extension === "sig") return "lock";
  if (extension === "dll") return "settings";
  if (TEXT_FILE_EXTENSIONS.has(extension)) return "terminal";
  return "open";
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
  notes,
  conflicts,
  conflictLoading,
  conflictProgress,
  onSaveAccount,
  onTestAccount,
  onTrustHost,
  onDismissTrust,
  onLoadFiles,
  onDownload,
  onUpload,
  onRename,
  onDelete,
  onSaveNote,
  onAnalyzeConflicts,
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
  const [browsePath, setBrowsePath] = useState(() =>
    active?.modsPath ? normalizeRemotePath(active.modsPath) : "",
  );
  const [pathInput, setPathInput] = useState(() =>
    active?.modsPath ? normalizeRemotePath(active.modsPath) : "",
  );
  const [selectedFilePath, setSelectedFilePath] = useState<string | null>(null);
  const [layout, setLayout] = useState(readStoredServerLayout);
  const [layoutEditing, setLayoutEditing] = useState(false);
  const [activePanel, setActivePanel] = useState<ServerPanelId>("viewer");
  const [stageSize, setStageSize] = useState<ServerStageSize>({
    width: 1200,
    height: 700,
  });
  const stageRef = useRef<HTMLDivElement | null>(null);
  const effectiveLayout = useMemo(
    () => fitServerLayoutToStage(layout, stageSize),
    [layout, stageSize],
  );

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
    const nextPath = active?.modsPath ? normalizeRemotePath(active.modsPath) : "";
    setBrowsePath(nextPath);
    setPathInput(nextPath);
    setSelectedFilePath(null);
  }, [active?.id, active?.modsPath]);

  useEffect(() => {
    const timer = window.setTimeout(() => storeServerLayout(layout), 160);
    return () => window.clearTimeout(timer);
  }, [layout]);

  useEffect(() => {
    const node = stageRef.current;
    if (!node) return;
    const measure = () => {
      const rect = node.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      setStageSize((current) =>
        Math.abs(current.width - rect.width) < 0.5 &&
        Math.abs(current.height - rect.height) < 0.5
          ? current
          : { width: rect.width, height: rect.height },
      );
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  useEffect(
    () => () => {
      document.body.classList.remove(
        "is-moving-server-panel",
        "is-resizing-server-panel",
      );
    },
    [],
  );

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

  function startPanelMove(
    panel: ServerPanelId,
    event: PointerEvent<HTMLButtonElement>,
  ) {
    if (!layoutEditing || event.button !== 0) return;
    const stage = stageRef.current;
    if (!stage) return;
    event.preventDefault();
    event.stopPropagation();
    setActivePanel(panel);
    const bounds = stage.getBoundingClientRect();
    if (bounds.width <= 0 || bounds.height <= 0) return;
    const startRect = effectiveLayout.rects[panel];
    const startX = event.clientX;
    const startY = event.clientY;
    const onMove = (moveEvent: globalThis.PointerEvent) => {
      const next = moveServerPanelRect(
        panel,
        startRect,
        (moveEvent.clientX - startX) / bounds.width,
        (moveEvent.clientY - startY) / bounds.height,
        { width: bounds.width, height: bounds.height },
      );
      setLayout((current) => ({
        rects: {
          ...current.rects,
          [panel]: next,
        },
      }));
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onUp);
      document.body.classList.remove("is-moving-server-panel");
    };
    document.body.classList.add("is-moving-server-panel");
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onUp);
  }

  function startPanelResize(
    panel: ServerPanelId,
    event: PointerEvent<HTMLButtonElement>,
  ) {
    if (!layoutEditing || event.button !== 0) return;
    const stage = stageRef.current;
    if (!stage) return;
    event.preventDefault();
    event.stopPropagation();
    setActivePanel(panel);
    const bounds = stage.getBoundingClientRect();
    if (bounds.width <= 0 || bounds.height <= 0) return;
    const startRect = effectiveLayout.rects[panel];
    const startX = event.clientX;
    const startY = event.clientY;
    const onMove = (moveEvent: globalThis.PointerEvent) => {
      const next = resizeServerPanelRect(
        panel,
        startRect,
        (moveEvent.clientX - startX) / bounds.width,
        (moveEvent.clientY - startY) / bounds.height,
        { width: bounds.width, height: bounds.height },
      );
      setLayout((current) => ({
        rects: {
          ...current.rects,
          [panel]: next,
        },
      }));
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onUp);
      document.body.classList.remove("is-resizing-server-panel");
    };
    document.body.classList.add("is-resizing-server-panel");
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onUp);
  }

  function handlePanelKeyDown(
    panel: ServerPanelId,
    event: ReactKeyboardEvent<HTMLButtonElement>,
  ) {
    if (!layoutEditing) return;
    const step = event.shiftKey ? 0.05 : 0.01;
    let deltaX = 0;
    let deltaY = 0;
    if (event.key === "ArrowLeft") deltaX = -step;
    else if (event.key === "ArrowRight") deltaX = step;
    else if (event.key === "ArrowUp") deltaY = -step;
    else if (event.key === "ArrowDown") deltaY = step;
    else return;
    event.preventDefault();
    setLayout((current) => ({
      rects: {
        ...current.rects,
        [panel]: moveServerPanelRect(
          panel,
          effectiveLayout.rects[panel],
          deltaX,
          deltaY,
          stageSize,
        ),
      },
    }));
  }

  function handleResizeKeyDown(
    panel: ServerPanelId,
    event: ReactKeyboardEvent<HTMLButtonElement>,
  ) {
    if (!layoutEditing) return;
    const step = event.shiftKey ? 0.05 : 0.01;
    let deltaW = 0;
    let deltaH = 0;
    if (event.key === "ArrowLeft") deltaW = -step;
    else if (event.key === "ArrowRight") deltaW = step;
    else if (event.key === "ArrowUp") deltaH = -step;
    else if (event.key === "ArrowDown") deltaH = step;
    else return;
    event.preventDefault();
    setLayout((current) => ({
      rects: {
        ...current.rects,
        [panel]: resizeServerPanelRect(
          panel,
          effectiveLayout.rects[panel],
          deltaW,
          deltaH,
          stageSize,
        ),
      },
    }));
  }

  function resetLayout() {
    setLayout(normalizeServerLayout(DEFAULT_SERVER_LAYOUT));
    setActivePanel("viewer");
  }

  function navigateRemote(path: string) {
    if (!active) return;
    const target = normalizeRemotePath(
      path.trim() || scan?.homePath || active.modsPath || "/",
    );
    setBrowsePath(target);
    setPathInput(target);
    setSelectedFilePath(null);
    onLoadFiles(active.id, target);
  }

  const displayPath = browsePath || active?.modsPath || "";
  const breadcrumbs = remoteBreadcrumbs(displayPath);
  const selectedFile = files.find((file) => file.path === selectedFilePath) ?? null;
  const homePath = scan?.homePath || "/";
  const canModifyDirectory = Boolean(
    active &&
      displayPath &&
      ((active.modsPath && isRemotePathWithin(active.modsPath, displayPath)) ||
        (active.ue4ssPath && isRemotePathWithin(active.ue4ssPath, displayPath))),
  );
  const uploadKind: SftpUploadKind =
    active?.ue4ssPath && isRemotePathWithin(active.ue4ssPath, displayPath)
      ? "ue4ss"
      : "pak";

  const accountPanel = (
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
                {scan?.detectedModsPath || active.modsPath || t("server.scanNotLocated")}
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
  );

  const filesPanel = (
    <section className="server-browser">
      <div className="section-title server-browser-title">
        <span>{t("server.remoteFiles")}</span>
        <b>{t("server.fileCount", { count: files.length })}</b>
      </div>
      {active ? (
        <div className="remote-browser-navigation">
          <form
            className="remote-path-form"
            onSubmit={(event) => {
              event.preventDefault();
              navigateRemote(pathInput);
            }}
          >
            <div className="remote-path-controls">
              <button
                type="button"
                className="remote-path-icon"
                aria-label={t("server.homeDirectory")}
                title={t("server.homeDirectory")}
                onClick={() => navigateRemote(homePath)}
                disabled={loading}
              >
                <Icon name="folder" size={15} />
              </button>
              <button
                type="button"
                className="remote-path-icon"
                aria-label={t("server.parentDirectory")}
                title={t("server.parentDirectory")}
                onClick={() => navigateRemote(remoteParent(displayPath))}
                disabled={loading || displayPath === "/"}
              >
                <Icon name="chevronRight" size={14} className="is-reversed" />
              </button>
              <input
                aria-label={t("server.remotePath")}
                value={pathInput}
                onChange={(event) => setPathInput(event.target.value)}
                placeholder={t("server.pathPlaceholder")}
                spellCheck={false}
                disabled={loading}
              />
              <Button
                type="submit"
                size="sm"
                icon="arrow"
                disabled={loading || !pathInput.trim()}
              >
                {t("server.goToPath")}
              </Button>
            </div>
          </form>
          <nav className="remote-breadcrumbs" aria-label={t("server.breadcrumbs")}>
            {breadcrumbs.map((crumb, index) => (
              <span key={crumb.path}>
                {index > 0 ? <i>/</i> : null}
                <button
                  type="button"
                  onClick={() => navigateRemote(crumb.path)}
                  disabled={loading}
                  aria-current={index === breadcrumbs.length - 1 ? "page" : undefined}
                >
                  {crumb.name}
                </button>
              </span>
            ))}
          </nav>
          <div className="remote-root-switches">
            <button
              type="button"
              onClick={() => active.modsPath && navigateRemote(active.modsPath)}
              disabled={loading || !active.modsPath}
              className={
                active.modsPath &&
                displayPath === normalizeRemotePath(active.modsPath)
                  ? "is-active"
                  : ""
              }
            >
              {t("server.pakRoot")}
            </button>
            <button
              type="button"
              onClick={() => active.ue4ssPath && navigateRemote(active.ue4ssPath)}
              disabled={loading || !active.ue4ssPath}
              className={
                active.ue4ssPath &&
                displayPath === normalizeRemotePath(active.ue4ssPath)
                  ? "is-active"
                  : ""
              }
            >
              {t("server.ue4ssRoot")}
            </button>
          </div>
        </div>
      ) : null}
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
          title={t(
            scan
              ? "server.emptyDirectoryTitle"
              : "server.empty.noFilesTitle",
          )}
          description={t(
            scan
              ? "server.emptyDirectoryDescription"
              : "server.empty.noFilesDescription",
          )}
          action={
            <Button
              icon="refresh"
              onClick={() => navigateRemote(displayPath || active.modsPath)}
              disabled={loading}
            >
              {t("server.readDirectory")}
            </Button>
          }
        />
      ) : (
        <div className="remote-file-list">
          {files.map((file) => {
            const extension = remoteFileExtension(file.name);
            const content = (
              <>
                <span
                  className={`file-symbol ${file.isDirectory ? "is-folder" : ""}`}
                >
                  <Icon name={remoteFileIcon(file)} size={16} />
                </span>
                <div>
                  <b>{file.name}</b>
                  <span>
                    {file.isDirectory
                      ? t("common.directory")
                      : extension
                        ? `${extension.toUpperCase()} · ${formatBytes(file.size)}`
                        : formatBytes(file.size)}
                  </span>
                </div>
                <span>{formatDate(file.modifiedAt, language)}</span>
              </>
            );
            return (
              <button
                type="button"
                className={[
                  "remote-file-row",
                  file.isDirectory ? "is-browsable" : "",
                  selectedFilePath === file.path ? "is-selected" : "",
                ]
                  .filter(Boolean)
                  .join(" ")}
                key={file.path}
                title={file.path}
                aria-label={
                  file.isDirectory
                    ? `${t("server.openFolder")} ${file.name}`
                    : file.name
                }
                onClick={() => {
                  if (file.isDirectory) {
                    navigateRemote(file.path);
                  } else {
                    setSelectedFilePath(file.path);
                  }
                }}
              >
                {content}
              </button>
            );
          })}
        </div>
      )}
      {selectedFile ? (
        <div className="remote-file-selection" aria-live="polite">
          <div>
            <b>{selectedFile.name}</b>
            <code>{selectedFile.path}</code>
          </div>
          <div className="remote-file-selection-actions">
            <span>
              {selectedFile.isDirectory
                ? t("common.directory")
                : formatBytes(selectedFile.size)}
            </span>
            {!selectedFile.isDirectory && active ? (
              <Button
                size="sm"
                icon="download"
                onClick={() =>
                  void onDownload(active.id, selectedFile.path, selectedFile.name)
                }
                disabled={loading}
              >
                {t("server.downloadFile")}
              </Button>
            ) : null}
          </div>
        </div>
      ) : null}
      {active && displayPath && !canModifyDirectory ? (
        <p className="server-browser-readonly">{t("server.readOnlyDirectory")}</p>
      ) : null}
      <div className="server-browser-actions">
        <Button
          icon="chevronRight"
          className="is-reversed"
          onClick={() => navigateRemote(remoteParent(displayPath))}
          disabled={loading || displayPath === "/"}
        >
          {t("server.parentDirectory")}
        </Button>
        <Button
          icon="folder"
          onClick={() => navigateRemote(homePath)}
          disabled={loading || displayPath === homePath}
        >
          {t("server.homeDirectory")}
        </Button>
        <Button
          icon="refresh"
          onClick={() => navigateRemote(displayPath)}
          disabled={!active || loading}
        >
          {t("server.refreshDirectory")}
        </Button>
        {canModifyDirectory ? (
          <Button
            icon="upload"
            onClick={() => active && void onUpload(active.id, uploadKind)}
            disabled={!active || loading}
          >
            {uploadKind === "ue4ss"
              ? t("remoteViewer.uploadUe4ss")
              : t("server.upload")}
          </Button>
        ) : null}
      </div>
    </section>
  );

  const viewerPanel = (
    <div className="server-viewer-panel">
      {connected && scan && active ? (
        <RemoteModViewer
          scan={scan}
          notes={notes}
          conflicts={conflicts}
          conflictLoading={conflictLoading}
          progress={conflictProgress}
          loading={loading || conflictLoading}
          onUpload={(kind) => onUpload(active.id, kind)}
          onRename={(path, newName) => onRename(active.id, path, newName)}
          onDelete={(path) => onDelete(active.id, path)}
          onSaveNote={(path, note) => onSaveNote(active.id, path, note)}
          onAnalyzeConflicts={() => onAnalyzeConflicts(active.id)}
        />
      ) : (
        <EmptyState
          icon="box"
          title={t("remoteViewer.offlineTitle")}
          description={t("remoteViewer.offlineDescription")}
        />
      )}
    </div>
  );

  const panels: Record<ServerPanelId, React.ReactNode> = {
    account: accountPanel,
    files: filesPanel,
    viewer: viewerPanel,
  };

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

      <div className="server-workspace-toolbar">
        <div>
          <b>{t("serverLayout.title")}</b>
          <span>
            {t(layoutEditing ? "serverLayout.editing" : "serverLayout.locked")} ·{" "}
            {t("serverLayout.hint")}
          </span>
        </div>
        <div className="server-layout-actions">
          <Button
            size="sm"
            icon={layoutEditing ? "check" : "edit"}
            className={layoutEditing ? "is-active" : ""}
            onClick={() => setLayoutEditing((current) => !current)}
          >
            {t(
              layoutEditing
                ? "serverLayout.finishEditing"
                : "serverLayout.edit",
            )}
          </Button>
          <Button size="sm" icon="refresh" onClick={resetLayout}>
            {t("serverLayout.reset")}
          </Button>
        </div>
      </div>

      <div
        ref={stageRef}
        className={`server-panel-stage ${layoutEditing ? "is-editing" : ""}`}
      >
        {SERVER_PANEL_ORDER.map((panel, index) => {
          const rect = effectiveLayout.rects[panel];
          return (
            <article
              key={panel}
              className={[
                "server-panel-slot",
                `panel-${panel}`,
                activePanel === panel ? "is-active" : "",
                layoutEditing ? "is-editable" : "is-locked",
              ].join(" ")}
              style={{
                left: `${rect.x * 100}%`,
                top: `${rect.y * 100}%`,
                width: `${rect.w * 100}%`,
                height: `${rect.h * 100}%`,
                zIndex: activePanel === panel ? 5 : index + 1,
              }}
              onPointerDownCapture={() => setActivePanel(panel)}
            >
              <header className="server-panel-bar">
                {layoutEditing ? (
                  <button
                    type="button"
                    className="server-panel-drag"
                    title={`${t("serverLayout.dragHint")} · ${t(
                      "serverLayout.keyboardHint",
                    )}`}
                    aria-label={`${t("serverLayout.dragHint")} ${t(
                      PANEL_LABEL_KEYS[panel],
                    )}`}
                    onPointerDown={(event) => startPanelMove(panel, event)}
                    onKeyDown={(event) => handlePanelKeyDown(panel, event)}
                  >
                    <Icon name="drag" size={13} />
                    <span>{t(PANEL_LABEL_KEYS[panel])}</span>
                  </button>
                ) : (
                  <div className="server-panel-drag is-locked">
                    <span>{t(PANEL_LABEL_KEYS[panel])}</span>
                  </div>
                )}
                {layoutEditing ? (
                  <span className="server-panel-size">
                    {Math.round(rect.w * 100)}% × {Math.round(rect.h * 100)}%
                  </span>
                ) : null}
              </header>
              <div className="server-panel-content">{panels[panel]}</div>
              {layoutEditing ? (
                <button
                  type="button"
                  className="server-panel-resizer"
                  aria-label={t("serverLayout.resizeHint", {
                    panel: t(PANEL_LABEL_KEYS[panel]),
                  })}
                  onPointerDown={(event) => startPanelResize(panel, event)}
                  onKeyDown={(event) => handleResizeKeyDown(panel, event)}
                >
                  <span />
                </button>
              ) : null}
            </article>
          );
        })}
      </div>
    </section>
  );
}
