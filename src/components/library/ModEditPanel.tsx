import { useEffect, useState } from "react";
import type { ModEntry } from "../../types";
import { useI18n } from "../../i18n";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";

interface ModEditPanelProps {
  mod: ModEntry;
  onSave: (tags: string[], notes: string) => void;
  onClose: () => void;
}

export function ModEditPanel({ mod, onSave, onClose }: ModEditPanelProps) {
  const { t } = useI18n();
  const [tags, setTags] = useState(mod.tags);
  const [tagDraft, setTagDraft] = useState("");
  const [notes, setNotes] = useState(mod.notes);

  useEffect(() => {
    setTags(mod.tags);
    setNotes(mod.notes);
  }, [mod]);

  function addTag() {
    const next = tagDraft.trim();
    if (!next || tags.includes(next)) return;
    setTags([...tags, next]);
    setTagDraft("");
  }

  return (
    <Modal
      title={t("edit.title")}
      description={t("edit.description", { name: mod.name })}
      onClose={onClose}
      footer={
        <>
          <Button onClick={onClose}>{t("common.cancel")}</Button>
          <Button
            variant="primary"
            onClick={() => {
              onSave(tags, notes.trim());
              onClose();
            }}
          >
            {t("common.save")}
          </Button>
        </>
      }
    >
      <label className="field-label" htmlFor="tag-input">
        {t("edit.tags")}
      </label>
      <div className="tag-editor">
        {tags.map((tag) => (
          <button
            type="button"
            className="tag-editor-chip"
            key={tag}
            onClick={() => setTags(tags.filter((item) => item !== tag))}
            title={t("edit.removeTag")}
          >
            {tag}
            <Icon name="close" size={10} />
          </button>
        ))}
        <input
          id="tag-input"
          value={tagDraft}
          placeholder={t("edit.tagPlaceholder")}
          onChange={(event) => setTagDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              addTag();
            }
          }}
        />
      </div>
      <label className="field-label" htmlFor="notes-input">
        {t("edit.notes")}
      </label>
      <textarea
        id="notes-input"
        className="note-input"
        value={notes}
        rows={7}
        placeholder={t("edit.notesPlaceholder")}
        onChange={(event) => setNotes(event.target.value)}
      />
    </Modal>
  );
}
