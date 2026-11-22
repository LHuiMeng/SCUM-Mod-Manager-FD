import {
  createContext,
  useContext,
  useMemo,
  type ReactNode,
} from "react";
import zhCN from "./locales/zh-CN.json";
import enUS from "./locales/en-US.json";

export type Language = "zh-CN" | "en-US";
export type TranslationVariables = Record<string, string | number | boolean>;
export type TranslationKey = keyof typeof zhCN;
export type Translator = (
  key: TranslationKey,
  variables?: TranslationVariables,
) => string;

export const LANGUAGE_STORAGE_KEY = "scum-language";
export const SUPPORTED_LANGUAGES: Array<{
  id: Language;
  label: string;
  shortLabel: string;
}> = [
  { id: "zh-CN", label: "简体中文", shortLabel: "中文" },
  { id: "en-US", label: "English", shortLabel: "EN" },
];

const builtIn: Record<Language, Record<string, string>> = {
  "zh-CN": zhCN,
  "en-US": enUS,
};

export function normalizeLanguage(value: unknown): Language {
  return value === "en-US" ? "en-US" : "zh-CN";
}

export function readStoredLanguage(): Language | null {
  if (typeof localStorage === "undefined") return null;
  const value = localStorage.getItem(LANGUAGE_STORAGE_KEY);
  return value === "zh-CN" || value === "en-US" ? value : null;
}

export function storeLanguage(language: Language) {
  localStorage.setItem(LANGUAGE_STORAGE_KEY, language);
}

export function interpolate(
  template: string,
  variables?: TranslationVariables,
): string {
  if (!variables) return template;
  return template.replace(/\{(\w+)\}/g, (match, name: string) => {
    const value = variables[name];
    return value === undefined || value === null ? match : String(value);
  });
}

export function translate(
  language: Language,
  overrides: Record<string, string> | null | undefined,
  key: TranslationKey,
  variables?: TranslationVariables,
): string {
  const singularKey = variables?.count === 1 ? `${key}.one` : null;
  const override =
    (singularKey ? overrides?.[singularKey] : undefined) ??
    overrides?.[key];
  const localized =
    (singularKey ? builtIn[language][singularKey] : undefined) ??
    builtIn[language][key];
  const fallback = builtIn["zh-CN"][key];
  return interpolate(
    typeof override === "string" && override.trim() ? override : localized || fallback || key,
    variables,
  );
}

interface I18nContextValue {
  language: Language;
  t: Translator;
  setLanguage: (language: Language) => void;
}

const I18nContext = createContext<I18nContextValue | null>(null);

interface I18nProviderProps {
  language: Language;
  overrides: Record<string, string>;
  onLanguageChange: (language: Language) => void;
  children: ReactNode;
}

export function I18nProvider({
  language,
  overrides,
  onLanguageChange,
  children,
}: I18nProviderProps) {
  const value = useMemo<I18nContextValue>(
    () => ({
      language,
      t: (key, variables) => translate(language, overrides, key, variables),
      setLanguage: onLanguageChange,
    }),
    [language, onLanguageChange, overrides],
  );
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nContextValue {
  const value = useContext(I18nContext);
  if (!value) {
    throw new Error("useI18n must be used inside I18nProvider");
  }
  return value;
}

export function localeTag(language: Language): string {
  return language;
}
