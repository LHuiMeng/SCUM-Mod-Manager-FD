import type { AppSettings, Language, ThemeMode } from "../../../types";
import { SUPPORTED_LANGUAGES, useI18n } from "../../../i18n";

interface AppearanceSectionProps {
  draft: AppSettings;
  update: (patch: Partial<AppSettings>) => void;
  onThemePreview: (theme: ThemeMode) => void;
  onLanguagePreview: (language: Language) => void;
}

export function AppearanceSection({
  draft,
  update,
  onThemePreview,
  onLanguagePreview,
}: AppearanceSectionProps) {
  const { t } = useI18n();
  return (
    <>
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
    </>
  );
}
