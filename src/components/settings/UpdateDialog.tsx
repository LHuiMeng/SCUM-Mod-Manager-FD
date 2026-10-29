import type { AppUpdateInfo, AppUpdatePhase, AppUpdateProgress } from "../../types";
import { useI18n } from "../../i18n";
import { formatBytes, formatDate } from "../../lib/format";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";

interface UpdateDialogProps {
  info: AppUpdateInfo;
  phase: AppUpdatePhase;
  progress: AppUpdateProgress | null;
  error: string | null;
  onClose: () => void;
  onInstall: () => void;
}

export function UpdateDialog({
  info,
  phase,
  progress,
  error,
  onClose,
  onInstall,
}: UpdateDialogProps) {
  const { t, language } = useI18n();
  const busy = phase === "downloading" || phase === "verifying" || phase === "installing";
  const percent =
    progress?.total && progress.total > 0
      ? Math.min(100, Math.round((progress.downloaded / progress.total) * 100))
      : phase === "verifying" || phase === "installing"
        ? 100
        : null;

  return (
    <Modal
      wide
      title={t("update.dialog.title", { version: info.version ?? "" })}
      description={t("update.dialog.description")}
      onClose={busy ? () => undefined : onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={busy}>
            {t("update.dialog.later")}
          </Button>
          <Button
            variant="primary"
            icon="download"
            onClick={onInstall}
            disabled={busy}
          >
            {phase === "downloading"
              ? t("update.dialog.downloading")
              : phase === "verifying"
                ? t("update.dialog.verifying")
                : phase === "installing"
                  ? t("update.dialog.installing")
                  : t("update.dialog.install")}
          </Button>
        </>
      }
    >
      <div className="update-version-line">
        <span>{info.currentVersion}</span>
        <i />
        <b>{info.version}</b>
      </div>

      <div className="update-facts">
        <div>
          <span>{t("update.dialog.fileSize")}</span>
          <b>
            {info.size ? formatBytes(info.size) : t("update.dialog.confirmOnDownload")}
          </b>
        </div>
        <div>
          <span>{t("update.dialog.publishedAt")}</span>
          <b>{formatDate(info.publishedAt, language)}</b>
        </div>
        <div>
          <span>{t("update.dialog.security")}</span>
          <b className="is-safe">
            <Icon name="lock" size={13} />
            {t("update.dialog.signature")}
          </b>
        </div>
      </div>

      <section className="update-notes">
        <span>{t("update.dialog.notes")}</span>
        <p>{info.notes || t("update.dialog.notesFallback")}</p>
      </section>

      {busy ? (
        <div className="update-progress-card">
          <div>
            <span>
              {phase === "downloading"
                ? t("update.status.downloading")
                : phase === "verifying"
                  ? t("update.dialog.verifyingSignature")
                  : t("update.dialog.installerStarted")}
            </span>
            <b>{percent !== null ? `${percent}%` : t("update.dialog.autoVerify")}</b>
          </div>
          <i>
            <span style={{ width: percent !== null ? `${percent}%` : "42%" }} />
          </i>
          <small>
            {phase === "installing"
              ? t("update.dialog.restartHint")
              : t("update.dialog.keepOpen")}
          </small>
        </div>
      ) : null}

      {error ? <div className="update-error">{error}</div> : null}

      <div className="update-safety-note">
        <Icon name="lock" size={15} />
        <span>
          {t("update.dialog.safety")}
        </span>
      </div>
    </Modal>
  );
}
