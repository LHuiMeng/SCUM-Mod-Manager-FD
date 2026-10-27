import type { ButtonHTMLAttributes, ReactNode } from "react";
import { Icon, type IconName } from "./Icon";

type ButtonVariant = "primary" | "outline" | "ghost" | "danger";
type ButtonSize = "sm" | "md" | "lg" | "icon";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  icon?: IconName;
  trailingIcon?: IconName;
  children?: ReactNode;
}

export function Button({
  variant = "outline",
  size = "md",
  icon,
  trailingIcon,
  className,
  children,
  type = "button",
  ...props
}: ButtonProps) {
  return (
    <button
      type={type}
      className={["button", `button-${variant}`, `button-${size}`, className]
        .filter(Boolean)
        .join(" ")}
      {...props}
    >
      {icon ? <Icon name={icon} size={size === "sm" ? 13 : 15} /> : null}
      {children ? <span>{children}</span> : null}
      {trailingIcon ? <Icon name={trailingIcon} size={size === "sm" ? 13 : 15} /> : null}
    </button>
  );
}
