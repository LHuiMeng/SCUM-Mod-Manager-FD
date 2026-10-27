import type { NavSection } from "../../types";
import { Icon, type IconName } from "../ui/Icon";

const items: Array<{ id: NavSection; label: string; icon: IconName }> = [
  { id: "library", label: "模组库", icon: "box" },
  { id: "cloud", label: "云端", icon: "cloud" },
  { id: "server", label: "服务器", icon: "server" },
  { id: "logs", label: "日志", icon: "log" },
];

interface SidebarProps {
  active: NavSection;
  onChange: (section: NavSection) => void;
  onSettings: () => void;
}

export function Sidebar({ active, onChange, onSettings }: SidebarProps) {
  return (
    <aside className="sidebar" aria-label="主导航">
      <div className="rail-logo" aria-label="SCUM Mod Manager">
        SM
      </div>
      <nav className="rail-nav">
        {items.map((item) => (
          <button
            type="button"
            key={item.id}
            className={`rail-button ${active === item.id ? "is-active" : ""}`}
            aria-label={item.label}
            aria-current={active === item.id ? "page" : undefined}
            title={item.label}
            onClick={() => onChange(item.id)}
          >
            <Icon name={item.icon} size={20} />
          </button>
        ))}
      </nav>
      <div className="rail-bottom">
        <button
          type="button"
          className={`rail-button ${active === "settings" ? "is-active" : ""}`}
          aria-label="设置"
          title="设置"
          onClick={onSettings}
        >
          <Icon name="settings" size={20} />
        </button>
        <span className="user-mark" aria-hidden="true">
          RD
        </span>
      </div>
    </aside>
  );
}
