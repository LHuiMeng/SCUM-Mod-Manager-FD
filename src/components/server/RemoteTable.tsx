import { useMemo, useState } from "react";
import type { RemoteFile, SftpUploadKind } from "../../types";
import { useI18n } from "../../i18n";
import { formatBytes, formatDate } from "../../lib/format";
import { Button } from "../ui/Button";
import { Icon, type IconName } from "../ui/Icon";

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

type SortKey = "name" | "size" | "modifiedAt";

export interface RemoteTableProps {
  files: RemoteFile[];
  loading: boolean;
  canModify: boolean;
  uploadKind: SftpUploadKind;
  selectedPath: string | null;
  onSelect: (path: string) => void;
  onOpenFolder: (path: string) => void;
  onDownload: (path: string, name: string) => void;
  onDownloadToLibrary: (path: string) => void;
  onRename: (path: string, newName: string) => Promise<string | null>;
  onMoveClick: (path: string) => void;
  onDeleteClick: (path: string) => void;
  onNoteClick: (path: string) => void;
}

/**
 * 远端文件表格。行容器是 div（不是 button），文件名单元格点击负责
 * 进目录 / 选中，右侧操作按钮是兄弟节点 —— 避免 <button> 嵌套在
 * WebView2 里点错目标。
 */
export function RemoteTable({
  files,
  loading,
  canModify,
  uploadKind,
  selectedPath,
  onSelect,
  onOpenFolder,
  onDownload,
  onDownloadToLibrary,
  onRename,
  onMoveClick,
  onDeleteClick,
  onNoteClick,
}: RemoteTableProps) {
  const { t, language } = useI18n();
  const [sortKey, setSortKey] = useState<SortKey>("name");
  const [sortDir, setSortDir] = useState<1 | -1>(1);
  const [renamePath, setRenamePath] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");
  const [renaming, setRenaming] = useState(false);

  const sorted = useMemo(() => {
    const copy = [...files];
    copy.sort((a, b) => {
      if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
      let cmp = 0;
      if (sortKey === "name") cmp = a.name.localeCompare(b.name);
      else if (sortKey === "size")
        cmp =
          (a.isDirectory ? -1 : a.size) - (b.isDirectory ? -1 : b.size);
      else cmp = (a.modifiedAt ?? "").localeCompare(b.modifiedAt ?? "");
      return cmp * sortDir || a.name.localeCompare(b.name);
    });
    return copy;
  }, [files, sortKey, sortDir]);

  function toggleSort(key: SortKey) {
    if (key === sortKey) {
      setSortDir((current) => (current === 1 ? -1 : 1));
    } else {
      setSortKey(key);
      setSortDir(1);
    }
  }

  function startRename(file: RemoteFile) {
    setRenamePath(file.path);
    setRenameValue(file.name);
  }

  async function commitRename() {
    if (!renamePath || renaming) return;
    const source = files.find((file) => file.path === renamePath);
    const nextName = renameValue.trim();
    setRenamePath(null);
    if (!source || !nextName || nextName === source.name) return;
    setRenaming(true);
    try {
      const result = await onRename(renamePath, nextName);
      if (result) setRenameValue("");
    } finally {
      setRenaming(false);
    }
  }

  function sortIndicator(key: SortKey) {
    if (key !== sortKey) return "";
    return sortDir === 1 ? " ↑" : " ↓";
  }

  return (
    <div className="remote-table">
      <div className="remote-table-head" role="row">
        <button
          type="button"
          className={`remote-table-sort${sortKey === "name" ? " is-active" : ""}`}
          onClick={() => toggleSort("name")}
        >
          {t("server.table.name")}
          {sortIndicator("name")}
        </button>
        <button
          type="button"
          className={`remote-table-sort${sortKey === "size" ? " is-active" : ""}`}
          onClick={() => toggleSort("size")}
        >
          {t("server.table.size")}
          {sortIndicator("size")}
        </button>
        <button
          type="button"
          className={`remote-table-sort${sortKey === "modifiedAt" ? " is-active" : ""}`}
          onClick={() => toggleSort("modifiedAt")}
        >
          {t("server.table.modifiedAt")}
          {sortIndicator("modifiedAt")}
        </button>
        <span className="remote-table-actions-label">
          {t("server.table.actions")}
        </span>
      </div>
      <div className="remote-table-body">
        {sorted.map((file) => {
          const extension = remoteFileExtension(file.name);
          const isSig = extension === "sig";
          // 「导入本地库」只对 .pak 文件 / UE4SS 根下的目录有意义（后端同样判断）。
          const canImport = !isSig && (
            file.isDirectory ? uploadKind === "ue4ss" : extension === "pak"
          );
          const selected = selectedPath === file.path;
          const rowActions = [];
          if (!file.isDirectory && !isSig) {
            rowActions.push(
              <Button
                key="download"
                size="icon"
                icon="download"
                title={t("server.rowActions.download")}
                aria-label={`${t("server.rowActions.download")} ${file.name}`}
                onClick={() => onDownload(file.path, file.name)}
                disabled={loading}
              />,
            );
          }
          if (canImport) {
            rowActions.push(
              <Button
                key="import"
                size="icon"
                icon="plus"
                title={t("server.rowActions.importLibrary")}
                aria-label={`${t("server.rowActions.importLibrary")} ${file.name}`}
                onClick={() => onDownloadToLibrary(file.path)}
                disabled={loading}
              />,
            );
          }
          if (canModify && !isSig) {
            rowActions.push(
              <Button
                key="rename"
                size="icon"
                icon="edit"
                title={t("server.rowActions.rename")}
                aria-label={`${t("server.rowActions.rename")} ${file.name}`}
                onClick={() => startRename(file)}
                disabled={loading || renamePath !== null}
              />,
              <Button
                key="move"
                size="icon"
                icon="arrow"
                title={t("server.rowActions.move")}
                aria-label={`${t("server.rowActions.move")} ${file.name}`}
                onClick={() => onMoveClick(file.path)}
                disabled={loading || renamePath !== null}
              />,
              <Button
                key="delete"
                size="icon"
                icon="trash"
                title={t("server.rowActions.delete")}
                aria-label={`${t("server.rowActions.delete")} ${file.name}`}
                onClick={() => onDeleteClick(file.path)}
                disabled={loading}
              />,
            );
          }
          if (!isSig) {
            rowActions.push(
              <Button
                key="note"
                size="icon"
                icon="terminal"
                title={t("server.rowActions.note")}
                aria-label={`${t("server.rowActions.note")} ${file.name}`}
                onClick={() => onNoteClick(file.path)}
                disabled={loading}
              />,
            );
          }
          return (
            <div
              key={file.path}
              className={[
                "remote-file-row",
                file.isDirectory ? "is-browsable" : "",
                selected ? "is-selected" : "",
              ]
                .filter(Boolean)
                .join(" ")}
              tabIndex={0}
              title={file.path}
              onClick={() =>
                file.isDirectory ? onOpenFolder(file.path) : onSelect(file.path)
              }
              onKeyDown={(event) => {
                if (event.key !== "Enter" && event.key !== " ") return;
                event.preventDefault();
                if (file.isDirectory) onOpenFolder(file.path);
                else onSelect(file.path);
              }}
            >
              <div className="remote-file-name">
                <span className={`file-symbol ${file.isDirectory ? "is-folder" : ""}`}>
                  <Icon name={remoteFileIcon(file)} size={16} />
                </span>
                <div className="remote-file-namebox">
                  {renamePath === file.path ? (
                    <input
                      autoFocus
                      value={renameValue}
                      disabled={renaming}
                      onChange={(event) => setRenameValue(event.target.value)}
                      onClick={(event) => event.stopPropagation()}
                      onBlur={() => {
                        if (!renaming) void commitRename();
                      }}
                      onKeyDown={(event) => {
                        event.stopPropagation();
                        if (event.key === "Enter") void commitRename();
                        if (event.key === "Escape") setRenamePath(null);
                      }}
                    />
                  ) : (
                    <b>{file.name}</b>
                  )}
                  <small>
                    {file.isDirectory
                      ? t("common.directory")
                      : extension
                        ? `${extension.toUpperCase()} · ${formatBytes(file.size)}`
                        : formatBytes(file.size)}
                  </small>
                </div>
              </div>
              <span className="remote-file-size">
                {file.isDirectory ? "—" : formatBytes(file.size)}
              </span>
              <span className="remote-file-date">
                {file.modifiedAt ? formatDate(file.modifiedAt, language) : "—"}
              </span>
              <div
                className="remote-row-actions"
                onClick={(event) => event.stopPropagation()}
              >
                {rowActions}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
