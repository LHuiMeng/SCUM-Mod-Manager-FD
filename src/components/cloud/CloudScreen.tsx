import { useMemo, useState } from "react";
import type { AppEdition, RemoteMod } from "../../types";
import { formatBytes, formatDate, modTypeLabel } from "../../lib/format";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { Icon } from "../ui/Icon";
import { SearchField } from "../ui/SearchField";
import { Tag } from "../ui/Tag";

interface CloudScreenProps {
  mods: RemoteMod[];
  loading: boolean;
  error: string | null;
  configured: boolean;
  edition: AppEdition;
  onRefresh: () => void;
  onDownload: (id: string) => void;
  onOpenSettings: () => void;
}

export function CloudScreen({
  mods,
  loading,
  error,
  configured,
  edition,
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
          <p>从已配置的云源获取模组，下载后先在本地完成 SHA-256 校验。</p>
        </div>
        <div className="heading-tools">
          <SearchField value={search} onChange={setSearch} placeholder="搜索云端模组" />
          <Button icon="refresh" onClick={onRefresh} disabled={loading}>
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
              ? "安装包内置共享凭据，可读取公开模组与仅限服务器玩家的模组。"
              : "此安装包不包含私人凭据，只能读取公开模组。"}
          </span>
        </div>
      </section>

      {!configured ? (
        <EmptyState
          icon="cloud"
          title="尚未配置云源"
          description="云源地址不写死在程序里。请先在设置中配置线路，或通过 secrets 注入开发环境。"
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
          {filtered.map((mod) => (
            <article className="remote-card" key={mod.id}>
              <header>
                <span className="remote-mark">{mod.name.slice(0, 2).toUpperCase()}</span>
                <div>
                  <b>{mod.name}</b>
                  <span>
                    {mod.author} · v{mod.version}
                  </span>
                </div>
                <span className={`remote-state ${mod.installed ? "is-installed" : ""}`}>
                  {mod.installed ? "已安装" : modTypeLabel(mod.type)}
                </span>
              </header>
              <p>{mod.description}</p>
              <div className="tag-row">
                {mod.tags.map((tag) => (
                  <Tag key={tag}>{tag}</Tag>
                ))}
              </div>
              <footer>
                <span>
                  {formatBytes(mod.fileSize)} · 更新于 {formatDate(mod.updatedAt)}
                </span>
                <Button
                  size="sm"
                  icon="download"
                  onClick={() => onDownload(mod.id)}
                  disabled={!configured || loading}
                >
                  {mod.installed ? "重新下载" : "下载"}
                </Button>
              </footer>
            </article>
          ))}
        </div>
      )}

      <div className="page-footnote">
        <Icon name="lock" size={13} />
        <span>云端请求与下载均由 Rust 后端完成，前端不读取共享密钥。</span>
      </div>
    </section>
  );
}
