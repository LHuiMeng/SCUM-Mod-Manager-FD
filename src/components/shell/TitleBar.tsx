import type { GameStatus, NavSection, ThemeMode } from "../../types";
import { useI18n } from "../../i18n";
import { Icon } from "../ui/Icon";

const titleKeys: Record<NavSection, "page.library" | "page.cloud" | "page.server" | "page.logs" | "page.settings"> = {
  library: "page.library",
  cloud: "page.cloud",
  server: "page.server",
  logs: "page.logs",
  settings: "page.settings",
};

interface TitleBarProps {
  section: NavSection;
  theme: ThemeMode;
  gameStatus: GameStatus;
  hasClientPath: boolean;
  deployedSize: string;
  enabledCount: number;
  lastChecked: string;
  updateAvailable: boolean;
  updateVersion: string | null;
  onToggleTheme: () => void;
  onOpenUpdate: () => void;
  onMinimize: () => void;
  onMaximize: () => void;
  onClose: () => void;
}

export function TitleBar({
  section,
  theme,
  gameStatus,
  hasClientPath,
  deployedSize,
  enabledCount,
  lastChecked,
  updateAvailable,
  updateVersion,
  onToggleTheme,
  onOpenUpdate,
  onMinimize,
  onMaximize,
  onClose,
}: TitleBarProps) {
  const { t } = useI18n();
  return (
    <header className="titlebar" data-tauri-drag-region>
      <div className="crumb" data-tauri-drag-region>
        <span>{t("app.name")}</span>
        <i>/</i>
        <b>{t(titleKeys[section])}</b>
      </div>
      <div className="title-status" data-tauri-drag-region>
        {updateAvailable ? (
          <button type="button" className="update-notice" onClick={onOpenUpdate}>
            <i />
            {updateVersion
              ? t("title.updateVersionAvailable", { version: updateVersion })
              : t("title.updateAvailable")}
          </button>
        ) : null}
        <span
          className={`status-live ${gameStatus.running ? "is-running" : hasClientPath ? "" : "is-warn"}`}
          data-tauri-drag-region
        >
          {gameStatus.running
            ? t("title.gameRunning")
            : hasClientPath
              ? t("title.clientLocated")
              : t("title.clientMissing")}
        </span>
        <span className="title-deployed" data-tauri-drag-region>
          {t("title.enabledDeployed", { count: enabledCount, size: deployedSize })}
        </span>
        <span className="title-checked" data-tauri-drag-region>
          {t("title.lastChecked", { time: lastChecked })}
        </span>
        <button
          type="button"
          className="theme-switch"
          onClick={onToggleTheme}
          aria-label={t(theme === "dark" ? "title.switchToLight" : "title.switchToDark")}
          title={t(theme === "dark" ? "title.switchToLight" : "title.switchToDark")}
        >
          <Icon name={theme === "dark" ? "sun" : "moon"} size={13} />
          <span>{t(theme === "dark" ? "title.light" : "title.dark")}</span>
        </button>
      </div>
      <div className="window-actions">
        <button type="button" onClick={onMinimize} aria-label={t("title.minimize")}>
          <Icon name="minimize" size={12} />
        </button>
        <button type="button" onClick={onMaximize} aria-label={t("title.maximize")}>
          <Icon name="maximize" size={11} />
        </button>
        <button type="button" className="window-close" onClick={onClose} aria-label={t("title.close")}>
          <Icon name="close" size={12} />
        </button>
      </div>
    </header>
  );
}
