import type { AppSettings } from "../../../types";
import { useI18n } from "../../../i18n";
import { normalizePort } from "../../../lib/serverPort";
import { Toggle } from "../../ui/Toggle";

interface StartupSectionProps {
  draft: AppSettings;
  update: (patch: Partial<AppSettings>) => void;
  onLaunchOptionsChange: (options: AppSettings["launchOptions"]) => void;
}

export function StartupSection({
  draft,
  update,
  onLaunchOptionsChange,
}: StartupSectionProps) {
  const { t } = useI18n();

  function updateLaunchOptions(patch: Partial<AppSettings["launchOptions"]>) {
    const next = { ...draft.launchOptions, ...patch };
    update({ launchOptions: next });
    onLaunchOptionsChange(next);
  }

  return (
    <section className="settings-group">
      <div className="section-title">
        <span>{t("settings.startup.title")}</span>
        <b>{t("settings.startup.note")}</b>
      </div>
      <div className="setting-switches">
        <label>
          <span>
            <b>{t("settings.startup.log")}</b>
            <small>{t("settings.startup.logDetail")}</small>
          </span>
          <Toggle
            checked={draft.launchOptions.log}
            onChange={(log) => updateLaunchOptions({ log })}
            label={t("settings.startup.log")}
          />
        </label>
        <label>
          <span>
            <b>{t("settings.startup.fileLog")}</b>
            <small>{t("settings.startup.fileLogDetail")}</small>
          </span>
          <Toggle
            checked={draft.launchOptions.fileOpenLog}
            onChange={(fileOpenLog) => updateLaunchOptions({ fileOpenLog })}
            label={t("settings.startup.fileLog")}
          />
        </label>
        <label>
          <span>
            <b>{t("settings.startup.battlEye")}</b>
            <small>{t("settings.startup.battlEyeDetail")}</small>
          </span>
          <Toggle
            checked={draft.launchOptions.noBattlEye}
            onChange={(noBattlEye) => updateLaunchOptions({ noBattlEye })}
            label={t("settings.startup.battlEye")}
          />
        </label>
        <label>
          <span>
            <b>{t("settings.startup.keepDeployed")}</b>
            <small>{t("settings.startup.keepDeployedDetail")}</small>
          </span>
          <Toggle
            checked={draft.keepDeployedModsOnExit}
            onChange={(keepDeployedModsOnExit) => update({ keepDeployedModsOnExit })}
            label={t("settings.startup.keepDeployed")}
          />
        </label>
        <label>
          <span>
            <b>{t("settings.startup.useDeployLinks")}</b>
            <small>{t("settings.startup.useDeployLinksDetail")}</small>
          </span>
          <Toggle
            checked={draft.useDeployLinks}
            onChange={(useDeployLinks) => update({ useDeployLinks })}
            label={t("settings.startup.useDeployLinks")}
          />
        </label>
        <label>
          <span>
            <b>{t("settings.startup.autoMergeConflicts")}</b>
            <small>{t("settings.startup.autoMergeConflictsDetail")}</small>
          </span>
          <Toggle
            checked={draft.autoMergeConflicts}
            onChange={(autoMergeConflicts) => update({ autoMergeConflicts })}
            label={t("settings.startup.autoMergeConflicts")}
          />
        </label>
        <label>
          <span>
            <b>{t("settings.startup.port")}</b>
            <small>{t("settings.startup.portDetail")}</small>
          </span>
          <input
            className="compact-input"
            value={draft.launchOptions.port}
            inputMode="numeric"
            onChange={(event) =>
              update({ launchOptions: { ...draft.launchOptions, port: event.target.value } })
            }
            onBlur={() => updateLaunchOptions({ port: normalizePort(draft.launchOptions.port) })}
          />
        </label>
      </div>
    </section>
  );
}
