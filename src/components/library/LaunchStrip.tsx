import { useEffect, useRef, useState } from "react";
import type { LaunchOptions } from "../../types";
import { useI18n } from "../../i18n";
import { formatBytes } from "../../lib/format";
import { Button } from "../ui/Button";
import { Toggle } from "../ui/Toggle";

interface LaunchStripProps {
  enabledCount: number;
  totalBytes: number;
  running: boolean;
  keepDeployedModsOnExit: boolean;
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
  keepDeployedModsOnExit,
  launchOptions,
  onLaunch,
  onKill,
  onOptionsChange,
  onOpenSettings,
}: LaunchStripProps) {
  const { t } = useI18n();
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
          <b>{running ? t("launch.runningTitle") : t("launch.readyTitle")}</b>
          <span>
            {running
              ? t(
                  keepDeployedModsOnExit
                    ? "launch.runningDetailKeep"
                    : "launch.runningDetail",
                )
              : t(
                  keepDeployedModsOnExit
                    ? "launch.readyDetailKeep"
                    : "launch.readyDetail",
                )}
          </span>
        </div>
      </div>
      <div className="strip-facts">
        <span>
          {t("launch.enabled")} <b>{enabledCount}</b>
        </span>
        <i />
        <span>
          {t("launch.totalSize")} <b>{formatBytes(totalBytes)}</b>
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
          {t("launch.options")}
        </Button>
        {optionsOpen ? (
          <div className="launch-options-popover" role="dialog" aria-label={t("launch.options")}>
            <div className="launch-options-head">
              <b>{t("launch.optionsTitle")}</b>
              <span>{t("launch.optionsDetail")}</span>
            </div>
            <label className="launch-option-row">
              <span>
                <b>{t("launch.log")}</b>
                <small>{t("launch.logDetail")}</small>
              </span>
              <Toggle
                checked={launchOptions.log}
                onChange={(log) => onOptionsChange({ ...launchOptions, log })}
                label={t("launch.log")}
              />
            </label>
            <label className="launch-option-row">
              <span>
                <b>{t("launch.fileLog")}</b>
                <small>{t("launch.fileLogDetail")}</small>
              </span>
              <Toggle
                checked={launchOptions.fileOpenLog}
                onChange={(fileOpenLog) => onOptionsChange({ ...launchOptions, fileOpenLog })}
                label={t("launch.fileLog")}
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
              {t("launch.allSettings")}
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
        {running ? t("launch.stop") : t("launch.start")}
      </Button>
    </section>
  );
}
