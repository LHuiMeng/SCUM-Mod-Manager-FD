import type { ToastMessage } from "../../types";
import { useI18n } from "../../i18n";

interface ToastStackProps {
  messages: ToastMessage[];
  onDismiss: (id: number) => void;
}

export function ToastStack({ messages, onDismiss }: ToastStackProps) {
  const { t } = useI18n();
  return (
    <div className="toast-stack" aria-live="polite">
      {messages.map((message) => (
        <button
          type="button"
          className={`toast toast-${message.tone}`}
          key={message.id}
          title={t("common.clickToClose")}
          onClick={() => onDismiss(message.id)}
        >
          <span className="toast-mark" />
          <span className="toast-copy">
            <b>{message.title}</b>
            {message.detail ? <span>{message.detail}</span> : null}
          </span>
        </button>
      ))}
    </div>
  );
}
