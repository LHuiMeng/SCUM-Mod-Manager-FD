import type { AppUpdateInfo, AppUpdatePhase, AppUpdateProgress } from "../../types";
import { useI18n, type Translator } from "../../i18n";
import { formatBytes, formatDate } from "../../lib/format";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";

interface UpdateSettingsProps {
  info: AppUpdateInfo | null;
  phase: AppUpdatePhase;
  progress: AppUpdateProgress | null;
  error: string | null;
  onCheck: () => void;
  onShowDetails: () => void;
}

export function UpdateSettings({
  info,
  phase,
  progress,
  error,
  onCheck,
  onShowDetails,
}: UpdateSettingsProps) {
  const { t, language } = useI18n();
  const checking = phase === "checking";
  const busy = checking || phase === "downloading" || phase === "verifying" || phase === "installing";
  const percent =
    progress?.total && progress.total > 0
      ? Math.min(100, Math.round((progress.downloaded / progress.total) * 100))
      : null;

  return (
    <section className="settings-group">
      <div className="section-title">
        <span>{t("update.sectionTitle")}</span>
        <b>{t("update.channel")}</b>
      </div>
      <div className="update-overview">
        <span className={`update-mark ${phase === "available" ? "is-available" : ""}`}>
          <Icon name={phase === "available" ? "download" : "refresh"} size={19} />
        </span>
        <div className="update-copy">
          <b>
            SCUM Mod Desk {info?.currentVersion ?? ""}
            {phase === "available" && info?.version ? ` → ${info.version}` : ""}
          </b>
          <span>{statusText(info, phase, error, t)}</span>
        </div>
        <div className="update-actions">
          {phase === "available" ? (
            <Button onClick={onShowDetails}>{t("update.view")}</Button>
          ) : (
            <Button icon="refresh" onClick={onCheck} disabled={busy}>
              {checking ? t("update.checking") : t("update.check")}
            </Button>
          )}
        </div>
      </div>

      {busy && phase !== "checking" ? (
        <div className="update-inline-progress">
          <div>
            <span>{progressLabel(phase, t)}</span>
            <b>{percent !== null ? `${percent}%` : t("update.verifyingShort")}</b>
          </div>
          <i>
            <span style={{ width: percent !== null ? `${percent}%` : "36%" }} />
          </i>
        </div>
      ) : null}

      {phase === "available" && info ? (
        <div className="update-available-meta">
          <span>
            {info.size ? formatBytes(info.size) : t("update.sizeFromPage")}
          </span>
          <span>
            {t("update.publishedAt", {
              date: formatDate(info.publishedAt, language),
            })}
          </span>
          <span>
            <Icon name="lock" size={12} />
            {t("update.signedOnly")}
          </span>
        </div>
      ) : null}

      <p className="settings-note update-note">
        {t("update.note")}
      </p>
    </section>
  );
}

function statusText(
  info: AppUpdateInfo | null,
  phase: AppUpdatePhase,
  error: string | null,
  t: Translator,
) {
  if (phase === "checking") return t("update.status.checking");
  if (phase === "unconfigured") return t("update.status.unconfigured");
  if (phase === "error") return error ?? t("update.status.errorFallback");
  if (phase === "up-to-date") return t("update.status.upToDate");
  if (phase === "downloading") return t("update.status.downloading");
  if (phase === "verifying") return t("update.status.verifying");
  if (phase === "installing") return t("update.status.installing");
  if (phase === "available" && info?.version) {
    return t("update.status.available", { version: info.version });
  }
  return t("update.status.idle");
}

function progressLabel(phase: AppUpdatePhase, t: Translator) {
  if (phase === "verifying") return t("update.progress.verifying");
  if (phase === "installing") return t("update.progress.installing");
  return t("update.progress.download");
}
