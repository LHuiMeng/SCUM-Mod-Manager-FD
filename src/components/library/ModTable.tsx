import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import type {
  CSSProperties,
  PointerEvent as ReactPointerEvent,
} from "react";
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
  lockedMessage?: string;
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

interface DragSlot {
  id: string;
  top: number;
  height: number;
}

interface DragPreview {
  sourceIndex: number;
  targetIndex: number;
  offsetY: number;
  markerTop: number;
  rowHeight: number;
}

interface RowPosition {
  left: number;
  top: number;
}

interface PendingDrag {
  id: string;
  startY: number;
  started: boolean;
  grabOffsetY: number;
  pointerId: number;
  captureElement: HTMLElement;
}

export function ModTable({
  mods,
  selectedId,
  search,
  locked,
  lockedMessage,
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
  const [dragPreview, setDragPreview] = useState<DragPreview | null>(null);
  const [enteringIds, setEnteringIds] = useState<Set<string>>(() => new Set());
  const [toggleFeedback, setToggleFeedback] = useState<{
    id: string;
    tone: "on" | "off";
  } | null>(null);
  const [dropSettledId, setDropSettledId] = useState<string | null>(null);

  const listRef = useRef<HTMLDivElement | null>(null);
  const pendingRef = useRef<PendingDrag | null>(null);
  const dragPreviewRef = useRef<DragPreview | null>(null);
  const dragSlotsRef = useRef<DragSlot[]>([]);
  const suppressClickRef = useRef(false);
  const modsRef = useRef(mods);
  const reorderRef = useRef(onReorder);
  const positionsRef = useRef<Map<string, RowPosition>>(new Map());
  const dropPositionsRef = useRef<Map<string, RowPosition> | null>(null);
  const initialReflowRef = useRef(true);
  const knownModIdsRef = useRef<Set<string> | null>(null);
  const enteringTimerRef = useRef<number | null>(null);
  const toggleTimerRef = useRef<number | null>(null);
  const settleTimerRef = useRef<number | null>(null);
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

  const filteredKey = filtered.map((mod) => mod.id).join("|");

  useLayoutEffect(() => {
    const current = captureRowPositions();
    if (initialReflowRef.current) {
      initialReflowRef.current = false;
      positionsRef.current = current;
      return;
    }

    const previous = dropPositionsRef.current ?? positionsRef.current;
    dropPositionsRef.current = null;
    positionsRef.current = current;
    if (
      typeof window === "undefined" ||
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ) {
      return;
    }

    for (const row of listRef.current?.querySelectorAll<HTMLElement>(".mod-row") ?? []) {
      const id = row.dataset.modId;
      if (!id) continue;
      const before = previous.get(id);
      const after = current.get(id);
      if (!before || !after) continue;
      const deltaX = before.left - after.left;
      const deltaY = before.top - after.top;
      if (Math.abs(deltaX) < 0.5 && Math.abs(deltaY) < 0.5) continue;
      row.animate(
        [
          { transform: `translate3d(${deltaX}px, ${deltaY}px, 0)` },
          { transform: "translate3d(0, 0, 0)" },
        ],
        {
          duration: 260,
          easing: "cubic-bezier(0.22, 1, 0.36, 1)",
        },
      );
    }
  }, [filteredKey]);

  useEffect(() => {
    const ids = mods.map((mod) => mod.id);
    if (!knownModIdsRef.current) {
      knownModIdsRef.current = new Set(ids);
      return;
    }
    const removed = new Set(ids);
    const added = ids.filter((id) => !knownModIdsRef.current?.has(id));
    knownModIdsRef.current = removed;
    if (added.length === 0) return;
    setEnteringIds(new Set(added));
    if (enteringTimerRef.current !== null) {
      window.clearTimeout(enteringTimerRef.current);
    }
    enteringTimerRef.current = window.setTimeout(() => {
      setEnteringIds(new Set());
      enteringTimerRef.current = null;
    }, 900);
  }, [mods]);

  useEffect(
    () => () => {
      for (const timer of [
        enteringTimerRef.current,
        toggleTimerRef.current,
        settleTimerRef.current,
      ]) {
        if (timer !== null) window.clearTimeout(timer);
      }
    },
    [],
  );

  const counts = useMemo(
    () => ({
      all: mods.length,
      client: mods.filter((mod) => mod.type === "clientPak").length,
      ue4ss: mods.filter((mod) => mod.type === "ue4ssMod").length,
      updates: mods.filter((mod) => mod.updateVersion).length,
    }),
    [mods],
  );

  const canDrag =
    sortMode === "load" && filter === "all" && !search.trim() && !locked;
  const dragHint = canDrag
    ? t("library.dragHint.active")
    : locked
      ? lockedMessage ?? t("library.dragHint.locked")
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

  function captureRowPositions(): Map<string, RowPosition> {
    const positions = new Map<string, RowPosition>();
    for (const row of listRef.current?.querySelectorAll<HTMLElement>(".mod-row") ?? []) {
      const id = row.dataset.modId;
      if (!id) continue;
      const rect = row.getBoundingClientRect();
      positions.set(id, { left: rect.left, top: rect.top });
    }
    return positions;
  }

  function captureDragSlots(): DragSlot[] {
    const list = listRef.current;
    if (!list) return [];
    const listRect = list.getBoundingClientRect();
    const rows = [
      ...list.querySelectorAll<HTMLElement>(".mod-row"),
    ];
    return rows.flatMap((row) => {
      const id = row.dataset.modId;
      if (!id) return [];
      const rect = row.getBoundingClientRect();
      return [
        {
          id,
          top: rect.top - listRect.top + list.scrollTop,
          height: rect.height,
        },
      ];
    });
  }

  function commitReorder(sourceId: string, targetIndex: number) {
    const ordered = [...modsRef.current]
      .sort((a, b) => a.loadOrder - b.loadOrder)
      .map((mod) => mod.id);
    const from = ordered.indexOf(sourceId);
    if (
      from < 0 ||
      targetIndex < 0 ||
      targetIndex >= ordered.length ||
      from === targetIndex
    ) {
      return false;
    }
    ordered.splice(from, 1);
    ordered.splice(targetIndex, 0, sourceId);
    reorderRef.current(ordered);
    return true;
  }

  function showDropSettled(id: string) {
    setDropSettledId(id);
    if (settleTimerRef.current !== null) {
      window.clearTimeout(settleTimerRef.current);
    }
    settleTimerRef.current = window.setTimeout(() => {
      setDropSettledId(null);
      settleTimerRef.current = null;
    }, 360);
  }

  function updateDragPreview(clientY: number, pending: PendingDrag) {
    const list = listRef.current;
    const slots = dragSlotsRef.current;
    const sourceIndex = slots.findIndex((slot) => slot.id === pending.id);
    if (!list || slots.length === 0 || sourceIndex < 0) return;

    const listRect = list.getBoundingClientRect();
    const viewportY = clientY - listRect.top;
    if (viewportY < 36) {
      list.scrollTop = Math.max(0, list.scrollTop - 10);
    } else if (viewportY > listRect.height - 36) {
      list.scrollTop += 10;
    }

    const contentY = clientY - listRect.top + list.scrollTop;
    let targetIndex = slots.length - 1;
    for (let index = 0; index < slots.length; index += 1) {
      const slot = slots[index];
      if (contentY < slot.top + slot.height / 2) {
        targetIndex = index;
        break;
      }
    }

    const source = slots[sourceIndex];
    const minimumOffset = -source.top;
    const maximumOffset = Math.max(
      minimumOffset,
      list.scrollHeight - source.top - source.height,
    );
    const offsetY = Math.min(
      maximumOffset,
      Math.max(minimumOffset, contentY - pending.grabOffsetY - source.top),
    );
    const next: DragPreview = {
      sourceIndex,
      targetIndex,
      offsetY,
      markerTop: slots[targetIndex].top,
      rowHeight: source.height,
    };
    const current = dragPreviewRef.current;
    if (
      current?.sourceIndex === next.sourceIndex &&
      current.targetIndex === next.targetIndex &&
      Math.abs(current.offsetY - next.offsetY) < 0.25 &&
      current.markerTop === next.markerTop &&
      current.rowHeight === next.rowHeight
    ) {
      return;
    }
    dragPreviewRef.current = next;
    setDragPreview(next);
  }

  /** 键盘排序：Alt+↑/↓ 把当前行上移/下移一格。 */
  const moveBy = useCallback((id: string, delta: number) => {
    const ordered = [...modsRef.current]
      .sort((a, b) => a.loadOrder - b.loadOrder)
      .map((mod) => mod.id);
    const from = ordered.indexOf(id);
    const to = from + delta;
    if (from < 0 || to < 0 || to >= ordered.length) return;
    dropPositionsRef.current = captureRowPositions();
    ordered.splice(from, 1);
    ordered.splice(to, 0, id);
    reorderRef.current(ordered);
    showDropSettled(id);
  }, []);

  // HTML5 draggable 在 Tauri 的 WebView2 里会被窗口级文件拖放吃掉，
  // 所以排序走 pointer 事件，和文件拖入互不干扰。
  useEffect(() => {
    function onMove(event: PointerEvent) {
      const pending = pendingRef.current;
      if (!pending || event.pointerId !== pending.pointerId) return;
      if (!pending.started) {
        if (Math.abs(event.clientY - pending.startY) < DRAG_THRESHOLD) return;
        pending.started = true;
        setDragId(pending.id);
        document.body.classList.add("is-row-dragging");
      }
      event.preventDefault();
      updateDragPreview(event.clientY, pending);
    }

    function finish(commit: boolean) {
      const pending = pendingRef.current;
      pendingRef.current = null;
      document.body.classList.remove("is-row-dragging");
      if (
        pending &&
        pending.captureElement.hasPointerCapture(pending.pointerId)
      ) {
        try {
          pending.captureElement.releasePointerCapture(pending.pointerId);
        } catch {
          // The pointer may already be released by the browser.
        }
      }
      setDragId(null);
      setDragPreview(null);
      const preview = dragPreviewRef.current;
      dragPreviewRef.current = null;
      if (!pending?.started) return;

      if (
        commit &&
        preview &&
        preview.targetIndex !== preview.sourceIndex
      ) {
        dropPositionsRef.current = captureRowPositions();
        if (commitReorder(pending.id, preview.targetIndex)) {
          showDropSettled(pending.id);
        } else {
          dropPositionsRef.current = null;
        }
        // 拖拽结束后的 pointerup 会补一个 click，别让它把选中态也改掉。
        suppressClickRef.current = true;
        window.setTimeout(() => {
          suppressClickRef.current = false;
        }, 0);
      }
    }

    window.addEventListener("pointermove", onMove, { passive: false });
    const onPointerUp = (event: PointerEvent) => {
      if (pendingRef.current?.pointerId === event.pointerId) finish(true);
    };
    const onPointerCancel = (event: PointerEvent) => {
      if (pendingRef.current?.pointerId === event.pointerId) finish(false);
    };
    window.addEventListener("pointerup", onPointerUp);
    window.addEventListener("pointercancel", onPointerCancel);
    return () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onPointerUp);
      window.removeEventListener("pointercancel", onPointerCancel);
      document.body.classList.remove("is-row-dragging");
    };
  }, []);

  function handlePointerDown(
    event: ReactPointerEvent<HTMLDivElement>,
    modId: string,
  ) {
    if (!canDrag || event.button !== 0) return;
    if ((event.target as HTMLElement).closest(".toggle, button, input, textarea")) {
      return;
    }
    const row = event.currentTarget;
    const rect = row.getBoundingClientRect();
    dragSlotsRef.current = captureDragSlots();
    try {
      row.setPointerCapture(event.pointerId);
    } catch {
      // Synthetic pointer tests and rare WebView cases may not expose capture.
    }
    pendingRef.current = {
      id: modId,
      startY: event.clientY,
      started: false,
      grabOffsetY: event.clientY - rect.top,
      pointerId: event.pointerId,
      captureElement: row,
    };
  }

  function handleToggle(modId: string, enabled: boolean) {
    onToggle(modId, enabled);
    const tone = enabled ? "on" : "off";
    setToggleFeedback({ id: modId, tone });
    if (toggleTimerRef.current !== null) {
      window.clearTimeout(toggleTimerRef.current);
    }
    toggleTimerRef.current = window.setTimeout(() => {
      setToggleFeedback(null);
      toggleTimerRef.current = null;
    }, 520);
  }

  const dragStatus = dragPreview
    ? t("library.dragHint.dropAt", {
        order: String(dragPreview.targetIndex + 1).padStart(2, "0"),
      })
    : null;

  function dragShiftFor(index: number): "up" | "down" | null {
    if (!dragPreview || index === dragPreview.sourceIndex) return null;
    if (
      dragPreview.sourceIndex < dragPreview.targetIndex &&
      index > dragPreview.sourceIndex &&
      index <= dragPreview.targetIndex
    ) {
      return "up";
    }
    if (
      dragPreview.targetIndex < dragPreview.sourceIndex &&
      index >= dragPreview.targetIndex &&
      index < dragPreview.sourceIndex
    ) {
      return "down";
    }
    return null;
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
        className={`mod-rows ${dragId ? "is-sorting" : ""} ${
          dragPreview ? "has-drop-preview" : ""
        }`}
        ref={listRef}
        role="listbox"
        aria-label={t("library.table.listLabel")}
      >
        {dragPreview ? (
          <div
            className="mod-drop-indicator"
            aria-hidden="true"
            style={
              {
                "--drop-marker-top": `${dragPreview.markerTop}px`,
                "--drop-marker-height": `${dragPreview.rowHeight}px`,
              } as CSSProperties
            }
          >
            <span>{dragStatus}</span>
          </div>
        ) : null}
        {filtered.length === 0 ? (
          <EmptyState
            icon="box"
            title={t("library.empty.title")}
            description={t("library.empty.description")}
          />
        ) : (
          filtered.map((mod, index) => {
            const dragging = dragId === mod.id;
            return (
              <ModRow
                key={mod.id}
                mod={mod}
                selected={selectedId === mod.id}
                sortable={canDrag}
                showLoadOrder={sortMode === "load"}
                locked={locked}
                lockedTitle={lockedMessage}
                dragging={dragging}
                dragShift={dragShiftFor(index)}
                dragOffsetY={dragging ? dragPreview?.offsetY ?? null : null}
                removing={removingId === mod.id}
                entering={enteringIds.has(mod.id)}
                toggleFeedback={
                  toggleFeedback?.id === mod.id ? toggleFeedback.tone : null
                }
                dropSettled={dropSettledId === mod.id}
                onSelect={() => {
                  if (suppressClickRef.current) return;
                  onSelect(mod.id);
                }}
                onToggle={(enabled) => handleToggle(mod.id, enabled)}
                onMove={(delta) => moveBy(mod.id, delta)}
                onPointerDown={(event) => handlePointerDown(event, mod.id)}
              />
            );
          })
        )}
      </div>
      <div className={`table-foot ${dragPreview ? "is-drop-preview" : ""}`}>
        <span aria-live={dragPreview ? "polite" : "off"}>
          {t("library.foot.showing", { shown: filtered.length, total: mods.length })} ·{" "}
          <b className={dragPreview ? "is-drop-status" : ""}>
            {dragStatus ?? dragHint}
          </b>
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
