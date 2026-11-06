import type { AppEdition, AppSettings } from "../../../types";
import { useI18n } from "../../../i18n";
import { clampCloudDownloadSegments } from "../../../lib/cloudDownload";

interface CloudSectionProps {
  draft: AppSettings;
  update: (patch: Partial<AppSettings>) => void;
  edition: AppEdition;
}

export function CloudSection({ draft, update, edition }: CloudSectionProps) {
  const { t } = useI18n();
  return (
    <section className="settings-group settings-cloud">
      <div className="section-title">
        <span>{t("settings.cloud.title")}</span>
        <b>
          {t(
            edition === "server" ? "settings.cloud.serverNote" : "settings.cloud.publicNote",
          )}
        </b>
      </div>
      <div className="settings-cloud-fields">
        <label>
          <span>{t("settings.cloud.urls")}</span>
          <textarea
            className="note-input settings-textarea"
            rows={4}
            value={draft.cloud.baseUrls.join("\n")}
            placeholder="https://your-catalog.example"
            onChange={(event) =>
              update({
                cloud: {
                  ...draft.cloud,
                  baseUrls: event.target.value
                    .split("\n")
                    .map((line) => line.trim())
                    .filter(Boolean),
                },
              })
            }
          />
        </label>
        <label className="settings-segment-field">
          <span>{t("settings.cloud.segments")}</span>
          <input
            type="number"
            min={8}
            max={128}
            step={1}
            value={draft.cloud.maxDownloadSegments}
            onChange={(event) => {
              const value = Number(event.target.value);
              update({
                cloud: {
                  ...draft.cloud,
                  maxDownloadSegments: Number.isFinite(value) ? value : 8,
                },
              });
            }}
            onBlur={() =>
              update({
                cloud: {
                  ...draft.cloud,
                  maxDownloadSegments: clampCloudDownloadSegments(
                    draft.cloud.maxDownloadSegments,
                  ),
                },
              })
            }
          />
          <small>{t("settings.cloud.segmentsHelp")}</small>
        </label>
      </div>
      <div className="settings-note">
        {t(
          edition === "server" ? "settings.cloud.serverSecret" : "settings.cloud.publicSecret",
        )}
      </div>
    </section>
  );
}
