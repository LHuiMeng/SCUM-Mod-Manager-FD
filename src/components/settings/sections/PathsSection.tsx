import type { AppSettings } from "../../../types";
import { useI18n } from "../../../i18n";
import { Button } from "../../ui/Button";

interface PathsSectionProps {
  draft: AppSettings;
  update: (patch: Partial<AppSettings>) => void;
  onChooseDirectory: (kind: "client" | "server") => Promise<string | null>;
}

export function PathsSection({ draft, update, onChooseDirectory }: PathsSectionProps) {
  const { t } = useI18n();
  return (
    <section className="settings-group">
      <div className="section-title">
        <span>{t("settings.paths.title")}</span>
        <b>{t("settings.paths.note")}</b>
      </div>
      <div className="form-grid">
        <label className="form-span-2">
          <span>{t("settings.paths.client")}</span>
          <div className="input-with-button">
            <input
              value={draft.scumInstallPath}
              onChange={(event) => update({ scumInstallPath: event.target.value })}
              placeholder="X:/SteamLibrary/steamapps/common/SCUM"
            />
            <Button
              size="sm"
              icon="folder"
              onClick={async () => {
                const path = await onChooseDirectory("client");
                if (path) update({ scumInstallPath: path });
              }}
            >
              {t("settings.paths.select")}
            </Button>
          </div>
        </label>
        <label className="form-span-2">
          <span>{t("settings.paths.server")}</span>
          <div className="input-with-button">
            <input
              value={draft.serverInstallPath}
              onChange={(event) => update({ serverInstallPath: event.target.value })}
              placeholder="X:/SteamLibrary/steamapps/common/SCUM Server"
            />
            <Button
              size="sm"
              icon="folder"
              onClick={async () => {
                const path = await onChooseDirectory("server");
                if (path) update({ serverInstallPath: path });
              }}
            >
              {t("settings.paths.select")}
            </Button>
          </div>
        </label>
      </div>
    </section>
  );
}
