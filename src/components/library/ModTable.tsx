import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import type { ModEntry } from "../../types";
import { useI18n } from "../../i18n";
import { formatTimestamp } from "../../lib/format";
import { EmptyState } from "../ui/EmptyState";
import { ModRow } from "./ModRow";

type FilterId = "all" | "client" | "ue4ss" | "updates";
type SortMode = "load" | "name" | "size";

interface ModTableProps {
  mods: ModEntry[];
  selectedId: string | null;
  search: string;
  locked: boolean;
  lastDeployedAt: string | null;
  conflictCount: number;
  removingId: string | null;
  onSelect: (id: string) => void;
  onToggle: (id: string, enabled: boolean) => void;
  onReorder: (ids: string[]) => void;
  onVisibleChange: (ids: string[]) => void;
}

/** 指针移动超过这个距离才算拖拽，否则当成点击选中。 */
const DRAG_THRESHOLD = 5;

export function ModTable({
  mods,
  selectedId,
  search,
  locked,
  lastDeployedAt,
  conflictCount,
  removingId,
  onSelect,
  onToggle,
  onReorder,
  onVisibleChange,
}: ModTableProps) {
  const { t, language } = useI18n();
  const [filter, setFilter] = useState<FilterId>("all");
  const [sortMode, setSortMode] = useState<SortMode>("load");
  const [dragId, setDragId] = useState<string | null>(null);
  const [dragOverId, setDragOverId] = useState<string | null>(null);

  const listRef = useRef<HTMLDivElement | null>(null);
  const pendingRef = useRef<{ id: string; startY: number; started: boolean } | null>(
    null,
  );
  const dragOverRef = useRef<string | null>(null);
  const suppressClickRef = useRef(false);
  const modsRef = useRef(mods);
  const reorderRef = useRef(onReorder);
  modsRef.current = mods;
  reorderRef.current = onReorder;

  const filtered = useMemo(() => {
    const query = search.trim().toLowerCase();
    return mods
      .filter((mod) => {
        const matchesFilter =
          filter === "all" ||
          (filter === "client" && mod.type === "clientPak") ||
          (filter === "ue4ss" && mod.type === "ue4ssMod") ||
          (filter === "updates" && Boolean(mod.updateVersion));
        const haystack = [mod.name, mod.description, mod.notes, ...mod.tags]
          .join(" ")
          .toLowerCase();
        return matchesFilter && (!query || haystack.includes(query));
      })
      .sort((left, right) => {
        if (sortMode === "name") {
          return left.name.localeCompare(right.name, language);
        }
        if (sortMode === "size") {
          return right.fileSize - left.fileSize;
        }
        return left.loadOrder - right.loadOrder;
      });
  }, [filter, language, mods, search, sortMode]);

  // 把可见条目交回上层，检查器据此判断当前选中项是否还在列表里。
  const visibleKeyRef = useRef<string>("");
  useEffect(() => {
    const key = filtered.map((mod) => mod.id).join("|");
    if (visibleKeyRef.current === key) return;
    visibleKeyRef.current = key;
    onVisibleChange(filtered.map((mod) => mod.id));
  }, [filtered, onVisibleChange]);

  const counts = useMemo(
    () => ({
      all: mods.length,
      client: mods.filter((mod) => mod.type === "clientPak").length,
      ue4ss: mods.filter((mod) => mod.type === "ue4ssMod").length,
      updates: mods.filter((mod) => mod.updateVersion).length,
    }),
    [mods],
  );

  const canDrag = sortMode === "load" && filter === "all" && !search.trim();
  const dragHint = canDrag
    ? t("library.dragHint.active")
    : sortMode !== "load"
      ? t("library.dragHint.loadOrder")
      : search.trim()
        ? t("library.dragHint.search")
        : t("library.dragHint.filter");

  const sortLabel = {
    load: t("library.sort.load"),
    name: t("library.sort.name"),
    size: t("library.sort.size"),
  }[sortMode];

  function cycleSortMode() {
    setSortMode((current) =>
      current === "load" ? "name" : current === "name" ? "size" : "load",
    );
  }

  const rowIdAt = useCallback((y: number) => {
    const rows = [
      ...(listRef.current?.querySelectorAll<HTMLElement>(".mod-row") ?? []),
    ];
    if (rows.length === 0) return null;
    for (const row of rows) {
      const rect = row.getBoundingClientRect();
      if (y < rect.bottom) return row.dataset.modId ?? null;
    }
    return rows[rows.length - 1].dataset.modId ?? null;
  }, []);

  function commitReorder(sourceId: string, targetId: string) {
    const ordered = [...modsRef.current]
      .sort((a, b) => a.loadOrder - b.loadOrder)
      .map((mod) => mod.id);
    const from = ordered.indexOf(sourceId);
    const to = ordered.indexOf(targetId);
    if (from < 0 || to < 0 || from === to) return;
    ordered.splice(from, 1);
    ordered.splice(to, 0, sourceId);
    reorderRef.current(ordered);
  }

  /** 键盘排序：Alt+↑/↓ 把当前行上移/下移一格。 */
  const moveBy = useCallback((id: string, delta: number) => {
    const ordered = [...modsRef.current]
      .sort((a, b) => a.loadOrder - b.loadOrder)
      .map((mod) => mod.id);
    const from = ordered.indexOf(id);
    const to = from + delta;
    if (from < 0 || to < 0 || to >= ordered.length) return;
    ordered.splice(from, 1);
    ordered.splice(to, 0, id);
    reorderRef.current(ordered);
  }, []);

  // HTML5 draggable 在 Tauri 的 WebView2 里会被窗口级文件拖放吃掉，
  // 所以排序走 pointer 事件，和文件拖入互不干扰。
  useEffect(() => {
    function onMove(event: PointerEvent) {
      const pending = pendingRef.current;
      if (!pending) return;
      if (!pending.started) {
        if (Math.abs(event.clientY - pending.startY) < DRAG_THRESHOLD) return;
        pending.started = true;
        setDragId(pending.id);
        document.body.classList.add("is-row-dragging");
      }
      event.preventDefault();
      const target = rowIdAt(event.clientY);
      dragOverRef.current = target;
      setDragOverId(target);
    }

    function finish() {
      const pending = pendingRef.current;
      pendingRef.current = null;
      document.body.classList.remove("is-row-dragging");
      setDragId(null);
      setDragOverId(null);
      if (!pending?.started) return;
      const target = dragOverRef.current;
      if (target && target !== pending.id) {
        commitReorder(pending.id, target);
        // 拖拽结束后的 pointerup 会补一个 click，别让它把选中态也改掉。
        suppressClickRef.current = true;
        window.setTimeout(() => {
          suppressClickRef.current = false;
        }, 0);
      }
    }

    window.addEventListener("pointermove", onMove, { passive: false });
    window.addEventListener("pointerup", finish);
    window.addEventListener("pointercancel", finish);
    return () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", finish);
      window.removeEventListener("pointercancel", finish);
      document.body.classList.remove("is-row-dragging");
    };
  }, [rowIdAt]);

  function handlePointerDown(
    event: ReactPointerEvent<HTMLDivElement>,
    modId: string,
  ) {
    if (!canDrag || event.button !== 0) return;
    if ((event.target as HTMLElement).closest(".toggle")) return;
    pendingRef.current = { id: modId, startY: event.clientY, started: false };
  }

  return (
    <section className="table-card" aria-label={t("library.table.listLabel")}>
      <div className="table-toolbar">
        {(
          [
            ["all", t("library.filter.all"), counts.all],
            ["client", t("library.filter.client"), counts.client],
            ["ue4ss", t("library.filter.ue4ss"), counts.ue4ss],
            ["updates", t("library.filter.updates"), counts.updates],
          ] as const
        ).map(([id, label, count]) => (
          <button
            type="button"
            key={id}
            className={`filter-chip ${filter === id ? "is-active" : ""}`}
            onClick={() => setFilter(id)}
          >
            {label} {count}
          </button>
        ))}
        <div className="table-toolbar-right">
          <span>{sortLabel}</span>
          <button
            type="button"
            className="tiny-tool"
            aria-label={t("library.sort.toggle")}
            title={t("library.sort.toggle")}
            onClick={cycleSortMode}
          >
            <span>↕</span>
          </button>
        </div>
      </div>
      <div className="table-head" aria-hidden="true">
        <span />
        <span>{t("library.table.mod")}</span>
        <span>{t("library.table.type")}</span>
        <span>{t("library.table.size")}</span>
        <span>{t("library.table.enabled")}</span>
        <span />
      </div>
      <div
        className={`mod-rows ${dragId ? "is-sorting" : ""}`}
        ref={listRef}
        role="listbox"
        aria-label={t("library.table.listLabel")}
      >
        {filtered.length === 0 ? (
          <EmptyState
            icon="box"
            title={t("library.empty.title")}
            description={t("library.empty.description")}
          />
        ) : (
          filtered.map((mod) => (
            <ModRow
              key={mod.id}
              mod={mod}
              selected={selectedId === mod.id}
              sortable={canDrag}
              showLoadOrder={sortMode === "load"}
              locked={locked}
              dragging={dragId === mod.id}
              dragOver={dragOverId === mod.id}
              removing={removingId === mod.id}
              onSelect={() => {
                if (suppressClickRef.current) return;
                onSelect(mod.id);
              }}
              onToggle={(enabled) => onToggle(mod.id, enabled)}
              onMove={(delta) => moveBy(mod.id, delta)}
              onPointerDown={(event) => handlePointerDown(event, mod.id)}
            />
          ))
        )}
      </div>
      <div className="table-foot">
        <span>
          {t("library.foot.showing", { shown: filtered.length, total: mods.length })} ·{" "}
          <b>{dragHint}</b>
        </span>
        <span>
          {lastDeployedAt
            ? t("library.foot.deployed", {
                time: formatTimestamp(lastDeployedAt, language),
              })
            : t("library.foot.neverDeployed")}
          {conflictCount > 0
            ? t("library.foot.conflicts", { count: conflictCount })
            : t("library.foot.noConflicts")}
        </span>
      </div>
    </section>
  );
}
