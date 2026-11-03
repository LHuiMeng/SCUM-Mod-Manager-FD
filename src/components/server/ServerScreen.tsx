import { useEffect, useState } from "react";
import type {
  RemoteFile,
  SftpAccount,
  SftpConflictProgress,
  SftpConflictReport,
  SftpConnectionResult,
  SftpUploadKind,
} from "../../types";
import { useI18n } from "../../i18n";
import { isRemotePathWithin, normalizeRemotePath } from "../../lib/remotePath";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { Modal } from "../ui/Modal";
import { RemoteBrowser } from "./RemoteBrowser";
import { RemoteModViewer } from "./RemoteModViewer";
import { ServerAccountBar } from "./ServerAccountBar";
import { ServerAccountForm, type SftpTrustPrompt } from "./ServerAccountForm";

export interface ServerScreenProps {
  accounts: SftpAccount[];
  activeAccountId: string | null;
  files: RemoteFile[];
  loading: boolean;
  error: string | null;
  trustPrompt: SftpTrustPrompt | null;
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
  onMkdir: (accountId: string, targetPath: string) => Promise<boolean>;
  onMove: (accountId: string, path: string, newPath: string) => Promise<boolean>;
  onDownloadToLibrary: (accountId: string, path: string) => void;
  onSwitchAccount: (accountId: string) => void;
}

/**
 * 服务器页：连接后双列固定布局（左 = 账户条 + 文件浏览，右 = 模组布局查看器），
 * 未连接时整页内联账户表单。可拖动的浮动面板系统已移除。
 */
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
  onMkdir,
  onMove,
  onDownloadToLibrary,
  onSwitchAccount,
}: ServerScreenProps) {
  const { t } = useI18n();
  const active =
    accounts.find((account) => account.id === activeAccountId) ??
    accounts[0] ??
    null;
  const connected = Boolean(scan?.ok && connectedAccountId === active?.id);
  const [manageOpen, setManageOpen] = useState(false);
  const [newAccountOpen, setNewAccountOpen] = useState(false);
  const [browsePath, setBrowsePath] = useState(() =>
    active?.modsPath ? normalizeRemotePath(active.modsPath) : "",
  );
  const [pathInput, setPathInput] = useState(() =>
    active?.modsPath ? normalizeRemotePath(active.modsPath) : "",
  );

  // 换账户或根目录变化时，浏览位置回到 PAK 根。
  useEffect(() => {
    const nextPath = active?.modsPath
      ? normalizeRemotePath(active.modsPath)
      : "";
    setBrowsePath(nextPath);
    setPathInput(nextPath);
  }, [active?.id, active?.modsPath]);

  function navigateRemote(path: string) {
    if (!active) return;
    const target = normalizeRemotePath(
      path.trim() || scan?.homePath || active.modsPath || "/",
    );
    setBrowsePath(target);
    setPathInput(target);
    onLoadFiles(active.id, target);
  }

  const displayPath = browsePath || active?.modsPath || "";
  const canModify = Boolean(
    active &&
      displayPath &&
      ((active.modsPath &&
        isRemotePathWithin(active.modsPath, displayPath)) ||
        (active.ue4ssPath &&
          isRemotePathWithin(active.ue4ssPath, displayPath))),
  );
  const uploadKind: SftpUploadKind =
    active?.ue4ssPath && isRemotePathWithin(active.ue4ssPath, displayPath)
      ? "ue4ss"
      : "pak";

  return (
    <section className="page page-server">
      <header className="page-header">
        <div>
          <h1>{t("server.title")}</h1>
          <p>{t("server.subtitle")}</p>
        </div>
        <div className="heading-tools">
          {active ? (
            <Button
              icon="server"
              onClick={() => onTestAccount(active.id)}
              disabled={loading}
            >
              {t("server.testConnection")}
            </Button>
          ) : null}
          <Button icon="settings" onClick={onOpenSettings}>
            {t("server.accountSettings")}
          </Button>
        </div>
      </header>

      {active && connected && scan ? (
        <div className="server-workspace-grid">
          <div className="server-pane server-pane-files">
            <ServerAccountBar
              accounts={accounts}
              active={active}
              connected={connected}
              scan={scan}
              onSwitchAccount={onSwitchAccount}
              onNewAccount={() => setNewAccountOpen(true)}
              onManage={() => setManageOpen(true)}
            />
            <RemoteBrowser
              scan={scan}
              files={files}
              loading={loading}
              error={error}
              browsePath={displayPath}
              pathInput={pathInput}
              onPathInputChange={setPathInput}
              onNavigate={navigateRemote}
              onRetry={() => onTestAccount(active.id)}
              onMkdir={(target) => onMkdir(active.id, target)}
              onUpload={(kind) => onUpload(active.id, kind)}
              onDownload={(path, name) => onDownload(active.id, path, name)}
              onDownloadToLibrary={(path) => onDownloadToLibrary(active.id, path)}
              onRename={(path, newName) => onRename(active.id, path, newName)}
              onMove={(path, target) => onMove(active.id, path, target)}
              onDelete={(path) => onDelete(active.id, path)}
              onNote={(path, note) => onSaveNote(active.id, path, note)}
              notes={notes}
              canModify={canModify}
              uploadKind={uploadKind}
            />
          </div>
          <div className="server-pane server-pane-viewer panel-viewer">
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
          </div>
        </div>
      ) : (
        <div className="server-disconnected">
          <ServerAccountForm
            accounts={accounts}
            editing={active}
            connected={false}
            trustPrompt={trustPrompt}
            onDismissTrust={onDismissTrust}
            onTrustHost={onTrustHost}
            onSaveAccount={onSaveAccount}
          />
          {active ? (
            <EmptyState
              icon="serverOff"
              title={t("server.empty.failedTitle")}
              description={error ?? t("remoteViewer.offlineDescription")}
              action={
                <Button onClick={() => onTestAccount(active.id)} disabled={loading}>
                  {t("server.empty.retry")}
                </Button>
              }
            />
          ) : (
            <EmptyState
              icon="server"
              title={t("server.empty.noAccountTitle")}
              description={t("server.empty.noAccountDescription")}
            />
          )}
        </div>
      )}

      {manageOpen && active ? (
        <Modal
          title={t("server.manageAccount")}
          onClose={() => setManageOpen(false)}
          footer={
            <Button onClick={() => setManageOpen(false)}>
              {t("common.cancel")}
            </Button>
          }
        >
          <ServerAccountForm
            accounts={accounts}
            editing={active}
            connected
            trustPrompt={trustPrompt}
            onDismissTrust={onDismissTrust}
            onTrustHost={onTrustHost}
            onSaveAccount={onSaveAccount}
          />
        </Modal>
      ) : null}

      {newAccountOpen ? (
        <Modal
          title={t("server.newAccount")}
          onClose={() => setNewAccountOpen(false)}
          footer={
            <Button onClick={() => setNewAccountOpen(false)}>
              {t("common.cancel")}
            </Button>
          }
        >
          <ServerAccountForm
            accounts={accounts}
            editing={null}
            connected={connected}
            trustPrompt={null}
            onDismissTrust={onDismissTrust}
            onTrustHost={onTrustHost}
            onSaveAccount={onSaveAccount}
          />
        </Modal>
      ) : null}
    </section>
  );
}
