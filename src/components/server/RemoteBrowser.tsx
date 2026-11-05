import { useEffect, useState } from "react";
import type {
  RemoteFile,
  SftpConnectionResult,
  SftpUploadKind,
} from "../../types";
import { useI18n } from "../../i18n";
import { formatBytes } from "../../lib/format";
import {
  normalizeRemotePath,
  remoteBreadcrumbs,
  remoteParent,
} from "../../lib/remotePath";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";
import { RemoteTable } from "./RemoteTable";

export interface RemoteBrowserProps {
  scan: SftpConnectionResult;
  files: RemoteFile[];
  loading: boolean;
  error: string | null;
  browsePath: string;
  pathInput: string;
  onPathInputChange: (value: string) => void;
  onNavigate: (path: string) => void;
  onRetry: () => void;
  onMkdir: (targetPath: string) => Promise<boolean>;
  onUpload: (kind: SftpUploadKind) => void;
  onDownload: (path: string, name: string) => void;
  onDownloadToLibrary: (path: string) => void;
  onRename: (path: string, newName: string) => Promise<string | null>;
  onMove: (path: string, newPath: string) => Promise<boolean>;
  onDelete: (path: string) => Promise<boolean>;
  onNote: (path: string, note: string) => Promise<boolean>;
  notes: Record<string, string>;
  canModify: boolean;
  uploadKind: SftpUploadKind;
}

/**
 * 文件浏览列：路径栏（home/parent/输入/面包屑/根切换）+ 工具栏（刷新/新建/上传）
 * + 表格 + 选中操作条。移动/删除/备注走弹窗；新建文件夹走内联输入。
 */
