import { useMemo, useState } from "react";
import type { AppEdition, CloudDownloadProgress, RemoteMod } from "../../types";
import { useI18n } from "../../i18n";
import {
  cloudDownloadDetail,
  cloudDownloadIsActive,
  cloudDownloadPercent,
  cloudDownloadPhaseLabel,
} from "../../lib/cloudDownload";
import { formatBytes, formatDate, modTypeKey } from "../../lib/format";
import { Button } from "../ui/Button";
import { EmptyState } from "../ui/EmptyState";
import { Icon } from "../ui/Icon";
import { ModCover } from "../ui/ModCover";
import { SearchField } from "../ui/SearchField";
import { Tag } from "../ui/Tag";

interface CloudScreenProps {
  mods: RemoteMod[];
  loading: boolean;
  downloads: Record<string, CloudDownloadProgress>;
  error: string | null;
  loaded: boolean;
  attempt: number;
  autoAttempts: number;
  manualOnly: boolean;
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
  loaded,
  attempt,
  autoAttempts,
  manualOnly,
  configured,
  edition,
  maxSegments,
  onRefresh,
  onDownload,
  onOpenSettings,
}: CloudScreenProps) {
  const { t, language } = useI18n();
  const [search, setSearch] = useState("");
  const filtered = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) return mods;
    return mods.filter((mod) =>
      [mod.name, mod.author, mod.description, ...mod.tags].join(" ").toLowerCase().includes(query),
    );
  }, [mods, search]);
  const installedCount = useMemo(
    () => mods.filter((mod) => mod.installed).length,
    [mods],
  );
  const refreshLabel = loading
    ? t(attempt > 0 ? "cloud.loadingAttempt" : "cloud.loading", {
        attempt,
        total: autoAttempts,
      })
    : manualOnly
      ? t("cloud.manualRetry")
      : loaded
        ? t("cloud.refresh")
        : t("cloud.fetch");
  return (
    <section className="page page-cloud">
      <header className="page-header">
        <div>
          <h1>{t("cloud.title")}</h1>
          <p>{t("cloud.subtitle")}</p>
        </div>
        <div className="heading-tools">
          <SearchField
            value={search}
            onChange={setSearch}
            placeholder={t("cloud.searchPlaceholder")}
          />
          <Button
            icon="refresh"
            onClick={onRefresh}
            disabled={loading}
          >
            {refreshLabel}
          </Button>
          <Button icon="settings" onClick={onOpenSettings}>
            {t("cloud.settings")}
          </Button>
        </div>
      </header>

      <section className={`cloud-edition-strip ${edition === "server" ? "is-server" : ""}`}>
        <span className="cloud-edition-mark">
          <Icon name={edition === "server" ? "lock" : "cloud"} size={15} />
        </span>
        <div>
          <b>
            {t(edition === "server" ? "cloud.edition.server" : "cloud.edition.public")}
          </b>
          <span>
            {t(
              edition === "server"
                ? "cloud.edition.serverDetail"
                : "cloud.edition.publicDetail",
            )}
          </span>
        </div>
        {manualOnly ? (
          <span className="cloud-manual-state">
            {t("cloud.manualState", { attempts: autoAttempts })}
          </span>
        ) : configured && !error && mods.length > 0 ? (
          <span className="cloud-edition-meta">
            {t("cloud.meta.count", { count: mods.length })}
            {installedCount > 0
              ? t("cloud.meta.installed", { count: installedCount })
              : ""}
          </span>
        ) : null}
      </section>

      {!configured ? (
        <EmptyState
          icon="cloud"
          title={t("cloud.empty.unconfiguredTitle")}
          description={t("cloud.empty.unconfiguredDescription")}
          action={
            <Button variant="primary" onClick={onOpenSettings}>
              {t("cloud.empty.openSettings")}
            </Button>
          }
        />
      ) : error ? (
        <EmptyState
          icon="cloud"
          title={t("cloud.empty.unreachableTitle")}
          description={
            manualOnly
              ? `${error} ${t("cloud.manualOnlyHint", { attempts: autoAttempts })}`
              : error
          }
          action={<Button onClick={onRefresh}>{t("cloud.manualRetry")}</Button>}
        />
      ) : !loaded && loading ? (
        <EmptyState
          icon="cloud"
          title={t("cloud.fetchingTitle")}
          description={t("cloud.loadingAttempt", {
            attempt: Math.max(attempt, 1),
            total: autoAttempts,
          })}
        />
      ) : !loaded ? (
        <EmptyState
          icon="cloud"
          title={t("cloud.notLoadedTitle")}
          description={t("cloud.notLoadedDescription")}
          action={<Button onClick={onRefresh}>{t("cloud.fetch")}</Button>}
        />
      ) : filtered.length === 0 && !loading ? (
        <EmptyState
          icon="cloud"
          title={t("cloud.empty.noMatchTitle")}
          description={t("cloud.empty.noMatchDescription")}
        />
      ) : (
        <div className="remote-grid">
          {filtered.map((mod) => {
            const progress = downloads[mod.id];
            const active = progress ? cloudDownloadIsActive(progress) : false;
            const percent = progress ? cloudDownloadPercent(progress) : 0;
            const detail = progress ? cloudDownloadDetail(progress, t) : "";
            const activeLabel = progress
              ? cloudDownloadPhaseLabel(progress.phase, t)
              : "";
            const done = progress?.phase === "completed";
            return (
              <article className="remote-card" key={mod.id} data-mod-type={mod.type}>
                <header>
                  <ModCover
                    name={mod.name}
                    src={mod.coverUrl}
                    className="remote-mark"
                    imageClassName="remote-mark-image"
                  />
                  <div className="remote-identity">
                    <b className="remote-name" title={mod.name}>
                      {mod.name}
                    </b>
                    <span className="remote-byline" title={`${mod.author} · v${mod.version}`}>
                      {mod.author} · v{mod.version}
                    </span>
                  </div>
                  <div className="remote-badges">
                    <span className="remote-state">{t(modTypeKey(mod.type))}</span>
                    {mod.installed ? (
                      <span className="remote-installed">{t("cloud.installed")}</span>
                    ) : null}
                  </div>
                </header>

                <p className="remote-description" title={mod.description || undefined}>
                  {mod.description || t("cloud.noDescription")}
                </p>

                <div className="remote-tags">
                  {mod.tags.length > 0 ? (
                    mod.tags.slice(0, 4).map((tag) => <Tag key={tag}>{tag}</Tag>)
                  ) : (
                    <span className="remote-empty-label">{t("cloud.noTags")}</span>
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
                        <span>{t("cloud.installedLocal")}</span>
                      </div>
                    ) : (
                      <>
                        <div className="remote-download-top">
                          <span>{cloudDownloadPhaseLabel(progress.phase, t)}</span>
                          <b>{percent}%</b>
                        </div>
                        <div
                          className="remote-progress-track"
                          role="progressbar"
                          aria-label={t("cloud.downloadProgress", { name: mod.name })}
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
                    {formatBytes(mod.fileSize)} ·{" "}
                    {t("cloud.updatedAt", {
                      date: formatDate(mod.updatedAt, language),
                    })}
                  </span>
                  <Button
                    size="sm"
                    icon="download"
                    onClick={() => onDownload(mod.id)}
                    disabled={!configured || active}
                  >
                    {active
                      ? activeLabel
                      : mod.installed
                        ? t("cloud.downloadAgain")
                        : t("cloud.download")}
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
          {t("cloud.footnote", { segments: maxSegments })}
        </span>
      </div>
    </section>
  );
}
