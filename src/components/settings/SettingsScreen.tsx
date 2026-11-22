import { useState } from "react";
import type {
  AppEdition,
  AppSettings,
  AppUpdateInfo,
  AppUpdatePhase,
  AppUpdateProgress,
  Language,
  ThemeMode,
} from "../../types";
import type { TranslationKey } from "../../i18n";
import { useI18n } from "../../i18n";
import { clampCloudDownloadSegments } from "../../lib/cloudDownload";
import { normalizePort } from "../../lib/serverPort";
import { Button } from "../ui/Button";
import { AboutSection } from "./sections/AboutSection";
import { AppearanceSection } from "./sections/AppearanceSection";
import { CloudSection } from "./sections/CloudSection";
import { PathsSection } from "./sections/PathsSection";
import { StartupSection } from "./sections/StartupSection";
import { useSettingsDraft } from "./useSettingsDraft";

interface SettingsScreenProps {
  settings: AppSettings;
  theme: ThemeMode;
  language: Language;
  edition: AppEdition;
  version?: string | null;
  dataRoot?: string | null;
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

const SECTIONS: Array<{
  id: string;
  labelKey: TranslationKey;
  hintKey: TranslationKey;
}> = [
  { id: "paths", labelKey: "settings.nav.paths", hintKey: "settings.nav.pathsHint" },
  { id: "startup", labelKey: "settings.nav.startup", hintKey: "settings.nav.startupHint" },
  { id: "cloud", labelKey: "settings.nav.cloud", hintKey: "settings.nav.cloudHint" },
  {
    id: "appearance",
    labelKey: "settings.nav.appearance",
    hintKey: "settings.nav.appearanceHint",
  },
  { id: "about", labelKey: "settings.nav.about", hintKey: "settings.nav.aboutHint" },
];

/**
 * 设置页：左侧分类导航 + 右侧单页内容。所有分类共用一个 draft，
 * 保存仍然只有 header 里的一个按钮，避免「改一半生效一半」。
 */
export function SettingsScreen({
  settings,
  theme,
  language,
  edition,
  version = null,
  dataRoot = null,
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
  const { draft, update, hint, setHint } = useSettingsDraft(settings, theme, language);
  const [active, setActive] = useState<string>("paths");
  const dirty = JSON.stringify(draft) !== JSON.stringify(settings);

  async function handleDetect() {
    const paths = await onDetectPaths();
    if (!paths) return;
    update(paths);
    const found = Boolean(paths.scumInstallPath.trim() || paths.serverInstallPath.trim());
    setHint(found ? t("settings.hint.detected") : t("settings.hint.notFound"));
    window.setTimeout(() => setHint(null), 6000);
  }

  function handleSave() {
    onSave({
      ...draft,
      launchOptions: {
        ...draft.launchOptions,
        port: normalizePort(draft.launchOptions.port),
      },
      cloud: {
        ...draft.cloud,
        maxDownloadSegments: clampCloudDownloadSegments(draft.cloud.maxDownloadSegments),
      },
    });
  }

  return (
    <section className="page page-settings">
      <header className="page-header">
        <div>
          <h1>{t("settings.title")}</h1>
          <p>{t("settings.subtitle")}</p>
        </div>
        <div className="heading-tools">
          {dirty ? <span className="settings-dirty">{t("settings.unsaved")}</span> : null}
          <Button icon="search" onClick={() => void handleDetect()}>
            {t("settings.autoDetect")}
          </Button>
          <Button variant="primary" onClick={handleSave}>
            {t("settings.save")}
          </Button>
        </div>
      </header>

      {hint ? (
        <p className="settings-hint" role="status">
          {hint}
        </p>
      ) : null}

      <div className="settings-layout">
        <nav className="settings-nav" role="tablist" aria-label={t("settings.title")}>
          {SECTIONS.map((section) => (
            <button
              key={section.id}
              type="button"
              role="tab"
              aria-selected={active === section.id}
              className={active === section.id ? "is-active" : ""}
              onClick={() => setActive(section.id)}
            >
              <b>{t(section.labelKey)}</b>
              <small>{t(section.hintKey)}</small>
            </button>
          ))}
        </nav>
        <div className="settings-body" role="tabpanel">
          {active === "paths" ? (
            <PathsSection
              draft={draft}
              update={update}
              onChooseDirectory={onChooseDirectory}
            />
          ) : null}
          {active === "startup" ? (
            <StartupSection
              draft={draft}
              update={update}
              onLaunchOptionsChange={onLaunchOptionsChange}
            />
          ) : null}
          {active === "cloud" ? (
            <CloudSection draft={draft} update={update} edition={edition} />
          ) : null}
          {active === "appearance" ? (
            <AppearanceSection
              draft={draft}
              update={update}
              onThemePreview={onThemePreview}
              onLanguagePreview={onLanguagePreview}
            />
          ) : null}
          {active === "about" ? (
            <AboutSection
              version={version}
              dataRoot={dataRoot}
              updateInfo={updateInfo}
              updatePhase={updatePhase}
              updateProgress={updateProgress}
              updateError={updateError}
              onCheckUpdate={onCheckUpdate}
              onShowUpdate={onShowUpdate}
            />
          ) : null}
        </div>
      </div>
    </section>
  );
}