export function RemoteBrowser({
  scan,
  files,
  loading,
  error,
  browsePath,
  pathInput,
  onPathInputChange,
  onNavigate,
  onRetry,
  onMkdir,
  onUpload,
  onDownload,
  onDownloadToLibrary,
  onRename,
  onMove,
  onDelete,
  onNote,
  notes,
  canModify,
  uploadKind,
}: RemoteBrowserProps) {
  const { t } = useI18n();
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [mkdirOpen, setMkdirOpen] = useState(false);
  const [mkdirName, setMkdirName] = useState("");
  const [moving, setMoving] = useState(false);
  const [moveSource, setMoveSource] = useState<string | null>(null);
  const [moveTarget, setMoveTarget] = useState("");
  const [deleteTarget, setDeleteTarget] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [noteTarget, setNoteTarget] = useState<string | null>(null);
  const [noteValue, setNoteValue] = useState("");
  const [savingNote, setSavingNote] = useState(false);

  // 换目录后选中态失效。
  useEffect(() => {
    setSelectedPath(null);
  }, [browsePath]);

  const breadcrumbs = remoteBreadcrumbs(browsePath);
  const selected = files.find((file) => file.path === selectedPath) ?? null;
  const currentDir = browsePath.replace(/\/+$/, "") || "/";

  function entryName(path: string): string {
    return path.split("/").filter(Boolean).pop() ?? path;
  }

  async function commitMkdir() {
    const name = mkdirName.trim();
    if (!name || !currentDir) return;
    const ok = await onMkdir(normalizeRemotePath(`${currentDir}/${name}`));
    if (ok) {
      setMkdirOpen(false);
      setMkdirName("");
    }
  }

  function openMove(path: string) {
    setMoveSource(path);
    setMoveTarget(normalizeRemotePath(`${currentDir}/${entryName(path)}`));
  }

  async function commitMove() {
    if (!moveSource || moving) return;
    const target = normalizeRemotePath(moveTarget);
    setMoving(true);
    const ok = await onMove(moveSource, target);
    setMoving(false);
    if (ok) {
      setMoveSource(null);
      setMoveTarget("");
    }
  }

  async function commitDelete() {
    if (!deleteTarget || deleting) return;
    setDeleting(true);
    const ok = await onDelete(deleteTarget);
    setDeleting(false);
    if (ok) {
      setDeleteTarget(null);
      setSelectedPath(null);
    }
  }

  function openNote(path: string) {
    setNoteTarget(path);
    setNoteValue(notes[path] ?? "");
  }

  async function commitNote() {
    if (!noteTarget || savingNote) return;
    setSavingNote(true);
    const ok = await onNote(noteTarget, noteValue);
    setSavingNote(false);
    if (ok) setNoteTarget(null);
  }

  return (
    <div className="remote-browser">
      <div className="remote-browser-navigation">
        <form
          className="remote-path-form"
          onSubmit={(event) => {
            event.preventDefault();
            onNavigate(pathInput);
          }}
        >
          <div className="remote-path-controls">
            <button
              type="button"
              className="remote-path-icon"
              aria-label={t("server.homeDirectory")}
              title={t("server.homeDirectory")}
              onClick={() => onNavigate(scan.homePath ?? "/")}
              disabled={loading}
            >
              <Icon name="folder" size={15} />
            </button>
            <button
              type="button"
              className="remote-path-icon"
              aria-label={t("server.parentDirectory")}
              title={t("server.parentDirectory")}
              onClick={() => onNavigate(remoteParent(browsePath))}
              disabled={loading || browsePath === "/"}
            >
              <Icon name="chevronRight" size={14} className="is-reversed" />
            </button>
            <input
              aria-label={t("server.remotePath")}
              value={pathInput}
              onChange={(event) => onPathInputChange(event.target.value)}
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
                onClick={() => onNavigate(crumb.path)}
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
            onClick={() => scan.detectedModsPath && onNavigate(scan.detectedModsPath)}
            disabled={loading || !scan.detectedModsPath}
            className={
              scan.detectedModsPath &&
              browsePath === normalizeRemotePath(scan.detectedModsPath)
                ? "is-active"
                : ""
            }
          >
            {t("server.pakRoot")}
          </button>
          <button
            type="button"
            onClick={() =>
              scan.detectedUe4ssPath && onNavigate(scan.detectedUe4ssPath)
            }
            disabled={loading || !scan.detectedUe4ssPath}
            className={
              scan.detectedUe4ssPath &&
              browsePath === normalizeRemotePath(scan.detectedUe4ssPath)
                ? "is-active"
                : ""
            }
          >
            {t("server.ue4ssRoot")}
          </button>
        </div>
      </div>

      <div className="remote-toolbar">
        <Button
          size="sm"
          icon="refresh"
          onClick={() => onNavigate(browsePath)}
          disabled={loading}
        >
          {t("server.refreshDirectory")}
        </Button>
        {canModify ? (
          <>
            <Button
              size="sm"
              icon="plus"
              onClick={() => setMkdirOpen((current) => !current)}
              disabled={loading}
            >
              {t("server.browser.newFolder")}
            </Button>
            <Button
              size="sm"
              icon="upload"
              onClick={() => onUpload(uploadKind)}
              disabled={loading}
            >
              {uploadKind === "ue4ss" ? t("remoteViewer.uploadUe4ss") : t("server.upload")}
            </Button>
          </>
        ) : null}
      </div>

      {mkdirOpen ? (
        <div className="remote-mkdir-row">
          <input
            autoFocus
            value={mkdirName}
            onChange={(event) => setMkdirName(event.target.value)}
            placeholder={t("server.browser.newFolderPlaceholder")}
            onKeyDown={(event) => {
              if (event.nativeEvent.isComposing || event.keyCode === 229) return;
              if (event.key === "Enter") void commitMkdir();
              if (event.key === "Escape") setMkdirOpen(false);
            }}
          />
          <Button
            size="sm"
            variant="primary"
            icon="check"
            onClick={() => void commitMkdir()}
            disabled={!mkdirName.trim() || loading}
          >
            {t("server.browser.create")}
          </Button>
        </div>
      ) : null}

      {error ? (
        <EmptyState
          icon="serverOff"
          title={t("server.empty.failedTitle")}
          description={error}
          action={
            <Button onClick={onRetry} disabled={loading}>
              {t("server.empty.retry")}
            </Button>
          }
        />
      ) : files.length === 0 ? (
        <EmptyState
          icon="folder"
          title={t("server.emptyDirectoryTitle")}
          description={t("server.emptyDirectoryDescription")}
          action={
            <Button
              icon="refresh"
              onClick={() => onNavigate(browsePath)}
              disabled={loading}
            >
              {t("server.readDirectory")}
            </Button>
          }
        />
      ) : (
        <RemoteTable
          files={files}
          loading={loading}
          canModify={canModify}
          uploadKind={uploadKind}
          selectedPath={selectedPath}
          onSelect={setSelectedPath}
          onOpenFolder={(path) => onNavigate(path)}
          onDownload={onDownload}
          onDownloadToLibrary={onDownloadToLibrary}
          onRename={onRename}
          onMoveClick={openMove}
          onDeleteClick={setDeleteTarget}
          onNoteClick={openNote}
        />
      )}

      {selected ? (
        <div className="remote-file-selection" aria-live="polite">
          <div>
            <b>{selected.name}</b>
            <code>{selected.path}</code>
          </div>
          <div className="remote-file-selection-actions">
            <span>
              {selected.isDirectory
                ? t("common.directory")
                : formatBytes(selected.size)}
            </span>
            {!selected.isDirectory ? (
              <Button
                size="sm"
                icon="download"
                onClick={() => onDownload(selected.path, selected.name)}
                disabled={loading}
              >
                {t("server.downloadFile")}
              </Button>
            ) : null}
            <Button size="sm" icon="plus" onClick={() => onDownloadToLibrary(selected.path)} disabled={loading}>
              {t("server.downloadToLibrary")}
            </Button>
            {canModify ? (
              <>
                <Button size="sm" icon="arrow" onClick={() => openMove(selected.path)} disabled={loading}>
                  {t("server.rowActions.move")}
                </Button>
                <Button size="sm" icon="trash" onClick={() => setDeleteTarget(selected.path)} disabled={loading}>
                  {t("server.rowActions.delete")}
                </Button>
              </>
            ) : null}
            <Button size="sm" icon="terminal" onClick={() => openNote(selected.path)} disabled={loading}>
              {t("server.rowActions.note")}
            </Button>
          </div>
        </div>
      ) : null}

      {browsePath && !canModify ? (
        <p className="server-browser-readonly">{t("server.readOnlyDirectory")}</p>
      ) : null}

      {moveSource ? (
        <Modal
          title={t("server.moveTitle")}
          onClose={() => setMoveSource(null)}
          footer={
            <>
              <Button
                variant="primary"
                icon="arrow"
                onClick={() => void commitMove()}
                disabled={moving || !moveTarget.trim()}
              >
                {t("server.moveConfirm")}
              </Button>
              <Button onClick={() => setMoveSource(null)}>{t("common.cancel")}</Button>
            </>
          }
        >
          <p>{t("server.moveHint", { name: entryName(moveSource) })}</p>
          <label>
            <span>{t("server.moveTarget")}</span>
            <input
              autoFocus
              value={moveTarget}
              onChange={(event) => setMoveTarget(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") void commitMove();
              }}
              spellCheck={false}
            />
          </label>
        </Modal>
      ) : null}

      {deleteTarget ? (
        <Modal
          title={t("server.deleteTitle")}
          onClose={() => setDeleteTarget(null)}
          footer={
            <>
              <Button
                variant="danger"
                icon="trash"
                onClick={() => void commitDelete()}
                disabled={deleting}
              >
                {t("server.deleteConfirm")}
              </Button>
              <Button onClick={() => setDeleteTarget(null)}>{t("common.cancel")}</Button>
            </>
          }
        >
          <p>{t("server.deleteHint", { name: entryName(deleteTarget) })}</p>
          <code>{deleteTarget}</code>
        </Modal>
      ) : null}

      {noteTarget ? (
        <Modal
          title={t("server.noteTitle")}
          onClose={() => setNoteTarget(null)}
          footer={
            <>
              <Button
                variant="primary"
                icon="lock"
                onClick={() => void commitNote()}
                disabled={savingNote}
              >
                {t("server.noteSave")}
              </Button>
              <Button onClick={() => setNoteTarget(null)}>{t("common.cancel")}</Button>
            </>
          }
        >
          <p>{t("server.noteHint", { name: entryName(noteTarget) })}</p>
          <textarea
            autoFocus
            rows={3}
            value={noteValue}
            onChange={(event) => setNoteValue(event.target.value)}
            placeholder={t("server.notePlaceholder")}
          />
        </Modal>
      ) : null}
    </div>
  );
}
