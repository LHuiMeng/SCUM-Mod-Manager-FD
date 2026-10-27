import { useMemo, useState } from "react";
import type { RuntimeLog } from "../../types";
import { formatClock } from "../../lib/format";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { SearchField } from "../ui/SearchField";

interface LogScreenProps {
  logs: RuntimeLog[];
  onRefresh: () => void;
  onClear: () => void;
}

export function LogScreen({ logs, onRefresh, onClear }: LogScreenProps) {
  const [search, setSearch] = useState("");
  const [level, setLevel] = useState<"all" | RuntimeLog["level"]>("all");
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
          <p>扫描、部署、SFTP、云端下载和进程回收的完整记录。</p>
        </div>
        <div className="heading-tools">
          <SearchField value={search} onChange={setSearch} placeholder="搜索日志内容" />
          <Button icon="refresh" onClick={onRefresh}>
            刷新
          </Button>
          <Button icon="trash" onClick={onClear}>
            清空
          </Button>
        </div>
      </header>
      <div className="log-toolbar">
        {(["all", "info", "warn", "error", "debug"] as const).map((item) => (
          <button
            type="button"
            className={`filter-chip ${level === item ? "is-active" : ""}`}
            key={item}
            onClick={() => setLevel(item)}
          >
            {item === "all" ? "全部" : item.toUpperCase()}
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
              <span>{formatClock(log.timestamp)}</span>
              <b>{log.level.toUpperCase()}</b>
              <span>{log.target}</span>
              <p>{log.message}</p>
            </div>
          ))
        )}
      </div>
    </section>
  );
}
