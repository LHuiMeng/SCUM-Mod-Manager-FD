import type { PointerEvent, ReactNode } from "react";
import type { GameStatus, NavSection, ThemeMode } from "../../types";
import { Sidebar } from "./Sidebar";
import { TitleBar } from "./TitleBar";

type WindowResizeDirection =
  | "East"
  | "North"
  | "NorthEast"
  | "NorthWest"
  | "South"
  | "SouthEast"
  | "SouthWest"
  | "West";

const RESIZE_HANDLES: Array<{
  direction: WindowResizeDirection;
  className: string;
}> = [
  { direction: "North", className: "is-north" },
  { direction: "South", className: "is-south" },
  { direction: "West", className: "is-west" },
  { direction: "East", className: "is-east" },
  { direction: "NorthWest", className: "is-north-west" },
  { direction: "NorthEast", className: "is-north-east" },
  { direction: "SouthWest", className: "is-south-west" },
  { direction: "SouthEast", className: "is-south-east" },
];

interface AppShellProps {
  section: NavSection;
  theme: ThemeMode;
  gameStatus: GameStatus;
  hasClientPath: boolean;
  enabledCount: number;
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

function startWindowResize(
  event: PointerEvent<HTMLDivElement>,
  direction: WindowResizeDirection,
) {
  if (event.button !== 0 || !window.__TAURI_INTERNALS__) return;
  event.preventDefault();
  event.stopPropagation();
  void import("@tauri-apps/api/window")
    .then(({ getCurrentWindow }) =>
      getCurrentWindow().startResizeDragging(direction),
    )
    .catch(() => undefined);
}

export function AppShell({
  section,
  theme,
  gameStatus,
  hasClientPath,
  enabledCount,
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
    <>
      {!maximized ? (
        <div className="window-resize-layer" aria-hidden="true">
          {RESIZE_HANDLES.map(({ direction, className }) => (
            <div
              key={direction}
              className={`window-resize-handle ${className}`}
              onPointerDown={(event) => startWindowResize(event, direction)}
            />
          ))}
        </div>
      ) : null}
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
            hasClientPath={hasClientPath}
            enabledCount={enabledCount}
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
    </>
  );
}
