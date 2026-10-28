import type { PointerEvent as ReactPointerEvent } from "react";
import type { ModEntry } from "../../types";
import { formatBytes, formatDate, modMonogram, modTypeLabel } from "../../lib/format";
import { Icon } from "../ui/Icon";
import { Toggle } from "../ui/Toggle";

interface ModRowProps {
  mod: ModEntry;
  selected: boolean;
  sortable: boolean;
  showLoadOrder: boolean;
  locked: boolean;
  dragging: boolean;
  dragOver: boolean;
  onSelect: () => void;
  onToggle: (enabled: boolean) => void;
  onMove: (delta: number) => void;
  onPointerDown: (event: ReactPointerEvent<HTMLDivElement>) => void;
}

export function ModRow({
  mod,
  selected,
  sortable,
  showLoadOrder,
  locked,
  dragging,
  dragOver,
  onSelect,
  onToggle,
  onMove,
  onPointerDown,
}: ModRowProps) {
  const status = mod.updateVersion
    ? `有新版本 ${mod.updateVersion}`
    : !mod.enabled
      ? "已停用"
      : showLoadOrder
        ? `加载顺序 ${String(mod.loadOrder + 1).padStart(2, "0")}`
        : "已启用";

  const className = [
    "mod-row",
    selected ? "is-selected" : "",
    dragOver ? "is-drag-over" : "",
    dragging ? "is-dragging" : "",
    sortable ? "is-sortable" : "",
    locked ? "is-locked" : "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <div
      className={className}
      role="option"
      aria-selected={selected}
      tabIndex={0}
      data-mod-id={mod.id}
      onClick={onSelect}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onSelect();
          return;
        }
        if (!sortable || !event.altKey) return;
        if (event.key === "ArrowUp") {
          event.preventDefault();
          onMove(-1);
        } else if (event.key === "ArrowDown") {
          event.preventDefault();
          onMove(1);
        }
      }}
      onPointerDown={onPointerDown}
    >
      <span className={`mod-thumb ${mod.type === "ue4ssMod" ? "is-ue4ss" : ""}`}>
        {modMonogram(mod.name)}
      </span>
      <div className="mod-row-main">
        <b>{mod.name}</b>
        <span>
          {mod.tags[0] ?? "未分类"} <i /> {formatDate(mod.lastModified)} <i /> {status}
        </span>
      </div>
      <span className="mod-type">{modTypeLabel(mod.type)}</span>
      <span className="mod-size">{formatBytes(mod.fileSize)}</span>
      <span
        className="mod-toggle-cell"
        onClick={(event) => event.stopPropagation()}
        onPointerDown={(event) => event.stopPropagation()}
        title={locked ? "游戏运行期间不能更改启用状态" : undefined}
      >
        <Toggle
          checked={mod.enabled}
          onChange={onToggle}
          disabled={locked}
          label={mod.enabled ? `停用 ${mod.name}` : `启用 ${mod.name}`}
        />
      </span>
      {sortable ? (
        <span className="row-drag" aria-hidden="true" title="拖动或 Alt+↑/↓ 调整加载顺序">
          <Icon name="drag" size={14} />
        </span>
      ) : null}
    </div>
  );
}
