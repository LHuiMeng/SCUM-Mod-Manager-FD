import { Icon } from "./Icon";

interface SearchFieldProps {
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
  className?: string;
}

export function SearchField({ value, onChange, placeholder, className }: SearchFieldProps) {
  return (
    <label className={["search-field", className].filter(Boolean).join(" ")}>
      <Icon name="search" size={15} />
      <input
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        aria-label={placeholder}
      />
      {value ? (
        <button type="button" aria-label="清空搜索" onClick={() => onChange("")}>
          <Icon name="close" size={12} />
        </button>
      ) : null}
    </label>
  );
}
