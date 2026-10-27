import type { AppUpdateInfo, AppUpdatePhase, AppUpdateProgress } from "../../types";
import { formatBytes, formatDate } from "../../lib/format";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";

interface UpdateSettingsProps {
  info: AppUpdateInfo | null;
  phase: AppUpdatePhase;
  progress: AppUpdateProgress | null;
  error: string | null;
  onCheck: () => void;
  onShowDetails: () => void;
}

export function UpdateSettings({
  info,
  phase,
  progress,
  error,
  onCheck,
  onShowDetails,
}: UpdateSettingsProps) {
  const checking = phase === "checking";
  const busy = checking || phase === "downloading" || phase === "verifying" || phase === "installing";
  const percent =
    progress?.total && progress.total > 0
      ? Math.min(100, Math.round((progress.downloaded / progress.total) * 100))
      : null;

  return (
    <section className="settings-group">
      <div className="section-title">
        <span>软件更新</span>
        <b>稳定通道 · 安装包签名校验</b>
      </div>
      <div className="update-overview">
        <span className={`update-mark ${phase === "available" ? "is-available" : ""}`}>
          <Icon name={phase === "available" ? "download" : "refresh"} size={19} />
        </span>
        <div className="update-copy">
          <b>
            SCUM Mod Desk {info?.currentVersion ?? ""}
            {phase === "available" && info?.version ? ` → ${info.version}` : ""}
          </b>
          <span>{statusText(info, phase, error)}</span>
        </div>
        <div className="update-actions">
          {phase === "available" ? (
            <Button onClick={onShowDetails}>查看更新</Button>
          ) : (
            <Button icon="refresh" onClick={onCheck} disabled={busy}>
              {checking ? "正在检查" : "检查更新"}
            </Button>
          )}
        </div>
      </div>

      {busy && phase !== "checking" ? (
        <div className="update-inline-progress">
          <div>
            <span>{progressLabel(phase)}</span>
            <b>{percent !== null ? `${percent}%` : "校验中"}</b>
          </div>
          <i>
            <span style={{ width: percent !== null ? `${percent}%` : "36%" }} />
          </i>
        </div>
      ) : null}

      {phase === "available" && info ? (
        <div className="update-available-meta">
          <span>{info.size ? formatBytes(info.size) : "安装包大小以下载页为准"}</span>
          <span>发布于 {formatDate(info.publishedAt)}</span>
          <span>
            <Icon name="lock" size={12} />
            仅安装签名匹配的版本
          </span>
        </div>
      ) : null}

      <p className="settings-note update-note">
        更新清单通过 HTTPS 获取。Rust 后端会在临时目录下载安装包、校验 Tauri
        签名，再启动系统安装器；前端不接触私钥。
      </p>
    </section>
  );
}

function statusText(info: AppUpdateInfo | null, phase: AppUpdatePhase, error: string | null) {
  if (phase === "checking") return "正在读取签名更新清单";
  if (phase === "unconfigured") return "当前构建未配置更新通道，发布版会自动启用";
  if (phase === "error") return error ?? "检查更新失败";
  if (phase === "up-to-date") return "已是最新版本";
  if (phase === "downloading") return "正在下载安装包";
  if (phase === "verifying") return "下载完成，正在校验签名";
  if (phase === "installing") return "安装器已启动，应用即将重启";
  if (phase === "available" && info?.version) {
    return `新版本 ${info.version} 可以安装`;
  }
  return "检查是否有新的稳定版本";
}

function progressLabel(phase: AppUpdatePhase) {
  if (phase === "verifying") return "正在校验安装包签名";
  if (phase === "installing") return "正在启动安装器";
  return "下载进度";
}
