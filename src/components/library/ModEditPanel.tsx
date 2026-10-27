import { useEffect, useState } from "react";
import type { ModEntry } from "../../types";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";

interface ModEditPanelProps {
  mod: ModEntry;
  onSave: (tags: string[], notes: string) => void;
  onClose: () => void;
}

export function ModEditPanel({ mod, onSave, onClose }: ModEditPanelProps) {
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
      title="编辑标签与备注"
      description={`${mod.name} · 这些信息只保存在当前设备`}
      onClose={onClose}
      footer={
        <>
          <Button onClick={onClose}>取消</Button>
          <Button
            variant="primary"
            onClick={() => {
              onSave(tags, notes.trim());
              onClose();
            }}
          >
            保存修改
          </Button>
        </>
      }
    >
      <label className="field-label" htmlFor="tag-input">
        标签
      </label>
      <div className="tag-editor">
        {tags.map((tag) => (
          <button
            type="button"
            className="tag-editor-chip"
            key={tag}
            onClick={() => setTags(tags.filter((item) => item !== tag))}
            title="点击移除"
          >
            {tag}
            <Icon name="close" size={10} />
          </button>
        ))}
        <input
          id="tag-input"
          value={tagDraft}
          placeholder="输入后回车添加"
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
        本地备注
      </label>
      <textarea
        id="notes-input"
        className="note-input"
        value={notes}
        rows={7}
        placeholder="记录兼容性、服务器用途或测试结果..."
        onChange={(event) => setNotes(event.target.value)}
      />
    </Modal>
  );
}
