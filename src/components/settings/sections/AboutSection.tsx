import type { AppUpdateInfo, AppUpdatePhase, AppUpdateProgress } from "../../../types";
import { useI18n } from "../../../i18n";
import { UpdateSettings } from "../UpdateSettings";

interface AboutSectionProps {
  version: string | null;
  dataRoot: string | null;
  updateInfo: AppUpdateInfo | null;
  updatePhase: AppUpdatePhase;
  updateProgress: AppUpdateProgress | null;
  updateError: string | null;
  onCheckUpdate: () => void;
  onShowUpdate: () => void;
}

export function AboutSection({
  version,
  dataRoot,
  updateInfo,
  updatePhase,
  updateProgress,
  updateError,
  onCheckUpdate,
  onShowUpdate,
}: AboutSectionProps) {
  const { t } = useI18n();
  return (
    <>
      <UpdateSettings
        info={updateInfo}
        phase={updatePhase}
        progress={updateProgress}
        error={updateError}
        onCheck={onCheckUpdate}
        onShowDetails={onShowUpdate}
      />
      <section className="settings-group">
        <div className="section-title">
          <span>{t("settings.about.title")}</span>
          <b>{t("settings.about.note")}</b>
        </div>
        <dl className="settings-about-facts">
          <div>
            <dt>{t("settings.about.version")}</dt>
            <dd>{version ?? t("common.notRecorded")}</dd>
          </div>
          <div>
            <dt>{t("settings.about.dataRoot")}</dt>
            <dd>
              <code>{dataRoot ?? t("common.notRecorded")}</code>
            </dd>
          </div>
        </dl>
      </section>
    </>
  );
}
