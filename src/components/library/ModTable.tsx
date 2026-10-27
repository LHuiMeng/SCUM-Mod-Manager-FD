import { useMemo, useState, type DragEvent } from "react";
import type { ModEntry } from "../../types";
import { EmptyState } from "../ui/EmptyState";
import { ModRow } from "./ModRow";

type FilterId = "all" | "client" | "ue4ss" | "updates";
type SortMode = "load" | "name" | "size";

interface ModTableProps {
  mods: ModEntry[];
  selectedId: string | null;
  search: string;
  hasActiveFilter: boolean;
  onSelect: (id: string) => void;
  onToggle: (id: string, enabled: boolean) => void;
  onReorder: (ids: string[]) => void;
}

export function ModTable({
  mods,
  selectedId,
  search,
  hasActiveFilter,
  onSelect,
  onToggle,
  onReorder,
}: ModTableProps) {
  const [filter, setFilter] = useState<FilterId>("all");
  const [sortMode, setSortMode] = useState<SortMode>("load");
  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [dragOverId, setDragOverId] = useState<string | null>(null);

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
          return left.name.localeCompare(right.name, "zh-CN");
        }
        if (sortMode === "size") {
          return right.fileSize - left.fileSize;
        }
        return left.loadOrder - right.loadOrder;
      });
  }, [filter, mods, search, sortMode]);

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
    sortMode === "load" && filter === "all" && !search.trim() && !hasActiveFilter;

  const sortLabel = {
    load: "按加载顺序",
    name: "按名称",
    size: "按文件大小",
  }[sortMode];

  function cycleSortMode() {
    setSortMode((current) =>
      current === "load" ? "name" : current === "name" ? "size" : "load",
    );
  }

  function handleDragStart(event: DragEvent<HTMLDivElement>, modId: string) {
    if (!canDrag) {
      event.preventDefault();
      return;
    }
    setDraggingId(modId);
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", modId);
  }

  function handleDrop(event: DragEvent<HTMLDivElement>, targetId: string) {
    event.preventDefault();
    const sourceId = draggingId ?? event.dataTransfer.getData("text/plain");
    setDraggingId(null);
    setDragOverId(null);
    if (!sourceId || sourceId === targetId || !canDrag) return;
    const ordered = [...mods].sort((a, b) => a.loadOrder - b.loadOrder).map((mod) => mod.id);
    const sourceIndex = ordered.indexOf(sourceId);
    const targetIndex = ordered.indexOf(targetId);
    ordered.splice(sourceIndex, 1);
    ordered.splice(targetIndex, 0, sourceId);
    onReorder(ordered);
  }

  return (
    <section className="table-card" aria-label="本地模组列表">
      <div className="table-toolbar">
        {(
          [
            ["all", "全部", counts.all],
            ["client", "客户端 PAK", counts.client],
            ["ue4ss", "UE4SS", counts.ue4ss],
            ["updates", "有更新", counts.updates],
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
            aria-label="切换排序方式"
            title="切换排序方式"
            onClick={cycleSortMode}
          >
            <span>↕</span>
          </button>
        </div>
      </div>
      <div className="table-head">
        <span />
        <span />
        <span>模组</span>
        <span>类型</span>
        <span>大小</span>
        <span>启用</span>
      </div>
      <div className="mod-rows">
        {filtered.length === 0 ? (
          <EmptyState
            icon="box"
            title="没有符合条件的模组"
            description="换一个关键词或筛选条件，或者导入新的 PAK 文件。"
          />
        ) : (
          filtered.map((mod) => (
            <ModRow
              key={mod.id}
              mod={mod}
              selected={selectedId === mod.id}
              draggable={canDrag}
              dragOver={dragOverId === mod.id}
              onSelect={() => onSelect(mod.id)}
              onToggle={(enabled) => onToggle(mod.id, enabled)}
              onDragStart={(event) => handleDragStart(event, mod.id)}
              onDragOver={(event) => {
                if (!canDrag) return;
                event.preventDefault();
                event.dataTransfer.dropEffect = "move";
                setDragOverId(mod.id);
              }}
              onDrop={(event) => handleDrop(event, mod.id)}
              onDragEnd={() => {
                setDraggingId(null);
                setDragOverId(null);
              }}
            />
          ))
        )}
      </div>
      <div className="table-foot">
        <span>
          显示 {filtered.length} / {mods.length} · <b>{canDrag ? "拖拽可调整加载顺序" : "清除筛选后可排序"}</b>
        </span>
        <span>本地文件优先 · SHA-256 延迟校验</span>
      </div>
    </section>
  );
}
