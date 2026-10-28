import { useMemo, useState } from "react";
import type { AppEdition, CloudDownloadProgress, RemoteMod } from "../../types";
import {
  cloudDownloadDetail,
  cloudDownloadIsActive,
  cloudDownloadPercent,
  cloudDownloadPhaseLabel,
} from "../../lib/cloudDownload";
import { formatBytes, formatDate, modMonogram, modTypeLabel } from "../../lib/format";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { Icon } from "../ui/Icon";
import { SearchField } from "../ui/SearchField";
import { Tag } from "../ui/Tag";

interface CloudScreenProps {
  mods: RemoteMod[];
  loading: boolean;
  downloads: Record<string, CloudDownloadProgress>;
  error: string | null;
  configured: boolean;
  edition: AppEdition;
  maxSegments: number;
  onRefresh: () => void;
  onDownload: (id: string) => void;
  onOpenSettings: () => void;
}

export function CloudScreen({
  mods,
  loading,
  downloads,
  error,
  configured,
  edition,
  maxSegments,
  onRefresh,
  onDownload,
  onOpenSettings,
}: CloudScreenProps) {
  const [search, setSearch] = useState("");
  const filtered = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) return mods;
    return mods.filter((mod) =>
      [mod.name, mod.author, mod.description, ...mod.tags].join(" ").toLowerCase().includes(query),
    );
  }, [mods, search]);
  return (
    <section className="page page-cloud">
      <header className="page-header">
        <div>
          <h1>云端目录</h1>
          <p>从云源安装模组，下载完成后自动进入本地库。</p>
        </div>
        <div className="heading-tools">
          <SearchField value={search} onChange={setSearch} placeholder="搜索云端模组" />
          <Button
            icon="refresh"
            onClick={onRefresh}
            disabled={loading}
          >
            {loading ? "正在获取" : "刷新目录"}
          </Button>
          <Button icon="settings" onClick={onOpenSettings}>
            云源设置
          </Button>
        </div>
      </header>

      <section className={`cloud-edition-strip ${edition === "server" ? "is-server" : ""}`}>
        <span className="cloud-edition-mark">
          <Icon name={edition === "server" ? "lock" : "cloud"} size={15} />
        </span>
        <div>
          <b>{edition === "server" ? "服务器版目录" : "公开版目录"}</b>
          <span>
            {edition === "server"
              ? "内置共享凭据，可读取公开模组与服务器版模组。"
              : "此安装包不含私人凭据，只能读取公开模组。"}
          </span>
        </div>
      </section>

      {!configured ? (
        <EmptyState
          icon="cloud"
          title="尚未配置云源"
          description="安装包没有预置可用云源。请先在设置中配置线路，或安装带默认云源的正式版本。"
          action={
            <Button variant="primary" onClick={onOpenSettings}>
              打开云源设置
            </Button>
          }
        />
      ) : error ? (
        <EmptyState
          icon="cloud"
          title="无法连接云服务器"
          description={error}
          action={<Button onClick={onRefresh}>重新尝试</Button>}
        />
      ) : filtered.length === 0 && !loading ? (
        <EmptyState
          icon="cloud"
          title="目录中没有匹配项"
          description="换一个关键词，或者刷新云端目录。"
        />
      ) : (
        <div className="remote-grid">
          {filtered.map((mod) => {
            const progress = downloads[mod.id];
            const active = progress ? cloudDownloadIsActive(progress) : false;
            const percent = progress ? cloudDownloadPercent(progress) : 0;
            const detail = progress ? cloudDownloadDetail(progress) : "";
            const activeLabel = progress ? cloudDownloadPhaseLabel(progress.phase) : "";
            const done = progress?.phase === "completed";
            return (
              <article className="remote-card" key={mod.id}>
                <header>
                  <span className="remote-mark">{modMonogram(mod.name)}</span>
                  <div className="remote-identity">
                    <b className="remote-name" title={mod.name}>
                      {mod.name}
                    </b>
                    <span className="remote-byline" title={`${mod.author} · v${mod.version}`}>
                      {mod.author} · v{mod.version}
                    </span>
                  </div>
                  <div className="remote-badges">
                    <span className="remote-state">{modTypeLabel(mod.type)}</span>
                    {mod.installed ? <span className="remote-installed">已安装</span> : null}
                  </div>
                </header>

                <p className="remote-description" title={mod.description || undefined}>
                  {mod.description || "暂无模组描述"}
                </p>

                <div className="remote-tags">
                  {mod.tags.length > 0 ? (
                    mod.tags.slice(0, 4).map((tag) => <Tag key={tag}>{tag}</Tag>)
                  ) : (
                    <span className="remote-empty-label">暂无标签</span>
                  )}
                  {mod.tags.length > 4 ? (
                    <span className="remote-empty-label">+{mod.tags.length - 4}</span>
                  ) : null}
                </div>

                {progress ? (
                  <div className={`remote-download-progress is-${progress.phase}`}>
                    {done ? (
                      <div className="remote-download-done">
                        <Icon name="check" size={13} />
                        <span>已安装到本地库</span>
                      </div>
                    ) : (
                      <>
                        <div className="remote-download-top">
                          <span>{cloudDownloadPhaseLabel(progress.phase)}</span>
                          <b>{percent}%</b>
                        </div>
                        <div
                          className="remote-progress-track"
                          role="progressbar"
                          aria-label={`${mod.name} 下载进度`}
                          aria-valuemin={0}
                          aria-valuemax={100}
                          aria-valuenow={percent}
                        >
                          <i style={{ width: `${percent}%` }} />
                        </div>
                        <div className="remote-download-detail" title={detail}>
                          {detail}
                        </div>
                      </>
                    )}
                  </div>
                ) : null}

                <footer>
                  <span>
                    {formatBytes(mod.fileSize)} · 更新于 {formatDate(mod.updatedAt)}
                  </span>
                  <Button
                    size="sm"
                    icon="download"
                    onClick={() => onDownload(mod.id)}
                    disabled={!configured || active}
                  >
                    {active
                      ? `${activeLabel} ${percent}%`
                      : mod.installed
                        ? "重新下载"
                        : "下载"}
                  </Button>
                </footer>
              </article>
            );
          })}
        </div>
      )}

      <div className="page-footnote">
        <Icon name="lock" size={13} />
        <span>
          下载与校验都由 Rust 后端完成，单模组最多 {maxSegments} 路分片。
        </span>
      </div>
    </section>
  );
}
