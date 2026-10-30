import { useEffect, useMemo, useState } from "react";
import type {
  RemoteFile,
  SftpConflictProgress,
  SftpConflictReport,
  SftpConnectionResult,
  SftpUploadKind,
} from "../../types";
import { useI18n } from "../../i18n";
import { formatBytes, formatDate } from "../../lib/format";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";
import { SearchField } from "../ui/SearchField";

interface RemoteModViewerProps {
  scan: SftpConnectionResult;
  notes: Record<string, string>;
  conflicts: SftpConflictReport | null;
  conflictLoading: boolean;
  progress: SftpConflictProgress | null;
  loading: boolean;
  onUpload: (kind: SftpUploadKind) => Promise<void> | void;
  onRename: (path: string, newName: string) => Promise<string | null>;
  onDelete: (path: string) => Promise<boolean>;
  onSaveNote: (path: string, note: string) => Promise<boolean>;
  onAnalyzeConflicts: () => Promise<void> | void;
}

interface ViewerItem extends RemoteFile {
  kind: SftpUploadKind;
}

type ViewerFilter = "all" | SftpUploadKind;

export function RemoteModViewer({
  scan,
  notes,
  conflicts,
  conflictLoading,
  progress,
  loading,
  onUpload,
  onRename,
  onDelete,
  onSaveNote,
  onAnalyzeConflicts,
}: RemoteModViewerProps) {
  const { t, language } = useI18n();
  const [filter, setFilter] = useState<ViewerFilter>("all");
  const [search, setSearch] = useState("");
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [draftNote, setDraftNote] = useState("");
  const [noteSaving, setNoteSaving] = useState(false);
  const [renameOpen, setRenameOpen] = useState(false);
  const [renameValue, setRenameValue] = useState("");
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [operationBusy, setOperationBusy] = useState(false);

  const items = useMemo<ViewerItem[]>(
    () => [
      ...scan.pakMods.map((file) => ({ ...file, kind: "pak" as const })),
      ...scan.ue4ssMods.map((file) => ({ ...file, kind: "ue4ss" as const })),
    ],
    [scan.pakMods, scan.ue4ssMods],
  );

  const conflictCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const group of conflicts?.groups ?? []) {
      for (const owner of group.owners) {
        counts[owner.path] = (counts[owner.path] ?? 0) + 1;
      }
    }
    return counts;
  }, [conflicts]);

  const filtered = useMemo(() => {
    const query = search.trim().toLowerCase();
    return items.filter(
      (item) =>
        (filter === "all" || item.kind === filter) &&
        (!query || item.name.toLowerCase().includes(query) || item.path.toLowerCase().includes(query)),
    );
  }, [filter, items, search]);

  const selected = items.find((item) => item.path === selectedPath) ?? null;
  const selectedConflicts = useMemo(
    () =>
      (conflicts?.groups ?? []).filter((group) =>
        group.owners.some((owner) => owner.path === selectedPath),
      ),
    [conflicts, selectedPath],
  );
  const conflictPercent = progress
    ? progress.phase === "completed"
      ? 100
      : progress.phase === "downloading" && progress.totalBytes > 0
        ? Math.min(99, Math.round((progress.completedBytes / progress.totalBytes) * 100))
        : progress.totalFiles > 0
          ? Math.min(99, Math.round((progress.completedFiles / progress.totalFiles) * 100))
          : null
    : null;
  const conflictActionLabel = conflictLoading
    ? progress?.phase === "parsing"
      ? t("remoteViewer.parsingProgress", {
          completed: progress.completedFiles,
          total: progress.totalFiles,
        })
      : progress?.phase === "downloading"
        ? t("remoteViewer.downloadingProgress", {
            completed: progress.completedFiles,
            total: progress.totalFiles,
          })
        : t("remoteViewer.analyzing")
    : t("remoteViewer.analyzeConflicts");

  useEffect(() => {
    if (selectedPath && items.some((item) => item.path === selectedPath)) return;
    setSelectedPath(items[0]?.path ?? null);
  }, [items, selectedPath]);

  useEffect(() => {
    setDraftNote(selected ? notes[selected.path] ?? "" : "");
  }, [notes, selected]);

  const noteChanged = Boolean(selected && draftNote !== (notes[selected.path] ?? ""));
  const invalidRename =
    !renameValue.trim() ||
    /[\\/]/.test(renameValue) ||
    (selected?.kind === "pak" && !renameValue.trim().toLowerCase().endsWith(".pak"));

  async function saveNote() {
    if (!selected || !noteChanged || noteSaving) return;
    setNoteSaving(true);
    try {
      await onSaveNote(selected.path, draftNote);
    } finally {
      setNoteSaving(false);
    }
  }

  async function submitRename() {
    if (!selected || invalidRename || operationBusy) return;
    setOperationBusy(true);
    try {
      const nextPath = await onRename(selected.path, renameValue.trim());
      if (nextPath) {
        setSelectedPath(nextPath);
        setRenameOpen(false);
      }
    } finally {
      setOperationBusy(false);
    }
  }

  async function confirmDelete() {
    if (!selected || operationBusy) return;
    setOperationBusy(true);
    try {
      const deleted = await onDelete(selected.path);
      if (deleted) {
        setDeleteOpen(false);
        setSelectedPath(null);
      }
    } finally {
      setOperationBusy(false);
    }
  }

  return (
    <section className="remote-viewer">
      <header className="remote-viewer-toolbar">
        <div>
          <b>{t("remoteViewer.title")}</b>
          <span>{t("remoteViewer.summary", { count: items.length })}</span>
        </div>
        <SearchField
          value={search}
          onChange={setSearch}
          placeholder={t("remoteViewer.searchPlaceholder")}
        />
        <Button
          size="sm"
          icon="upload"
          onClick={() => void onUpload("pak")}
          disabled={loading}
        >
          {t("remoteViewer.uploadPak")}
        </Button>
        <Button
          size="sm"
          icon="folder"
          onClick={() => void onUpload("ue4ss")}
          disabled={loading || !scan.detectedUe4ssPath}
        >
          {t("remoteViewer.uploadUe4ss")}
        </Button>
        <Button
          size="sm"
          icon="refresh"
          onClick={() => void onAnalyzeConflicts()}
          disabled={loading || conflictLoading || scan.pakMods.length < 2}
        >
          {conflictActionLabel}
        </Button>
      </header>

      <div className="remote-viewer-body">
        <div className="remote-viewer-list-pane">
          <div className="remote-viewer-filters" role="tablist" aria-label={t("remoteViewer.filter")}>
            {(["all", "pak", "ue4ss"] as ViewerFilter[]).map((value) => (
              <button
                key={value}
                type="button"
                className={filter === value ? "is-active" : ""}
                role="tab"
                aria-selected={filter === value}
                onClick={() => setFilter(value)}
              >
                {t(
                  value === "all"
                    ? "remoteViewer.filterAll"
                    : value === "pak"
                      ? "remoteViewer.filterPak"
                      : "remoteViewer.filterUe4ss",
                )}
              </button>
            ))}
          </div>
          {filtered.length > 0 ? (
            <div className="remote-viewer-list">
              {filtered.map((item) => {
                const conflictCount = conflictCounts[item.path] ?? 0;
                return (
                  <button
                    key={item.path}
                    type="button"
                    className={`remote-viewer-item ${
                      selectedPath === item.path ? "is-selected" : ""
                    }`}
                    onClick={() => setSelectedPath(item.path)}
                  >
                    <span className={`file-symbol ${item.kind === "ue4ss" ? "is-folder" : ""}`}>
                      <Icon name={item.kind === "ue4ss" ? "folder" : "box"} size={16} />
                    </span>
                    <span className="remote-viewer-item-main">
                      <b>{item.name}</b>
                      <small>
                        {item.kind === "pak" ? "PAK" : "UE4SS"} ·{" "}
                        {item.isDirectory ? t("common.directory") : formatBytes(item.size)}
                      </small>
                    </span>
                    {notes[item.path] ? (
                      <span className="remote-viewer-note-dot" title={t("remoteViewer.hasNote")} />
                    ) : null}
                    {conflictCount > 0 ? (
                      <span className="remote-viewer-conflict-count">{conflictCount}</span>
                    ) : null}
                  </button>
                );
              })}
            </div>
          ) : (
            <EmptyState
              icon="box"
              title={t("remoteViewer.emptyTitle")}
              description={t("remoteViewer.emptyDescription")}
            />
          )}
        </div>

        <div className="remote-viewer-inspector">
          {selected ? (
            <>
              <header>
                <div>
                  <span className="remote-viewer-kind">
                    {selected.kind === "pak" ? "PAK" : "UE4SS"}
                  </span>
                  <h3>{selected.name}</h3>
                </div>
                <div className="remote-viewer-inspector-actions">
                  <Button
                    size="sm"
                    icon="edit"
                    onClick={() => {
                      setRenameValue(selected.name);
                      setRenameOpen(true);
                    }}
                    disabled={loading}
                  >
                    {t("remoteViewer.rename")}
                  </Button>
                  <Button
                    size="sm"
                    variant="danger"
                    icon="trash"
                    onClick={() => setDeleteOpen(true)}
                    disabled={loading}
                  >
                    {t("remoteViewer.delete")}
                  </Button>
                </div>
              </header>
              <code className="remote-viewer-path">{selected.path}</code>
              <dl className="remote-viewer-facts">
                <div>
                  <dt>{t("remoteViewer.size")}</dt>
                  <dd>{selected.isDirectory ? t("common.directory") : formatBytes(selected.size)}</dd>
                </div>
                <div>
                  <dt>{t("remoteViewer.modified")}</dt>
                  <dd>{formatDate(selected.modifiedAt, language)}</dd>
                </div>
                <div>
                  <dt>{t("remoteViewer.conflicts")}</dt>
                  <dd>{conflictCounts[selected.path] ?? 0}</dd>
                </div>
              </dl>

              <label className="remote-viewer-note">
                <span>{t("remoteViewer.note")}</span>
                <textarea
                  value={draftNote}
                  onChange={(event) => setDraftNote(event.target.value)}
                  placeholder={t("remoteViewer.notePlaceholder")}
                />
              </label>
              <div className="remote-viewer-note-actions">
                <span>{t("remoteViewer.noteLocalHint")}</span>
                <Button
                  size="sm"
                  icon="check"
                  onClick={() => void saveNote()}
                  disabled={!noteChanged || noteSaving || loading}
                >
                  {noteSaving ? t("remoteViewer.savingNote") : t("remoteViewer.saveNote")}
                </Button>
              </div>

              <section className="remote-viewer-conflicts">
                <div className="section-title">
                  <span>{t("remoteViewer.conflictTitle")}</span>
                  <b>{conflicts?.message || t("remoteViewer.conflictNotAnalyzed")}</b>
                </div>
                {conflictLoading ? (
                  <div className="remote-viewer-conflict-progress" aria-live="polite">
                    <div>
                      <span>{progress?.message || t("remoteViewer.conflictAnalyzing")}</span>
                      {conflictPercent !== null ? <b>{conflictPercent}%</b> : null}
                    </div>
                    <div
                      className="remote-viewer-progress-track"
                      role="progressbar"
                      aria-label={t("remoteViewer.conflictTitle")}
                      aria-valuemin={0}
                      aria-valuemax={100}
                      aria-valuenow={conflictPercent ?? 0}
                    >
                      <i style={{ width: `${conflictPercent ?? 0}%` }} />
                    </div>
                    <small>
                      {progress?.currentFile
                        ? progress.currentFile
                        : t("remoteViewer.conflictAnalyzing")}
                    </small>
                    {progress && progress.totalBytes > 0 ? (
                      <small>
                        {t("remoteViewer.bytesProgress", {
                          completed: formatBytes(progress.completedBytes),
                          total: formatBytes(progress.totalBytes),
                        })}
                      </small>
                    ) : null}
                  </div>
                ) : !conflicts ? (
                  <p>{t("remoteViewer.conflictPrompt")}</p>
                ) : selectedConflicts.length === 0 ? (
                  <p>{t("remoteViewer.conflictNone")}</p>
                ) : (
                  <div className="remote-viewer-conflict-list">
                    {selectedConflicts.map((group) => (
                      <div key={group.resourcePath}>
                        <code>{group.resourcePath}</code>
                        <span className="remote-viewer-conflict-owners">
                          {group.owners
                            .filter((owner) => owner.path !== selected.path)
                            .map((owner) => (
                              <button
                                key={owner.path}
                                type="button"
                                onClick={() => setSelectedPath(owner.path)}
                              >
                                {owner.name}
                              </button>
                            ))}
                        </span>
                      </div>
                    ))}
                  </div>
                )}
              </section>
            </>
          ) : (
            <EmptyState
              icon="box"
              title={t("remoteViewer.selectTitle")}
              description={t("remoteViewer.selectDescription")}
            />
          )}
        </div>
      </div>

      {renameOpen && selected ? (
        <Modal
          title={t("remoteViewer.renameTitle")}
          description={t("remoteViewer.renameDescription", { name: selected.name })}
          onClose={() => setRenameOpen(false)}
          footer={
            <>
              <Button onClick={() => setRenameOpen(false)}>{t("common.cancel")}</Button>
              <Button
                variant="primary"
                onClick={() => void submitRename()}
                disabled={invalidRename || operationBusy}
              >
                {operationBusy ? t("remoteViewer.working") : t("remoteViewer.renameConfirm")}
              </Button>
            </>
          }
        >
          <label className="remote-viewer-modal-field">
            <span>{t("remoteViewer.newName")}</span>
            <input
              value={renameValue}
              onChange={(event) => setRenameValue(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  void submitRename();
                }
              }}
              autoFocus
            />
          </label>
          {invalidRename ? <p className="remote-viewer-modal-error">{t("remoteViewer.invalidName")}</p> : null}
        </Modal>
      ) : null}

      {deleteOpen && selected ? (
        <Modal
          title={t("remoteViewer.deleteTitle")}
          description={t("remoteViewer.deleteDescription", { name: selected.name })}
          onClose={() => setDeleteOpen(false)}
          footer={
            <>
              <Button onClick={() => setDeleteOpen(false)}>{t("common.cancel")}</Button>
              <Button
                variant="danger"
                icon="trash"
                onClick={() => void confirmDelete()}
                disabled={operationBusy}
              >
                {operationBusy ? t("remoteViewer.deleting") : t("remoteViewer.deleteConfirm")}
              </Button>
            </>
          }
        >
          <p className="remote-viewer-delete-warning">
            {selected.isDirectory
              ? t("remoteViewer.deleteDirectoryWarning")
              : t("remoteViewer.deleteFileWarning")}
          </p>
        </Modal>
      ) : null}
    </section>
  );
}
