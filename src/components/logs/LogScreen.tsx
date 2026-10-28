import { useEffect, useMemo, useState } from "react";
import type { RuntimeLog } from "../../types";
import { formatTimestamp } from "../../lib/format";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { SearchField } from "../ui/SearchField";

interface LogScreenProps {
  logs: RuntimeLog[];
  onRefresh: () => void;
  onClear: () => void;
}

const LEVELS: Array<{ id: "all" | RuntimeLog["level"]; label: string }> = [
  { id: "all", label: "全部" },
  { id: "info", label: "信息" },
  { id: "warn", label: "警告" },
  { id: "error", label: "错误" },
  { id: "debug", label: "调试" },
];

const LEVEL_LABEL: Record<RuntimeLog["level"], string> = {
  info: "信息",
  warn: "警告",
  error: "错误",
  debug: "调试",
};

export function LogScreen({ logs, onRefresh, onClear }: LogScreenProps) {
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
          <h1>运行日志</h1>
          <p>扫描、部署、SFTP、云端下载和进程回收的记录。</p>
        </div>
        <div className="heading-tools">
          <SearchField value={search} onChange={setSearch} placeholder="搜索日志内容" />
          <Button icon="refresh" onClick={onRefresh}>
            刷新
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
            {confirmClear ? "确认清空" : "清空"}
          </Button>
        </div>
      </header>
      <div className="log-toolbar">
        {LEVELS.map((item) => (
          <button
            type="button"
            className={`filter-chip ${level === item.id ? "is-active" : ""}`}
            key={item.id}
            onClick={() => setLevel(item.id)}
          >
            {item.label}
          </button>
        ))}
        <span>{filtered.length} 条记录</span>
      </div>
      <div className="log-console">
        {filtered.length === 0 ? (
          <EmptyState icon="terminal" title="没有日志" description="运行一次扫描或启动操作后再回来查看。" />
        ) : (
          filtered.map((log) => (
            <div className={`log-line level-${log.level}`} key={log.id}>
              <span>{formatTimestamp(log.timestamp)}</span>
              <b>{LEVEL_LABEL[log.level]}</b>
              <span>{log.target}</span>
              <p>{log.message}</p>
            </div>
          ))
        )}
      </div>
    </section>
  );
}
