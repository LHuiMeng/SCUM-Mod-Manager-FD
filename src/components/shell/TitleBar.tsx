import type { GameStatus, NavSection, ThemeMode } from "../../types";
import { Icon } from "../ui/Icon";

const titles: Record<NavSection, string> = {
  library: "模组库",
  cloud: "云端目录",
  server: "远程服务器",
  logs: "运行日志",
  settings: "设置",
};

interface TitleBarProps {
  section: NavSection;
  theme: ThemeMode;
  gameStatus: GameStatus;
  deployedSize: string;
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
  deployedSize,
  lastChecked,
  updateAvailable,
  updateVersion,
  onToggleTheme,
  onOpenUpdate,
  onMinimize,
  onMaximize,
  onClose,
}: TitleBarProps) {
  return (
    <header className="titlebar" data-tauri-drag-region>
      <div className="crumb" data-tauri-drag-region>
        <span>SCUM MOD DESK</span>
        <i>/</i>
        <b>{titles[section]}</b>
      </div>
      <div className="title-status" data-tauri-drag-region>
        {updateAvailable ? (
          <button type="button" className="update-notice" onClick={onOpenUpdate}>
            <i />
            {updateVersion ? `${updateVersion} 可用` : "有更新"}
          </button>
        ) : null}
        <span
          className={`status-live ${gameStatus.running ? "is-running" : ""}`}
          data-tauri-drag-region
        >
          {gameStatus.running ? "游戏运行中" : "客户端路径正常"}
        </span>
        <span className="title-deployed" data-tauri-drag-region>
          {deployedSize} 已部署
        </span>
        <span className="title-checked" data-tauri-drag-region>
          上次检查 {lastChecked}
        </span>
        <button
          type="button"
          className="theme-switch"
          onClick={onToggleTheme}
          aria-label={theme === "dark" ? "切换至亮色主题" : "切换至暗色主题"}
          title="切换亮色 / 暗色主题"
        >
          <Icon name={theme === "dark" ? "moon" : "sun"} size={13} />
          <span>{theme === "dark" ? "暗色" : "亮色"}</span>
        </button>
      </div>
      <div className="window-actions">
        <button type="button" onClick={onMinimize} aria-label="最小化">
          <Icon name="minimize" size={12} />
        </button>
        <button type="button" onClick={onMaximize} aria-label="最大化">
          <Icon name="maximize" size={11} />
        </button>
        <button type="button" className="window-close" onClick={onClose} aria-label="关闭">
          <Icon name="close" size={12} />
        </button>
      </div>
    </header>
  );
}
