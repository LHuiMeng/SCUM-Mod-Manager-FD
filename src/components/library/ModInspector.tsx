import type { ModEntry } from "../../types";
import { compactHash, formatBytes, formatDate, modMonogram, modTypeLabel } from "../../lib/format";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { Tag } from "../ui/Tag";

interface ModInspectorProps {
  mod: ModEntry | null;
  onEdit: () => void;
  onOpenFolder: () => void;
}

export function ModInspector({ mod, onEdit, onOpenFolder }: ModInspectorProps) {
  if (!mod) {
    return (
      <aside className="inspector inspector-empty">
        <span className="empty-selection-mark">
          <Icon name="box" size={30} />
        </span>
        <h2>选择一个模组</h2>
        <p>在左侧列表中选择条目，查看加载顺序、校验状态和本地备注。</p>
      </aside>
    );
  }

  return (
    <aside className="inspector">
      <div className="inspector-preview">
        <span className="inspector-monogram">{modMonogram(mod.name)}</span>
        <svg viewBox="0 0 300 220" aria-hidden="true">
          <path d="M34 174c52-31 86-67 124-66 41 1 59 26 103 4" />
          <path d="M27 194c55-31 93-68 132-67 46 1 67 28 115 5" />
          <path d="M44 155c45-27 78-58 112-57 35 1 51 22 91 3" />
          <path d="M58 136c36-22 66-48 96-47 29 1 43 18 77 2" />
        </svg>
        <div className="preview-meta">
          <span className="preview-badge">
            <i />
            已选模组
          </span>
          <span className="preview-badge">{mod.updateVersion ? `可更新 ${mod.updateVersion}` : "本地版本"}</span>
        </div>
      </div>
      <div className="inspector-body">
        <span className="inspector-kicker">
          {mod.tags[0] ?? "未分类"} / {modTypeLabel(mod.type)}
        </span>
        <h2>{mod.name}</h2>
        <div className="inspector-byline">
          {mod.originSource === "cloud" ? "云端来源" : "本地文件"} · 更新于 {formatDate(mod.lastModified)}
        </div>
        <div className="tag-row">
          {mod.tags.length > 0 ? mod.tags.map((tag) => <Tag key={tag}>{tag}</Tag>) : <Tag>未分类</Tag>}
        </div>
        <Button className="detail-action" trailingIcon="edit" onClick={onEdit}>
          编辑标签与备注
        </Button>

        <section className="inspector-section">
          <div className="section-title">
            <span>模组概览</span>
            <b className={mod.conflictCount > 0 ? "is-warn" : "is-good"}>
              {mod.conflictCount > 0 ? `${mod.conflictCount} 个冲突` : "校验通过"}
            </b>
          </div>
          <div className="detail-facts">
            <div>
              <span>文件大小</span>
              <b>{formatBytes(mod.fileSize)}</b>
            </div>
            <div>
              <span>加载位置</span>
              <b>{mod.enabled ? String(mod.loadOrder + 1).padStart(2, "0") : "停用"}</b>
            </div>
            <div>
              <span>模组类型</span>
              <b>{modTypeLabel(mod.type)}</b>
            </div>
            <div>
              <span>最近更新</span>
              <b>{formatDate(mod.lastModified)}</b>
            </div>
          </div>
          <div className={`health-row ${mod.conflictCount > 0 ? "has-conflict" : ""}`}>
            <span className="health-icon">
              <Icon name={mod.conflictCount > 0 ? "serverOff" : "check"} size={13} />
            </span>
            <span>
              <b>{mod.conflictCount > 0 ? "检测到资源覆盖" : "未检测到资源冲突"}</b>
              <span>
                {mod.conflictCount > 0
                  ? "请检查右侧冲突详情后再启动"
                  : "与当前启用模组的资源清单兼容"}
              </span>
            </span>
          </div>
        </section>

        <section className="inspector-section">
          <div className="section-title">
            <span>本地备注</span>
            <b>仅保存在当前设备</b>
          </div>
          <div className={`note-box ${mod.notes ? "" : "is-empty"}`}>
            {mod.notes || "还没有备注。记录兼容性、服务器用途或测试结果。"}
          </div>
        </section>
      </div>
      <div className="inspector-footer">
        <span>SHA-256 {compactHash(mod.sha256)}</span>
        <button type="button" onClick={onOpenFolder}>
          打开文件目录 →
        </button>
      </div>
    </aside>
  );
}
