import { useEffect, useMemo, useRef, useState } from "react";
import type { ModConfigFile } from "../../types";
import { useI18n } from "../../i18n";
import { formatBytes } from "../../lib/format";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";

interface ConfigEditorDialogProps {
  modName: string;
  files: ModConfigFile[];
  load: (relativePath: string) => Promise<string>;
  save: (relativePath: string, content: string) => Promise<boolean>;
  onClose: () => void;
}

/**
 * 模组配置文件编辑器：左侧文件树、右侧纯文本编辑，Ctrl/⌘+S 保存。
 * 只读写白名单文本类型，保存前由后端自动备份。
 */
export function ConfigEditorDialog({
  modName,
  files,
  load,
  save,
  onClose,
}: ConfigEditorDialogProps) {
  const { t } = useI18n();
  const ordered = useMemo(
    () =>
      [...files].sort(
        (left, right) =>
          Number(right.editable) - Number(left.editable) ||
          left.relativePath.localeCompare(right.relativePath),
      ),
    [files],
  );
  const [activePath, setActivePath] = useState<string | null>(
    ordered[0]?.relativePath ?? null,
  );
  const [content, setContent] = useState("");
  const [original, setOriginal] = useState("");
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const active = ordered.find((file) => file.relativePath === activePath) ?? null;
  const dirty = content !== original;
  // 父组件每次渲染都会传新函数；用 ref 固定住，避免 useEffect 反复拉取。
  const loadRef = useRef(load);
  loadRef.current = load;

  useEffect(() => {
    if (!activePath) return;
    let cancelled = false;
    setLoading(true);
    void loadRef
      .current(activePath)
      .then((body) => {
        if (cancelled) return;
        setContent(body);
        setOriginal(body);
      })
      .catch(() => {
        if (!cancelled) {
          setContent("");
          setOriginal("");
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [activePath]);

  async function submit() {
    if (!active || !dirty || saving || !active.editable) return;
    setSaving(true);
    try {
      if (await save(active.relativePath, content)) setOriginal(content);
    } finally {
      setSaving(false);
    }
  }

  const lines = content ? content.split("\n").length : 0;

  return (
    <Modal
      title={t("config.title")}
      description={modName}
      onClose={() => {
        if (!dirty || window.confirm(t("config.unsavedConfirm"))) onClose();
      }}
      wide
      footer={
        <>
          <span className="config-editor-hint">{t("config.editorHint")}</span>
          <Button variant="ghost" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button
            variant="primary"
            icon="check"
            onClick={() => void submit()}
            disabled={!dirty || saving || !active?.editable}
          >
            {saving ? t("config.saving") : t("config.save")}
          </Button>
        </>
      }
    >
      <div className="config-editor">
        <div className="config-editor-list">
          {ordered.length === 0 ? <p>{t("config.empty")}</p> : null}
          {ordered.map((file) => (
            <button
              key={file.relativePath}
              type="button"
              className={file.relativePath === activePath ? "is-active" : ""}
              onClick={() => setActivePath(file.relativePath)}
            >
              <Icon name={file.managedByApp ? "lock" : "box"} size={14} />
              <span>{file.relativePath}</span>
              <small>{formatBytes(file.size)}</small>
            </button>
          ))}
        </div>
        <div className="config-editor-body">
          {active && !active.editable ? (
            <p className="config-editor-locked">
              <Icon name="lock" size={13} /> {t("config.managed")}
            </p>
          ) : null}
          <textarea
            value={content}
            readOnly={loading || !active?.editable}
            spellCheck={false}
            onChange={(event) => setContent(event.target.value)}
            onKeyDown={(event) => {
              if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s") {
                event.preventDefault();
                void submit();
              }
            }}
          />
          <div className="config-editor-meta">
            <span>{t("config.lineCount", { lines, chars: content.length })}</span>
            {dirty ? <b>{t("config.unsaved")}</b> : null}
          </div>
        </div>
      </div>
    </Modal>
  );
}
