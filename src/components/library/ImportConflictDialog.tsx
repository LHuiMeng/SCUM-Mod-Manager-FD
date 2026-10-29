import type { ImportConflict } from "../../types";
import { useI18n } from "../../i18n";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";

interface ImportConflictDialogProps {
  conflicts: ImportConflict[];
  busy: boolean;
  onClose: () => void;
  onConfirm: () => void;
}

export function ImportConflictDialog({
  conflicts,
  busy,
  onClose,
  onConfirm,
}: ImportConflictDialogProps) {
  const { t } = useI18n();

  return (
    <Modal
      title={t("importConflict.title")}
      description={t("importConflict.description", { count: conflicts.length })}
      onClose={() => {
        if (!busy) onClose();
      }}
      footer={
        <>
          <Button disabled={busy} onClick={onClose}>
            {t("importConflict.keep")}
          </Button>
          <Button variant="primary" disabled={busy} onClick={onConfirm}>
            {busy ? t("common.working") : t("importConflict.replace")}
          </Button>
        </>
      }
    >
      <div className="import-conflict-list" role="list">
        {conflicts.map((conflict) => (
          <div
            className="import-conflict-row"
            role="listitem"
            key={`${conflict.sourcePath}:${conflict.targetPath}`}
          >
            <span className="import-conflict-icon" aria-hidden="true">
              <Icon name="serverOff" size={15} />
            </span>
            <span className="import-conflict-copy">
              <b>{conflict.fileName}</b>
              <small>{conflict.sourcePath}</small>
            </span>
            <span className="import-conflict-action">
              {t("importConflict.overwriteBadge")}
            </span>
          </div>
        ))}
      </div>
      <p className="import-conflict-note">{t("importConflict.backupNote")}</p>
    </Modal>
  );
}
