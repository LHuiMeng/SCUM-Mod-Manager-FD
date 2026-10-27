import type { AppUpdateInfo, AppUpdatePhase, AppUpdateProgress } from "../../types";
import { formatBytes, formatDate } from "../../lib/format";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";

interface UpdateDialogProps {
  info: AppUpdateInfo;
  phase: AppUpdatePhase;
  progress: AppUpdateProgress | null;
  error: string | null;
  onClose: () => void;
  onInstall: () => void;
}

export function UpdateDialog({
  info,
  phase,
  progress,
  error,
  onClose,
  onInstall,
}: UpdateDialogProps) {
  const busy = phase === "downloading" || phase === "verifying" || phase === "installing";
  const percent =
    progress?.total && progress.total > 0
      ? Math.min(100, Math.round((progress.downloaded / progress.total) * 100))
      : phase === "verifying" || phase === "installing"
        ? 100
        : null;

  return (
    <Modal
      wide
      title={`发现新版本 ${info.version ?? ""}`}
      description="安装包将先完成签名校验，再交给 Windows 安装器。"
      onClose={busy ? () => undefined : onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={busy}>
            稍后
          </Button>
          <Button
            variant="primary"
            icon="download"
            onClick={onInstall}
            disabled={busy}
          >
            {phase === "downloading"
              ? "正在下载"
              : phase === "verifying"
                ? "正在校验"
                : phase === "installing"
                  ? "正在安装"
                  : "下载并安装"}
          </Button>
        </>
      }
    >
      <div className="update-version-line">
        <span>{info.currentVersion}</span>
        <i />
        <b>{info.version}</b>
      </div>

      <div className="update-facts">
        <div>
          <span>文件大小</span>
          <b>{info.size ? formatBytes(info.size) : "下载时确认"}</b>
        </div>
        <div>
          <span>发布日期</span>
          <b>{formatDate(info.publishedAt)}</b>
        </div>
        <div>
          <span>安全校验</span>
          <b className="is-safe">
            <Icon name="lock" size={13} />
            Tauri 签名
          </b>
        </div>
      </div>

      <section className="update-notes">
        <span>本次更新</span>
        <p>{info.notes || "此版本包含稳定性与使用体验改进。"}</p>
      </section>

      {busy ? (
        <div className="update-progress-card">
          <div>
            <span>
              {phase === "downloading"
                ? "正在下载安装包"
                : phase === "verifying"
                  ? "正在验证发布签名"
                  : "安装器已启动"}
            </span>
            <b>{percent !== null ? `${percent}%` : "自动校验"}</b>
          </div>
          <i>
            <span style={{ width: percent !== null ? `${percent}%` : "42%" }} />
          </i>
          <small>
            {phase === "installing"
              ? "应用会退出，安装完成后自动重新打开。"
              : "请不要关闭窗口。下载与验签全部在 Rust 后端完成。"}
          </small>
        </div>
      ) : null}

      {error ? <div className="update-error">{error}</div> : null}

      <div className="update-safety-note">
        <Icon name="lock" size={15} />
        <span>
          只会安装版本号与签名同时匹配的安装包。任何下载中断、文件被替换或版本回退都会被拒绝。
        </span>
      </div>
    </Modal>
  );
}
