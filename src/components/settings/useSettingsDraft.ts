import { useEffect, useState } from "react";
import type { AppSettings, Language, ThemeMode } from "../../types";

/**
 * 设置页草稿状态：路径/云源这类字段只在「保存」时落盘，
 * 所以外部刷新只能同步即时生效的字段（主题、启动参数），
 * 不能覆盖用户正在编辑的草稿。这段逻辑必须原样保留。
 */
export function useSettingsDraft(
  settings: AppSettings,
  theme: ThemeMode,
  language: Language,
) {
  const [draft, setDraft] = useState(settings);
  const [hint, setHint] = useState<string | null>(null);

  useEffect(() => {
    setDraft((current) => ({
      ...current,
      theme: settings.theme,
      launchOptions: settings.launchOptions,
    }));
  }, [settings.launchOptions, settings.theme]);

  useEffect(() => {
    setDraft((current) => (current.theme === theme ? current : { ...current, theme }));
  }, [theme]);

  useEffect(() => {
    setDraft((current) =>
      current.language === language ? current : { ...current, language },
    );
  }, [language]);

  function update(patch: Partial<AppSettings>) {
    setDraft((current) => ({ ...current, ...patch }));
  }

  return { draft, update, hint, setHint };
}
