import type { NavSection } from "../../types";
import { useI18n } from "../../i18n";
import { Icon, type IconName } from "../ui/Icon";

const items: Array<{ id: NavSection; labelKey: "nav.library" | "nav.cloud" | "nav.server" | "nav.logs"; icon: IconName }> = [
  { id: "library", labelKey: "nav.library", icon: "box" },
  { id: "cloud", labelKey: "nav.cloud", icon: "cloud" },
  { id: "server", labelKey: "nav.server", icon: "server" },
  { id: "logs", labelKey: "nav.logs", icon: "log" },
];

interface SidebarProps {
  active: NavSection;
  onChange: (section: NavSection) => void;
  onSettings: () => void;
}

export function Sidebar({ active, onChange, onSettings }: SidebarProps) {
  const { t } = useI18n();
  return (
    <aside className="sidebar" aria-label={t("nav.ariaLabel")}>
      <div className="rail-logo" aria-label="SCUM Mod Desk">
        SM
      </div>
      <nav className="rail-nav">
        {items.map((item) => (
          <button
            type="button"
            key={item.id}
            className={`rail-button ${active === item.id ? "is-active" : ""}`}
            aria-current={active === item.id ? "page" : undefined}
            title={t(item.labelKey)}
            onClick={() => onChange(item.id)}
          >
            <Icon name={item.icon} size={19} />
            <span>{t(item.labelKey)}</span>
          </button>
        ))}
      </nav>
      <div className="rail-bottom">
        <button
          type="button"
          className={`rail-button ${active === "settings" ? "is-active" : ""}`}
          aria-current={active === "settings" ? "page" : undefined}
          title={t("nav.settings")}
          onClick={onSettings}
        >
          <Icon name="settings" size={19} />
          <span>{t("nav.settings")}</span>
        </button>
      </div>
    </aside>
  );
}
