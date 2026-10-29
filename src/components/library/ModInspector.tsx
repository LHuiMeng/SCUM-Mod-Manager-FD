import type { ModEntry } from "../../types";
import { useI18n } from "../../i18n";
import { compactHash, formatBytes, formatDate, modMonogram, modTypeKey } from "../../lib/format";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { ModCover } from "../ui/ModCover";
import { Tag } from "../ui/Tag";

interface ModInspectorProps {
  mod: ModEntry | null;
  onEdit: () => void;
  onDelete: () => void;
  onOpenFolder: () => void;
  onOpenConflicts: () => void;
}

export function ModInspector({
  mod,
  onEdit,
  onDelete,
  onOpenFolder,
  onOpenConflicts,
}: ModInspectorProps) {
  const { t, language } = useI18n();
  if (!mod) {
    return (
      <aside className="inspector inspector-empty">
        <span className="empty-selection-mark">
          <Icon name="box" size={30} />
        </span>
        <h2>{t("inspector.emptyTitle")}</h2>
        <p>{t("inspector.emptyDescription")}</p>
      </aside>
    );
  }

  const hasHash = Boolean(mod.sha256);

  return (
    <aside className="inspector" data-mod-type={mod.type}>
      <div className="inspector-preview">
        <ModCover
          name={mod.name}
          src={mod.coverUrl}
          className="inspector-art"
          imageClassName="inspector-art-image"
        />
        <span className="inspector-monogram" aria-hidden="true">
          {modMonogram(mod.name)}
        </span>
        <div className="preview-meta">
          <span className={`preview-badge ${mod.enabled ? "is-on" : "is-off"}`}>
            <i />
            {mod.enabled
              ? t("inspector.enabledOrder", {
                  order: String(mod.loadOrder + 1).padStart(2, "0"),
                })
              : t("common.disabled")}
          </span>
          <span className={`preview-badge ${mod.conflictCount > 0 ? "is-warn" : ""}`}>
            {mod.conflictCount > 0
              ? t("common.conflictCount", { count: mod.conflictCount })
              : t("common.noConflict")}
          </span>
          {mod.duplicateCount ? (
            <span className="preview-badge is-muted">
              {t("inspector.duplicateCopies", { count: mod.duplicateCount })}
            </span>
          ) : null}
        </div>
      </div>
      <div className="inspector-body">
        <span className="inspector-kicker">
          {t(modTypeKey(mod.type))} ·{" "}
          {t(mod.originSource === "cloud" ? "inspector.originCloud" : "inspector.originLocal")}
        </span>
        <h2>{mod.name}</h2>
        {mod.author ? (
          <div className="inspector-author">
            {t("inspector.author", { name: mod.author })}
          </div>
        ) : null}
        <div className="tag-row">
          {mod.tags.length > 0 ? (
            mod.tags.map((tag) => <Tag key={tag}>{tag}</Tag>)
          ) : (
            <Tag>{t("common.uncategorized")}</Tag>
          )}
        </div>
        <Button className="detail-action" trailingIcon="edit" onClick={onEdit}>
          {t("inspector.edit")}
        </Button>

        <section className="inspector-section">
          <div className="section-title">
            <span>{t("inspector.presentation")}</span>
            <b>
              {mod.coverUrl
                ? t("inspector.coverLoaded")
                : t("inspector.defaultMonogram")}
            </b>
          </div>
          <p className={`inspector-description ${mod.description ? "" : "is-empty"}`}>
            {mod.description || t("inspector.descriptionEmpty")}
          </p>
        </section>

        <section className="inspector-section">
          <div className="section-title">
            <span>{t("inspector.overview")}</span>
            <b className={mod.conflictCount > 0 ? "is-warn" : hasHash ? "is-good" : "is-muted"}>
              {mod.conflictCount > 0
                ? t("common.conflictCount", { count: mod.conflictCount })
                : hasHash
                  ? t("inspector.hashRecorded")
                  : t("inspector.unverified")}
            </b>
          </div>
          <div className="detail-facts">
            <div>
              <span>{t("inspector.fileSize")}</span>
              <b>{formatBytes(mod.fileSize)}</b>
            </div>
            <div>
              <span>{t("inspector.loadOrder")}</span>
              <b>
                {mod.enabled
                  ? String(mod.loadOrder + 1).padStart(2, "0")
                  : t("inspector.disabledShort")}
              </b>
            </div>
            <div>
              <span>{t("inspector.recentUpdate")}</span>
              <b>{formatDate(mod.lastModified, language)}</b>
            </div>
          </div>
          {mod.conflictCount > 0 ? (
            <button
              type="button"
              className="health-row has-conflict conflict-health-trigger"
              onClick={onOpenConflicts}
              aria-haspopup="dialog"
            >
              <span className="health-icon">
                <Icon name="serverOff" size={13} />
              </span>
              <span className="health-copy">
                <b>
                  {mod.fullyOverridden
                    ? t("inspector.fullyOverriddenTitle")
                    : t("inspector.conflictTitle")}
                </b>
                <span>
                  {mod.fullyOverridden
                    ? t("inspector.fullyOverriddenDetail")
                    : t("inspector.conflictDetail")}
                </span>
              </span>
              <span className="conflict-health-chevron" aria-hidden="true">
                <Icon name="chevronRight" size={14} />
              </span>
            </button>
          ) : (
            <div className={`health-row ${hasHash ? "" : "is-unverified"}`}>
              <span className="health-icon">
                <Icon name={hasHash ? "check" : "refresh"} size={13} />
              </span>
              <span className="health-copy">
                <b>
                  {hasHash
                    ? t("inspector.noConflictTitle")
                    : t("inspector.noHashTitle")}
                </b>
                <span>
                  {hasHash
                    ? t("inspector.noConflictDetail")
                    : t("inspector.noHashDetail")}
                </span>
              </span>
            </div>
          )}
        </section>

        <section className="inspector-section">
          <div className="section-title">
            <span>{t("inspector.notesTitle")}</span>
            <b>{t("inspector.deviceOnly")}</b>
          </div>
          <div className={`note-box ${mod.notes ? "" : "is-empty"}`}>
            {mod.notes || t("inspector.notesEmpty")}
          </div>
        </section>
      </div>
      <div className="inspector-footer">
        <div className="inspector-footer-meta">
          <span>
            SHA-256 {compactHash(mod.sha256, t("common.notCalculated"))}
          </span>
          <button type="button" onClick={onOpenFolder}>
            {t("inspector.openFolder")}
          </button>
        </div>
        <Button
          className="inspector-delete-button"
          size="sm"
          variant="danger"
          icon="trash"
          onClick={onDelete}
        >
          {t("inspector.delete")}
        </Button>
      </div>
    </aside>
  );
}
