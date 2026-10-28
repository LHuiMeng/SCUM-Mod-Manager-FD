import type { PointerEvent as ReactPointerEvent } from "react";
import type { ModEntry } from "../../types";
import { formatBytes, formatDate, modMonogram, modTypeLabel } from "../../lib/format";
import { Icon } from "../ui/Icon";
import { Toggle } from "../ui/Toggle";

interface ModRowProps {
  mod: ModEntry;
  selected: boolean;
  sortable: boolean;
  dragging: boolean;
  dragOver: boolean;
  onSelect: () => void;
  onToggle: (enabled: boolean) => void;
  onPointerDown: (event: ReactPointerEvent<HTMLDivElement>) => void;
}

export function ModRow({
  mod,
  selected,
  sortable,
  dragging,
  dragOver,
  onSelect,
  onToggle,
  onPointerDown,
}: ModRowProps) {
  const status = mod.updateVersion
    ? `有新版本 ${mod.updateVersion}`
    : mod.enabled
      ? `加载顺序 ${String(mod.loadOrder + 1).padStart(2, "0")}`
      : "已停用";

  const className = [
    "mod-row",
    selected ? "is-selected" : "",
    dragOver ? "is-drag-over" : "",
    dragging ? "is-dragging" : "",
    sortable ? "is-sortable" : "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <div
      className={className}
      role="row"
      tabIndex={0}
      aria-selected={selected}
      data-mod-id={mod.id}
      onClick={onSelect}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onSelect();
        }
      }}
      onPointerDown={onPointerDown}
    >
      <span className="mod-check" aria-hidden="true">
        {selected ? <Icon name="check" size={10} /> : null}
      </span>
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
      <span onClick={(event) => event.stopPropagation()} onPointerDown={(event) => event.stopPropagation()}>
        <Toggle
          checked={mod.enabled}
          onChange={onToggle}
          label={mod.enabled ? `停用 ${mod.name}` : `启用 ${mod.name}`}
        />
      </span>
      {sortable ? (
        <span className="row-drag" title="拖动调整加载顺序">
          <Icon name="drag" size={14} />
        </span>
      ) : null}
    </div>
  );
}
