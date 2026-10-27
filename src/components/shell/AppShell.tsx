import type { ReactNode } from "react";
import type { GameStatus, NavSection, ThemeMode } from "../../types";
import { Sidebar } from "./Sidebar";
import { TitleBar } from "./TitleBar";

interface AppShellProps {
  section: NavSection;
  theme: ThemeMode;
  gameStatus: GameStatus;
  deployedSize: string;
  lastChecked: string;
  updateAvailable: boolean;
  updateVersion: string | null;
  maximized: boolean;
  children: ReactNode;
  onSectionChange: (section: NavSection) => void;
  onToggleTheme: () => void;
  onOpenUpdate: () => void;
  onMinimize: () => void;
  onMaximize: () => void;
  onClose: () => void;
}

export function AppShell({
  section,
  theme,
  gameStatus,
  deployedSize,
  lastChecked,
  updateAvailable,
  updateVersion,
  maximized,
  children,
  onSectionChange,
  onToggleTheme,
  onOpenUpdate,
  onMinimize,
  onMaximize,
  onClose,
}: AppShellProps) {
  return (
    <div className={`app-frame ${maximized ? "is-maximized" : ""}`}>
      <Sidebar
        active={section}
        onChange={onSectionChange}
        onSettings={() => onSectionChange("settings")}
      />
      <main className="app-window">
        <TitleBar
          section={section}
          theme={theme}
          gameStatus={gameStatus}
          deployedSize={deployedSize}
          lastChecked={lastChecked}
          updateAvailable={updateAvailable}
          updateVersion={updateVersion}
          onToggleTheme={onToggleTheme}
          onOpenUpdate={onOpenUpdate}
          onMinimize={onMinimize}
          onMaximize={onMaximize}
          onClose={onClose}
        />
        <div className="app-content">{children}</div>
      </main>
    </div>
  );
}
