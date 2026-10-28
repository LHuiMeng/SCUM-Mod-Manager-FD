import { useEffect, useRef, useState } from "react";
import type { LaunchOptions } from "../../types";
import { formatBytes } from "../../lib/format";
import { Button } from "../ui/Button";
import { Toggle } from "../ui/Toggle";

interface LaunchStripProps {
  enabledCount: number;
  totalBytes: number;
  running: boolean;
  launchOptions: LaunchOptions;
  onLaunch: () => void;
  onKill: () => void;
  onOptionsChange: (options: LaunchOptions) => void;
  onOpenSettings: () => void;
}

export function LaunchStrip({
  enabledCount,
  totalBytes,
  running,
  launchOptions,
  onLaunch,
  onKill,
  onOptionsChange,
  onOpenSettings,
}: LaunchStripProps) {
  const [optionsOpen, setOptionsOpen] = useState(false);
  const optionsRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!optionsOpen) return;

    function handlePointerDown(event: PointerEvent) {
      if (!optionsRef.current?.contains(event.target as Node)) {
        setOptionsOpen(false);
      }
    }

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") setOptionsOpen(false);
    }

    document.addEventListener("pointerdown", handlePointerDown);
    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("pointerdown", handlePointerDown);
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [optionsOpen]);

  return (
    <section className="launch-strip">
      <div className="strip-state">
        <span className={`strip-dot ${running ? "is-running" : ""}`} />
        <div>
          <b>{running ? "游戏正在运行" : "可以启动客户端"}</b>
          <span>{running ? "退出后回收本次部署" : "启动时部署启用模组"}</span>
        </div>
      </div>
      <div className="strip-facts">
        <span>
          已启用 <b>{enabledCount}</b>
        </span>
        <i />
        <span>
          总大小 <b>{formatBytes(totalBytes)}</b>
        </span>
      </div>
      <div className="launch-options-wrap" ref={optionsRef}>
        <Button
          icon="settings"
          onClick={() => setOptionsOpen((open) => !open)}
          className="launch-options-button"
          aria-expanded={optionsOpen}
          aria-haspopup="dialog"
        >
          启动选项
        </Button>
        {optionsOpen ? (
          <div className="launch-options-popover" role="dialog" aria-label="启动选项">
            <div className="launch-options-head">
              <b>启动参数</b>
              <span>改动立即保存，下次启动生效</span>
            </div>
            <label className="launch-option-row">
              <span>
                <b>启用日志</b>
                <small>向游戏附加 -log</small>
              </span>
              <Toggle
                checked={launchOptions.log}
                onChange={(log) => onOptionsChange({ ...launchOptions, log })}
                label="启用日志"
              />
            </label>
            <label className="launch-option-row">
              <span>
                <b>文件打开日志</b>
                <small>向游戏附加 -fileopenlog</small>
              </span>
              <Toggle
                checked={launchOptions.fileOpenLog}
                onChange={(fileOpenLog) => onOptionsChange({ ...launchOptions, fileOpenLog })}
                label="文件打开日志"
              />
            </label>
            <Button
              size="sm"
              className="launch-options-settings"
              onClick={() => {
                setOptionsOpen(false);
                onOpenSettings();
              }}
            >
              全部启动设置
            </Button>
          </div>
        ) : null}
      </div>
      <Button
        variant={running ? "danger" : "primary"}
        className="launch-primary"
        icon={running ? "serverOff" : "play"}
        onClick={running ? onKill : onLaunch}
      >
        {running ? "停止游戏" : "启动客户端"}
      </Button>
    </section>
  );
}
