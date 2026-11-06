import { useEffect, useState } from "react";
import type { OperationEntry } from "../../lib/operations";
import {
  formatElapsed,
  operationDetail,
  operationKindKey,
  operationPercent,
} from "../../lib/operations";
import { useI18n } from "../../i18n";

interface OperationDockProps {
  current: OperationEntry | null;
  history: OperationEntry[];
}

/**
 * 常驻操作条：只在有正在进行的服务器长操作时出现，完成后立刻消失。
 * 放在标题栏下方，切页面也不会中断——用户看得见「现在在干什么」。
 */
export function OperationDock({ current, history }: OperationDockProps) {
  const { t, language } = useI18n();
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (!current) return;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [current]);

  if (!current) return null;

  const percent = operationPercent(current);
  return (
    <div className="operation-dock" role="status" aria-live="polite">
      <span className="operation-dock-spinner" aria-hidden="true" />
      <div className="operation-dock-copy">
        <b>{t(operationKindKey(current.kind))}</b>
        <span>
          {operationDetail(current)}
        </span>
      </div>
      <div className="operation-dock-track" aria-hidden="true">
        <i style={{ width: `${percent ?? 0}%` }} />
      </div>
      <span className="operation-dock-meta">
        {percent === null ? t("operation.dock.working") : `${percent}%`}
        {" · "}
        {formatElapsed(now - current.receivedAt)}
      </span>
      {history.length > 0 ? (
        <details className="operation-dock-history">
          <summary>{t("operation.dock.history")}</summary>
          <ul>
            {history.slice(-6).reverse().map((entry) => (
              <li key={entry.id} data-finished={entry.finished}>
                <span>{entry.message}</span>
                <small>
                  {new Date(entry.receivedAt).toLocaleTimeString(language, {
                    hour12: false,
                    hour: "2-digit",
                    minute: "2-digit",
                    second: "2-digit",
                  })}
                </small>
              </li>
            ))}
          </ul>
        </details>
      ) : null}
    </div>
  );
}
