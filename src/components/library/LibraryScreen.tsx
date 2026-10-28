import { useEffect, useMemo, useState } from "react";
import type {
  AppSettings,
  GameStatus,
  LibrarySnapshot,
  ModEntry,
  NavSection,
} from "../../types";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { SearchField } from "../ui/SearchField";
import { LaunchStrip } from "./LaunchStrip";
import { ModEditPanel } from "./ModEditPanel";
import { ModInspector } from "./ModInspector";
import { ModTable } from "./ModTable";

interface LibraryScreenProps {
  snapshot: LibrarySnapshot;
  search: string;
  onSearchChange: (search: string) => void;
  onScan: () => void;
  onImport: () => void;
  onToggle: (id: string, enabled: boolean) => void;
  onReorder: (ids: string[]) => void;
  onEdit: (id: string, tags: string[], notes: string) => void;
  onLaunch: () => void;
  onKill: () => void;
  onOpenFolder: (id: string) => void;
  onLaunchOptionsChange: (options: AppSettings["launchOptions"]) => void;
  onNavigate: (section: NavSection) => void;
  gameStatus: GameStatus;
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  fileDragActive: boolean;
}

export function LibraryScreen({
  snapshot,
  search,
  onSearchChange,
  onScan,
  onImport,
  onToggle,
  onReorder,
  onEdit,
  onLaunch,
  onKill,
  onOpenFolder,
  onLaunchOptionsChange,
  onNavigate,
  gameStatus,
  selectedId,
  onSelect,
  fileDragActive,
}: LibraryScreenProps) {
  const [editing, setEditing] = useState<ModEntry | null>(null);
  const [visibleIds, setVisibleIds] = useState<string[] | null>(null);
  const mods = snapshot.mods;

  useEffect(() => {
    if (!selectedId && mods.length > 0) {
      onSelect(sortedMods(mods)[0]?.id ?? null);
    } else if (selectedId && !mods.some((mod) => mod.id === selectedId)) {
      onSelect(sortedMods(mods)[0]?.id ?? null);
    }
  }, [mods, onSelect, selectedId]);

  const selected = mods.find((mod) => mod.id === selectedId) ?? null;
  // 列表被搜索或筛选清空时，右侧不该继续展示一个已经不在结果里的模组。
  const visibleSelected =
    selected && (!visibleIds || visibleIds.includes(selected.id)) ? selected : null;
  const summary = useMemo(() => {
    const enabled = mods.filter((mod) => mod.enabled);
    const totalBytes = enabled.reduce((sum, mod) => sum + mod.fileSize, 0);
    const conflicts = mods.reduce((sum, mod) => sum + mod.conflictCount, 0);
    const updates = mods.filter((mod) => mod.updateVersion).length;
    return { enabled, totalBytes, conflicts, updates };
  }, [mods]);

  return (
    <div className="library-layout">
      <section className="library-main">
        <div className="page-heading">
          <div>
            <h1>模组库</h1>
            <p>拖入 .pak、.zip 或 UE4SS 文件夹即可导入，排序决定加载优先级。</p>
          </div>
          <div className="heading-tools">
            <SearchField
              value={search}
              onChange={onSearchChange}
              placeholder="搜索模组、标签或备注"
            />
            <Button icon="folder" onClick={onScan}>
              扫描
            </Button>
            <Button icon="plus" onClick={onImport}>
              导入
            </Button>
          </div>
        </div>

        <LaunchStrip
          enabledCount={summary.enabled.length}
          totalBytes={summary.totalBytes}
          running={gameStatus.running}
          launchOptions={snapshot.settings.launchOptions}
          onLaunch={onLaunch}
          onKill={onKill}
          onOptionsChange={onLaunchOptionsChange}
          onOpenSettings={() => onNavigate("settings")}
        />

        <ModTable
          mods={sortedMods(mods)}
          selectedId={selectedId}
          search={search}
          locked={gameStatus.running}
          lastDeployedAt={snapshot.lastDeployedAt}
          conflictCount={summary.conflicts}
          onSelect={onSelect}
          onToggle={(id, enabled) => onToggle(id, enabled)}
          onReorder={onReorder}
          onVisibleChange={setVisibleIds}
        />
      </section>

      <ModInspector
        mod={visibleSelected}
        onEdit={() => visibleSelected && setEditing(visibleSelected)}
        onOpenFolder={() => visibleSelected && onOpenFolder(visibleSelected.id)}
      />

      {editing ? (
        <ModEditPanel
          mod={editing}
          onSave={(tags, notes) => onEdit(editing.id, tags, notes)}
          onClose={() => setEditing(null)}
        />
      ) : null}

      {fileDragActive ? (
        <div className="library-drop-overlay" role="status" aria-live="polite">
          <div className="library-drop-card">
            <span className="library-drop-icon">
              <Icon name="plus" size={22} />
            </span>
            <b>松开以导入模组</b>
            <span>支持 .pak、.zip 和 UE4SS 模组文件夹</span>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function sortedMods(mods: ModEntry[]) {
  return [...mods].sort((a, b) => a.loadOrder - b.loadOrder);
}
