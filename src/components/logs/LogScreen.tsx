import { useEffect, useMemo, useState } from "react";
import type { RuntimeLog } from "../../types";
import { useI18n } from "../../i18n";
import { formatTimestamp } from "../../lib/format";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { SearchField } from "../ui/SearchField";

interface LogScreenProps {
  logs: RuntimeLog[];
  onRefresh: () => void;
  onClear: () => void;
}

const LEVEL_KEYS = {
  all: "logs.all",
  info: "logs.info",
  warn: "logs.warn",
  error: "logs.error",
  debug: "logs.debug",
} as const;

const LEVELS: Array<"all" | RuntimeLog["level"]> = [
  "all",
  "info",
  "warn",
  "error",
  "debug",
];

export function LogScreen({ logs, onRefresh, onClear }: LogScreenProps) {
  const { t, language } = useI18n();
  const [search, setSearch] = useState("");
  const [level, setLevel] = useState<"all" | RuntimeLog["level"]>("all");
  const [confirmClear, setConfirmClear] = useState(false);

  useEffect(() => {
    if (!confirmClear) return;
    const timer = window.setTimeout(() => setConfirmClear(false), 4000);
    return () => window.clearTimeout(timer);
  }, [confirmClear]);

  const filtered = useMemo(() => {
    const query = search.trim().toLowerCase();
    return logs.filter(
      (log) =>
        (level === "all" || log.level === level) &&
        (!query || `${log.target} ${log.message}`.toLowerCase().includes(query)),
    );
  }, [level, logs, search]);

  return (
    <section className="page page-logs">
      <header className="page-header">
        <div>
          <h1>{t("logs.title")}</h1>
          <p>{t("logs.subtitle")}</p>
        </div>
        <div className="heading-tools">
          <SearchField
            value={search}
            onChange={setSearch}
            placeholder={t("logs.searchPlaceholder")}
          />
          <Button icon="refresh" onClick={onRefresh}>
            {t("common.refresh")}
          </Button>
          <Button
            icon="trash"
            variant={confirmClear ? "danger" : "outline"}
            onClick={() => {
              if (!confirmClear) {
                setConfirmClear(true);
                return;
              }
              setConfirmClear(false);
              onClear();
            }}
          >
            {confirmClear ? t("logs.confirmClear") : t("logs.clear")}
          </Button>
        </div>
      </header>
      <div className="log-toolbar">
        {LEVELS.map((id) => (
          <button
            type="button"
            className={`filter-chip ${level === id ? "is-active" : ""}`}
            key={id}
            onClick={() => setLevel(id)}
          >
            {t(LEVEL_KEYS[id])}
          </button>
        ))}
        <span>{t("logs.count", { count: filtered.length })}</span>
      </div>
      <div className="log-console">
        {filtered.length === 0 ? (
          <EmptyState
            icon="terminal"
            title={t("logs.emptyTitle")}
            description={t("logs.emptyDescription")}
          />
        ) : (
          filtered.map((log) => (
            <div className={`log-line level-${log.level}`} key={log.id}>
              <span>{formatTimestamp(log.timestamp, language)}</span>
              <b>{t(LEVEL_KEYS[log.level])}</b>
              <span>{log.target}</span>
              <p>{log.message}</p>
            </div>
          ))
        )}
      </div>
    </section>
  );
}
