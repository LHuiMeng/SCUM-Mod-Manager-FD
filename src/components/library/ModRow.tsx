import type { DragEvent } from "react";
import type { ModEntry } from "../../types";
import { formatBytes, formatDate, modMonogram, modTypeLabel } from "../../lib/format";
import { Icon } from "../ui/Icon";
import { Toggle } from "../ui/Toggle";

interface ModRowProps {
  mod: ModEntry;
  selected: boolean;
  draggable: boolean;
  dragOver: boolean;
  onSelect: () => void;
  onToggle: (enabled: boolean) => void;
  onDragStart: (event: DragEvent<HTMLDivElement>) => void;
  onDragOver: (event: DragEvent<HTMLDivElement>) => void;
  onDrop: (event: DragEvent<HTMLDivElement>) => void;
  onDragEnd: () => void;
}

export function ModRow({
  mod,
  selected,
  draggable,
  dragOver,
  onSelect,
  onToggle,
  onDragStart,
  onDragOver,
  onDrop,
  onDragEnd,
}: ModRowProps) {
  const status = mod.updateVersion
    ? `有新版本 ${mod.updateVersion}`
    : mod.enabled
      ? `加载顺序 ${String(mod.loadOrder + 1).padStart(2, "0")}`
      : "已停用";

  return (
    <div
      className={`mod-row ${selected ? "is-selected" : ""} ${dragOver ? "is-drag-over" : ""}`}
      role="row"
      tabIndex={0}
      aria-selected={selected}
      onClick={onSelect}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onSelect();
        }
      }}
      draggable={draggable}
      onDragStart={onDragStart}
      onDragOver={onDragOver}
      onDrop={onDrop}
      onDragEnd={onDragEnd}
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
      <span onClick={(event) => event.stopPropagation()}>
        <Toggle
          checked={mod.enabled}
          onChange={onToggle}
          label={mod.enabled ? `停用 ${mod.name}` : `启用 ${mod.name}`}
        />
      </span>
      {draggable ? (
        <span className="row-drag" aria-hidden="true">
          <Icon name="drag" size={14} />
        </span>
      ) : null}
    </div>
  );
}
