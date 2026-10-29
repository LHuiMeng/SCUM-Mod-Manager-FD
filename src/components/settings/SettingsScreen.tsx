import { useEffect, useState } from "react";
import type {
  AppEdition,
  AppSettings,
  AppUpdateInfo,
  AppUpdatePhase,
  AppUpdateProgress,
  Language,
  ThemeMode,
} from "../../types";
import { SUPPORTED_LANGUAGES, useI18n } from "../../i18n";
import { clampCloudDownloadSegments } from "../../lib/cloudDownload";
import { Button } from "../ui/Button";
import { Toggle } from "../ui/Toggle";
import { UpdateSettings } from "./UpdateSettings";

interface SettingsScreenProps {
  settings: AppSettings;
  theme: ThemeMode;
  language: Language;
  edition: AppEdition;
  onSave: (settings: AppSettings) => void;
  onDetectPaths: () => Promise<{
    scumInstallPath: string;
    serverInstallPath: string;
  } | null>;
  onLaunchOptionsChange: (options: AppSettings["launchOptions"]) => void;
  onThemePreview: (theme: ThemeMode) => void;
  onLanguagePreview: (language: Language) => void;
  onChooseDirectory: (kind: "client" | "server") => Promise<string | null>;
  updateInfo: AppUpdateInfo | null;
  updatePhase: AppUpdatePhase;
  updateProgress: AppUpdateProgress | null;
  updateError: string | null;
  onCheckUpdate: () => void;
  onShowUpdate: () => void;
}

export function SettingsScreen({
  settings,
  theme,
  language,
  edition,
  onSave,
  onDetectPaths,
  onLaunchOptionsChange,
  onThemePreview,
  onLanguagePreview,
  onChooseDirectory,
  updateInfo,
  updatePhase,
  updateProgress,
  updateError,
  onCheckUpdate,
  onShowUpdate,
}: SettingsScreenProps) {
  const { t } = useI18n();
  const [draft, setDraft] = useState(settings);
  const [hint, setHint] = useState<string | null>(null);

  // 只跟随即时生效的字段（主题、启动参数），路径与云源的未保存草稿不能被外部刷新冲掉。
  useEffect(() => {
    setDraft((current) => ({
      ...current,
      theme: settings.theme,
      launchOptions: settings.launchOptions,
    }));
  }, [settings.launchOptions, settings.theme]);

  useEffect(() => {
    setDraft((current) =>
      current.theme === theme ? current : { ...current, theme },
    );
  }, [theme]);

  useEffect(() => {
    setDraft((current) =>
      current.language === language ? current : { ...current, language },
    );
  }, [language]);

  function update(patch: Partial<AppSettings>) {
    setDraft((current) => ({ ...current, ...patch }));
  }

  function updateLaunchOptions(patch: Partial<AppSettings["launchOptions"]>) {
    const next = { ...draft.launchOptions, ...patch };
    update({ launchOptions: next });
    onLaunchOptionsChange(next);
  }

  async function handleDetect() {
    const paths = await onDetectPaths();
    if (!paths) return;
    update(paths);
    const found = Boolean(paths.scumInstallPath.trim() || paths.serverInstallPath.trim());
    setHint(
      found
        ? t("settings.hint.detected")
        : t("settings.hint.notFound"),
    );
    window.setTimeout(() => setHint(null), 6000);
  }

  return (
    <section className="page page-settings">
      <header className="page-header">
        <div>
          <h1>{t("settings.title")}</h1>
          <p>{t("settings.subtitle")}</p>
        </div>
        <div className="heading-tools">
          <Button icon="search" onClick={() => void handleDetect()}>
            {t("settings.autoDetect")}
          </Button>
          <Button
            variant="primary"
            onClick={() =>
              onSave({
                ...draft,
                cloud: {
                  ...draft.cloud,
                  maxDownloadSegments: clampCloudDownloadSegments(
                    draft.cloud.maxDownloadSegments,
                  ),
                },
              })
            }
          >
            {t("settings.save")}
          </Button>
        </div>
      </header>

      {hint ? (
        <p className="settings-hint" role="status">
          {hint}
        </p>
      ) : null}

      <div className="settings-sheet">
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
                onBlur={() => updateLaunchOptions({ port: draft.launchOptions.port })}
              />
            </label>
          </div>
        </section>

        <section className="settings-group">
          <div className="section-title">
            <span>{t("settings.appearance.title")}</span>
            <b>{t("settings.appearance.note")}</b>
          </div>
          <div className="theme-options">
            <button
              type="button"
              className={draft.theme === "light" ? "is-active" : ""}
              onClick={() => {
                update({ theme: "light" });
                onThemePreview("light");
              }}
            >
              <span className="theme-swatch theme-light">
                <i />
                <i />
              </span>
              <b>{t("settings.appearance.light")}</b>
              <small>{t("settings.appearance.lightDetail")}</small>
            </button>
            <button
              type="button"
              className={draft.theme === "dark" ? "is-active" : ""}
              onClick={() => {
                update({ theme: "dark" });
                onThemePreview("dark");
              }}
            >
              <span className="theme-swatch theme-dark">
                <i />
                <i />
              </span>
              <b>{t("settings.appearance.dark")}</b>
              <small>{t("settings.appearance.darkDetail")}</small>
            </button>
          </div>
        </section>

        <section className="settings-group settings-cloud">
          <div className="section-title">
            <span>{t("settings.cloud.title")}</span>
            <b>
              {t(
                edition === "server"
                  ? "settings.cloud.serverNote"
                  : "settings.cloud.publicNote",
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
              edition === "server"
                ? "settings.cloud.serverSecret"
                : "settings.cloud.publicSecret",
            )}
          </div>
        </section>

        <section
          className="settings-group settings-language"
          aria-label={t("settings.language.switch")}
        >
          <div className="section-title">
            <span>{t("settings.language.title")}</span>
            <b>{t("settings.language.note")}</b>
          </div>
          <div className="language-options">
            {SUPPORTED_LANGUAGES.map((language) => (
              <button
                type="button"
                key={language.id}
                className={draft.language === language.id ? "is-active" : ""}
                onClick={() => {
                  update({ language: language.id });
                  onLanguagePreview(language.id);
                }}
              >
                <b>{language.label}</b>
                <small>{language.id}</small>
              </button>
            ))}
          </div>
          <p className="settings-note">{t("settings.language.overrideNote")}</p>
        </section>
      </div>
    </section>
  );
}
