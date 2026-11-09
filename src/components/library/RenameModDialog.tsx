import { useEffect, useState } from "react";
import type { ModEntry } from "../../types";
import { useI18n } from "../../i18n";
import { Button } from "../ui/Button";
import { Modal } from "../ui/Modal";

interface RenameModDialogProps {
  mod: ModEntry;
  onRename: (newName: string) => Promise<string | null>;
  onClose: () => void;
}

function editableName(mod: ModEntry): string {
  if (mod.type === "clientPak" && /\.pak$/i.test(mod.fileName)) {
    return mod.fileName.slice(0, -4);
  }
  return mod.fileName;
}

export function RenameModDialog({ mod, onRename, onClose }: RenameModDialogProps) {
  const { t } = useI18n();
  const [name, setName] = useState(() => editableName(mod));
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    setName(editableName(mod));
    setError(null);
  }, [mod]);

  async function submit() {
    if (saving) return;
    const trimmed = name.trim();
    if (!trimmed) {
      setError(t("rename.empty"));
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const failure = await onRename(trimmed);
      if (failure) setError(failure);
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal
      title={t("rename.title")}
      description={t("rename.description", { name: mod.name })}
      onClose={() => {
        if (!saving) onClose();
      }}
      footer={
        <>
          <Button onClick={onClose} disabled={saving}>
            {t("common.cancel")}
          </Button>
          <Button variant="primary" onClick={() => void submit()} disabled={saving}>
            {saving ? t("rename.saving") : t("rename.confirm")}
          </Button>
        </>
      }
    >
      <label className="field-label" htmlFor="rename-mod-input">
        {t("rename.label")}
      </label>
      <input
        id="rename-mod-input"
        className="rename-input"
        value={name}
        maxLength={84}
        onChange={(event) => {
          setName(event.target.value);
          if (error) setError(null);
        }}
        onKeyDown={(event) => {
          if (event.nativeEvent.isComposing || event.keyCode === 229) return;
          if (event.key === "Enter") {
            event.preventDefault();
            void submit();
          }
        }}
      />
      <p className="rename-hint">
        {mod.type === "clientPak"
          ? t("rename.pakHint")
          : t("rename.folderHint")}
      </p>
      {error ? (
        <p className="rename-error" role="alert">
          {error}
        </p>
      ) : null}
    </Modal>
  );
}
