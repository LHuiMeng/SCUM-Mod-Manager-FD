import type { PointerEvent as ReactPointerEvent } from "react";
import type { ModEntry } from "../../types";
import { useI18n } from "../../i18n";
import { formatBytes, formatDate, modTypeKey } from "../../lib/format";
import { Icon } from "../ui/Icon";
import { ModCover } from "../ui/ModCover";
import { Toggle } from "../ui/Toggle";

interface ModRowProps {
  mod: ModEntry;
  selected: boolean;
  sortable: boolean;
  showLoadOrder: boolean;
  locked: boolean;
  dragging: boolean;
  dragOver: boolean;
  removing: boolean;
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
  removing,
  onSelect,
  onToggle,
  onMove,
  onPointerDown,
}: ModRowProps) {
  const { t, language } = useI18n();
  const loadOrder = String(mod.loadOrder + 1).padStart(2, "0");
  const overriding = mod.overridingFileCount ?? 0;
  const overridden = mod.overriddenFileCount ?? 0;
  const statusLabel = mod.enabled
    ? showLoadOrder
      ? t("library.row.statusEnabledOrder", { order: loadOrder })
      : t("common.enabled")
    : t("common.disabled");
  const conflictLabel = mod.fullyOverridden
    ? t("library.row.overrideStatusFull", {
        overrides: overriding,
        overridden,
      })
    : t("library.row.overrideStatus", {
        overrides: overriding,
        overridden,
      });

  const className = [
    "mod-row",
    selected ? "is-selected" : "",
    mod.fullyOverridden ? "is-fully-overridden" : "",
    dragOver ? "is-drag-over" : "",
    dragging ? "is-dragging" : "",
    removing ? "is-removing" : "",
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
      data-mod-type={mod.type}
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
      <ModCover
        name={mod.name}
        src={mod.coverUrl}
        className={`mod-thumb ${mod.type === "ue4ssMod" ? "is-ue4ss" : ""}`}
      />
      <div className="mod-row-main">
        <b>{mod.name}</b>
        <span className="mod-row-subline">
          <span className={`mod-state-pill ${mod.enabled ? "is-on" : "is-off"}`}>
            <i />
            {statusLabel}
          </span>
          <span
            className={`mod-conflict-pill ${
              mod.fullyOverridden ? "is-full" : overriding + overridden > 0 ? "has-conflict" : ""
            }`}
            title={conflictLabel}
          >
            {conflictLabel}
          </span>
          {mod.updateVersion ? (
            <span className="mod-update-pill">
              {t("library.row.update", { version: mod.updateVersion })}
            </span>
          ) : null}
          <span className="mod-row-meta">
            {mod.tags[0] ?? t("common.uncategorized")} <i />{" "}
            {formatDate(mod.lastModified, language)}
          </span>
        </span>
      </div>
      <span className="mod-type">{t(modTypeKey(mod.type))}</span>
      <span className="mod-size">{formatBytes(mod.fileSize)}</span>
      <span
        className="mod-toggle-cell"
        onClick={(event) => event.stopPropagation()}
        onPointerDown={(event) => event.stopPropagation()}
        title={locked ? t("library.row.lockTitle") : undefined}
      >
        <Toggle
          checked={mod.enabled}
          onChange={onToggle}
          disabled={locked}
          label={t(mod.enabled ? "library.row.disable" : "library.row.enable", {
            name: mod.name,
          })}
        />
      </span>
      {sortable ? (
        <span className="row-drag" aria-hidden="true" title={t("library.row.dragTitle")}>
          <Icon name="drag" size={14} />
        </span>
      ) : null}
    </div>
  );
}
