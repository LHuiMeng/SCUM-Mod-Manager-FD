import { useEffect, useMemo, useState } from "react";
import type {
  AppSettings,
  GameStatus,
  LibrarySnapshot,
  ModEntry,
  NavSection,
} from "../../types";
import { useI18n } from "../../i18n";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";
import { SearchField } from "../ui/SearchField";
import { LaunchStrip } from "./LaunchStrip";
import { ConflictResolutionPanel } from "./ConflictResolutionPanel";
import { ModEditPanel } from "./ModEditPanel";
import { ModInspector } from "./ModInspector";
import { ModTable } from "./ModTable";

interface LibraryScreenProps {
  snapshot: LibrarySnapshot;
  search: string;
  onSearchChange: (search: string) => void;
  onScan: () => void;
  onImport: () => void;
  onToggle: (id: string, enabled: boolean) => void;
  onReorder: (ids: string[]) => void;
  onEdit: (id: string, tags: string[], notes: string) => void;
  onDelete: (id: string) => Promise<boolean>;
  onSaveConflictWinners: (winners: Record<string, string>) => Promise<boolean>;
  onLaunch: () => void;
  onKill: () => void;
  onOpenFolder: (id: string) => void;
  onLaunchOptionsChange: (options: AppSettings["launchOptions"]) => void;
  onNavigate: (section: NavSection) => void;
  gameStatus: GameStatus;
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  fileDragActive: boolean;
}

