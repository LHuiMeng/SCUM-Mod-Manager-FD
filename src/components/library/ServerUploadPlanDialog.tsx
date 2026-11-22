import type { ServerLibraryState } from "../../lib/serverLibrary";
import type { ModEntry, SftpPrepareResult } from "../../types";
import { useI18n } from "../../i18n";
import { Button } from "../ui/Button";
import { Modal } from "../ui/Modal";

interface ServerUploadPlanDialogProps {
  prepare: SftpPrepareResult;
  state: ServerLibraryState;
  mods: ModEntry[];
  busy: boolean;
  onConfirm: () => void;
  onClose: () => void;
}

/**
 * 上传前的变更清单：把「融合 / 禁用 / 删除 / 重排」逐项摊开，
 * 并解释禁用与删除为什么会在服务器上变成 *.pak.bak。
 */
export function ServerUploadPlanDialog({
  prepare,
  state,
  mods,
  busy,
  onConfirm,
  onClose,
}: ServerUploadPlanDialogProps) {
  const { t } = useI18n();
  const nameOf = (path: string) => mods.find((mod) => mod.id === path)?.name ?? path;
  const disabled = Object.entries(state.enabled)
    .filter(([, on]) => !on)
    .map(([path]) => path);

  const rows: Array<{ key: string; title: string; items: string[] }> = [];
  if (prepare.mergedSources.length > 0) {
    rows.push({
      key: "merged",
      title: t("serverLibrary.plan.merged"),
      items: prepare.mergedSources.map((item) => item.name),
    });
  }
  if (disabled.length > 0) {
    rows.push({
      key: "disabled",
      title: t("serverLibrary.plan.disabled"),
      items: disabled.map(nameOf),
    });
  }
  if (state.deleted.length > 0) {
    rows.push({
      key: "deleted",
      title: t("serverLibrary.plan.deleted"),
      items: state.deleted.map(nameOf),
    });
  }
  if (prepare.renameCount > 0) {
    rows.push({
      key: "renamed",
      title: t("serverLibrary.plan.renamed"),
      items: [t("serverLibrary.plan.renameCount", { count: prepare.renameCount })],
    });
  }

  return (
    <Modal
      title={t("serverLibrary.plan.title")}
      description={prepare.message}
      onClose={onClose}
      wide
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          <Button variant="primary" icon="upload" onClick={onConfirm} disabled={busy}>
            {busy ? t("serverLibrary.uploading") : t("serverLibrary.plan.confirm")}
          </Button>
        </>
      }
    >
      {rows.length === 0 ? (
        <p>{t("serverLibrary.plan.none")}</p>
      ) : (
        <div className="server-plan">
          {rows.map((row) => (
            <section key={row.key}>
              <div className="section-title">
                <span>{row.title}</span>
                <b>{row.items.length}</b>
              </div>
              <ul>
                {row.items.map((item) => (
                  <li key={item}>{item}</li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      )}
      <p className="server-plan-note">
        {t("serverLibrary.plan.backupNote", { dir: "_SCUM_Mod_Desk_Backups" })}
      </p>
    </Modal>
  );
}
