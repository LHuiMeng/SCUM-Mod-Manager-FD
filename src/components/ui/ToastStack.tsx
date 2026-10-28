import type { ToastMessage } from "../../types";

interface ToastStackProps {
  messages: ToastMessage[];
  onDismiss: (id: number) => void;
}

export function ToastStack({ messages, onDismiss }: ToastStackProps) {
  return (
    <div className="toast-stack" aria-live="polite">
      {messages.map((message) => (
        <button
          type="button"
          className={`toast toast-${message.tone}`}
          key={message.id}
          title="点击关闭"
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