export function LibraryScreen({
  snapshot,
  search,
  onSearchChange,
  onScan,
  onImport,
  onToggle,
  onReorder,
  onEdit,
  onDelete,
  onSaveConflictWinners,
  onLaunch,
  onKill,
  onOpenFolder,
  onLaunchOptionsChange,
  onNavigate,
  gameStatus,
  selectedId,
  onSelect,
  fileDragActive,
}: LibraryScreenProps) {
  const { t } = useI18n();
  const [editing, setEditing] = useState<ModEntry | null>(null);
  const [deleting, setDeleting] = useState<ModEntry | null>(null);
  const [deleteBusy, setDeleteBusy] = useState(false);
  const [removingId, setRemovingId] = useState<string | null>(null);
  const [conflictsOpen, setConflictsOpen] = useState(false);
  const [visibleIds, setVisibleIds] = useState<string[] | null>(null);
  const mods = snapshot.mods;
  const conflictGroups = snapshot.conflicts ?? [];

  useEffect(() => {
    if (!selectedId && mods.length > 0) {
      onSelect(sortedMods(mods)[0]?.id ?? null);
    } else if (selectedId && !mods.some((mod) => mod.id === selectedId)) {
      onSelect(sortedMods(mods)[0]?.id ?? null);
    }
  }, [mods, onSelect, selectedId]);

  const selected = mods.find((mod) => mod.id === selectedId) ?? null;
  // 列表被搜索或筛选清空时，右侧不该继续展示一个已经不在结果里的模组。
  const visibleSelected =
    selected && (!visibleIds || visibleIds.includes(selected.id)) ? selected : null;

  useEffect(() => {
    if (!visibleSelected || visibleSelected.conflictCount === 0) {
      setConflictsOpen(false);
    }
  }, [visibleSelected]);

  const summary = useMemo(() => {
    const enabled = mods.filter((mod) => mod.enabled);
    const totalBytes = enabled.reduce((sum, mod) => sum + mod.fileSize, 0);
    const conflicts = snapshot.conflicts.length;
    const updates = mods.filter((mod) => mod.updateVersion).length;
    return { enabled, totalBytes, conflicts, updates };
  }, [mods, snapshot.conflicts.length]);

  return (
    <div className="library-layout">
      <section className="library-main">
        <div className="page-heading">
          <div>
            <h1>{t("library.title")}</h1>
            <p>{t("library.subtitle")}</p>
          </div>
          <div className="heading-tools">
            <SearchField
              value={search}
              onChange={onSearchChange}
              placeholder={t("library.searchPlaceholder")}
            />
            <Button icon="folder" onClick={onScan}>
              {t("library.scan")}
            </Button>
            <Button icon="plus" onClick={onImport}>
              {t("library.import")}
            </Button>
          </div>
        </div>

        <LaunchStrip
          enabledCount={summary.enabled.length}
          totalBytes={summary.totalBytes}
          running={gameStatus.running}
          launchOptions={snapshot.settings.launchOptions}
          onLaunch={onLaunch}
          onKill={onKill}
          onOptionsChange={onLaunchOptionsChange}
          onOpenSettings={() => onNavigate("settings")}
        />

        <ModTable
          mods={sortedMods(mods)}
          selectedId={selectedId}
          search={search}
          locked={gameStatus.running}
          lastDeployedAt={snapshot.lastDeployedAt}
          conflictCount={summary.conflicts}
          removingId={removingId}
          onSelect={onSelect}
          onToggle={(id, enabled) => onToggle(id, enabled)}
          onReorder={onReorder}
          onVisibleChange={setVisibleIds}
        />
      </section>

      <ModInspector
        key={visibleSelected?.id ?? "empty"}
        mod={visibleSelected}
        onEdit={() => visibleSelected && setEditing(visibleSelected)}
        onDelete={() => visibleSelected && setDeleting(visibleSelected)}
        onOpenFolder={() => visibleSelected && onOpenFolder(visibleSelected.id)}
        onOpenConflicts={() => visibleSelected && setConflictsOpen(true)}
      />

      {conflictsOpen && visibleSelected ? (
        <ConflictResolutionPanel
          key={visibleSelected.id}
          mod={visibleSelected}
          groups={conflictGroups}
          onClose={() => setConflictsOpen(false)}
          onSave={onSaveConflictWinners}
        />
      ) : null}

      {editing ? (
        <ModEditPanel
          mod={editing}
          onSave={(tags, notes) => onEdit(editing.id, tags, notes)}
          onClose={() => setEditing(null)}
        />
      ) : null}

      {deleting ? (
        <Modal
          title={t("inspector.deleteTitle")}
          description={t(
            deleting.duplicateCount
              ? "inspector.deleteDescriptionDuplicates"
              : "inspector.deleteDescription",
            {
              name: deleting.name,
              count: deleting.duplicateCount ?? 0,
            },
          )}
          onClose={() => {
            if (!deleteBusy) setDeleting(null);
          }}
          footer={
            <>
              <Button
                disabled={deleteBusy}
                onClick={() => {
                  if (!deleteBusy) setDeleting(null);
                }}
              >
                {t("common.cancel")}
              </Button>
              <Button
                variant="danger"
                disabled={deleteBusy || gameStatus.running}
                onClick={() => {
                  if (deleteBusy || gameStatus.running) return;
                  void (async () => {
                    setDeleteBusy(true);
                    setRemovingId(deleting.id);
                    try {
                      const removeDelay = window.matchMedia(
                        "(prefers-reduced-motion: reduce)",
                      ).matches
                        ? 0
                        : 260;
                      await new Promise((resolve) =>
                        window.setTimeout(resolve, removeDelay),
                      );
                      const deleted = await onDelete(deleting.id);
                      if (deleted) setDeleting(null);
                    } finally {
                      setDeleteBusy(false);
                      setRemovingId(null);
                    }
                  })();
                }}
              >
                {deleteBusy ? t("common.working") : t("inspector.deleteConfirm")}
              </Button>
            </>
          }
        >
          <p className="delete-confirm-note">
            {gameStatus.running
              ? t("inspector.deleteRunning")
              : t("inspector.deleteBackupNote")}
          </p>
        </Modal>
      ) : null}

      {fileDragActive ? (
        <div className="library-drop-overlay" role="status" aria-live="polite">
          <div className="library-drop-card">
            <span className="library-drop-icon">
              <Icon name="plus" size={22} />
            </span>
            <b>{t("library.drop.release")}</b>
            <span>{t("library.drop.detail")}</span>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function sortedMods(mods: ModEntry[]) {
  return [...mods].sort((a, b) => a.loadOrder - b.loadOrder);
}
