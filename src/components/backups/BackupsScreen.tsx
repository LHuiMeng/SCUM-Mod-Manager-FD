import { useCallback, useEffect, useMemo, useState } from "react";
import type { BackupEntry } from "../../types";
import { api } from "../../api/tauri";
import { useI18n, type TranslationKey } from "../../i18n";
import { formatBytes, formatDate } from "../../lib/format";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";

type BackupFilter = "all" | BackupEntry["kind"];

interface BackupsScreenProps {
  onNotify: (title: string, detail?: string, tone?: "default" | "success" | "error") => void;
  /** 恢复成功后通知外层刷新模组库，避免用户回到库页看不到刚恢复的模组。 */
  onRestored?: () => void;
}

/**
 * 备份找回页：把 ``backups/`` 下四类备份（删除、导入覆盖、下载覆盖、部署覆盖）
 * 全部列出来，用户可以在界面里直接恢复到本地模组库，不必去翻文件夹。
 */
export function BackupsScreen({ onNotify, onRestored }: BackupsScreenProps) {
  const { t, language } = useI18n();
  const [entries, setEntries] = useState<BackupEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<BackupFilter>("all");
  const [workingId, setWorkingId] = useState<string | null>(null);
  const [pending, setPending] = useState<{
    action: "restore" | "remove";
    entry: BackupEntry;
  } | null>(null);
  const [confirmBusy, setConfirmBusy] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setEntries(await api.listBackups());
    } catch (reason) {
      setError(String(reason));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const filtered = useMemo(
    () => entries.filter((entry) => filter === "all" || entry.kind === filter),
    [entries, filter],
  );
  const totalBytes = useMemo(
    () => entries.reduce((sum, entry) => sum + entry.size, 0),
    [entries],
  );

  async function restore(entry: BackupEntry): Promise<boolean> {
    if (workingId) return false;
    setWorkingId(entry.id);
    try {
      const message = await api.restoreBackup(entry.id);
      onNotify(t("backups.restored.title"), message, "success");
      onRestored?.();
      await load();
      return true;
    } catch (reason) {
      onNotify(t("backups.restoreFailed.title"), String(reason), "error");
      return false;
    } finally {
      setWorkingId(null);
    }
  }

  async function remove(entry: BackupEntry): Promise<boolean> {
    if (workingId) return false;
    setWorkingId(entry.id);
    try {
      await api.deleteBackup(entry.id);
      onNotify(t("backups.removed.title"), entry.name, "success");
      await load();
      return true;
    } catch (reason) {
      onNotify(t("backups.removeFailed.title"), String(reason), "error");
      return false;
    } finally {
      setWorkingId(null);
    }
  }

  async function confirmPending() {
    if (!pending || confirmBusy) return;
    setConfirmBusy(true);
    try {
      const ok =
        pending.action === "restore"
          ? await restore(pending.entry)
          : await remove(pending.entry);
      if (ok) setPending(null);
    } finally {
      setConfirmBusy(false);
    }
  }

  const filters: BackupFilter[] = ["all", "deleted", "import", "replaced", "deploy"];
  const filterLabel: Record<BackupFilter, TranslationKey> = {
    all: "backups.kind.all",
    deleted: "backups.kind.deleted",
    import: "backups.kind.import",
    replaced: "backups.kind.replaced",
    deploy: "backups.kind.deploy",
  };

  return (
    <section className="page page-backups">
      <header className="page-header">
        <div>
          <h1>{t("backups.title")}</h1>
          <p>{t("backups.subtitle")}</p>
        </div>
        <div className="heading-tools">
          <span className="backups-summary">
            {t("backups.summary", {
              count: entries.length,
              size: formatBytes(totalBytes),
            })}
          </span>
          <Button icon="refresh" onClick={() => void load()} disabled={loading}>
            {t("backups.refresh")}
          </Button>
        </div>
      </header>

      <div className="backups-filters" role="tablist" aria-label={t("backups.filterLabel")}>
        {filters.map((value) => (
          <button
            key={value}
            type="button"
            role="tab"
            aria-selected={filter === value}
            className={filter === value ? "is-active" : ""}
            onClick={() => setFilter(value)}
          >
            {t(filterLabel[value])}
          </button>
        ))}
      </div>

      {error ? (
        <div className="backups-error" role="alert">
          {t("backups.loadFailed")}：{error}
        </div>
      ) : null}

      {loading ? (
        <div className="backups-loading">{t("backups.loading")}</div>
      ) : filtered.length === 0 ? (
        <EmptyState
          icon="box"
          title={t("backups.emptyTitle")}
          description={t("backups.emptyDescription")}
        />
      ) : (
        <div className="backups-list" role="list">
          {filtered.map((entry) => (
            <article className="backup-row" key={entry.id} role="listitem">
              <span className={`backup-kind is-${entry.kind}`}>
                <Icon name="box" size={15} />
              </span>
              <div className="backup-main">
                <b>{entry.name}</b>
                <span>{entry.detail}</span>
                <code>{entry.path}</code>
              </div>
              <div className="backup-meta">
                <span>{formatBytes(entry.size)}</span>
                <span>{formatDate(entry.createdAt, language)}</span>
              </div>
              <div className="backup-actions">
                <Button
                  size="sm"
                  variant="outline"
                  icon="refresh"
                  disabled={Boolean(workingId) || !entry.restorable}
                  title={entry.restorable ? undefined : t("backups.viewOnly")}
                  onClick={() => setPending({ action: "restore", entry })}
                >
                  {!entry.restorable
                    ? t("backups.viewOnly")
                    : workingId === entry.id
                      ? t("backups.restoring")
                      : t("backups.restore")}
                </Button>
                <Button
                  size="sm"
                  variant="danger"
                  icon="trash"
                  disabled={Boolean(workingId)}
                  onClick={() => setPending({ action: "remove", entry })}
                >
                  {t("backups.remove")}
                </Button>
              </div>
            </article>
          ))}
        </div>
      )}

      {pending ? (
        <Modal
          title={t(
            pending.action === "restore"
              ? "backups.confirmRestore.title"
              : "backups.confirmRemove.title",
          )}
          description={t(
            pending.action === "restore"
              ? "backups.confirmRestore.detail"
              : "backups.confirmRemove.detail",
            { name: pending.entry.name },
          )}
          onClose={() => {
            if (!confirmBusy) setPending(null);
          }}
          footer={
            <>
              <Button
                disabled={confirmBusy}
                onClick={() => {
                  if (!confirmBusy) setPending(null);
                }}
              >
                {t("common.cancel")}
              </Button>
              <Button
                variant={pending.action === "remove" ? "danger" : "outline"}
                disabled={confirmBusy}
                onClick={() => void confirmPending()}
              >
                {confirmBusy
                  ? t("common.working")
                  : pending.action === "restore"
                    ? t("backups.restore")
                    : t("backups.remove")}
              </Button>
            </>
          }
        >
          <div className="backup-confirm">
            <code>{pending.entry.path}</code>
            <span>
              {formatBytes(pending.entry.size)} ·{" "}
              {formatDate(pending.entry.createdAt, language)}
            </span>
          </div>
        </Modal>
      ) : null}
    </section>
  );
}
