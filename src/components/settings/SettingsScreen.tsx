import { useEffect, useState } from "react";
import type {
  AppEdition,
  AppSettings,
  AppUpdateInfo,
  AppUpdatePhase,
  AppUpdateProgress,
  ThemeMode,
} from "../../types";
import { clampCloudDownloadSegments } from "../../lib/cloudDownload";
import { Button } from "../ui/Button";
import { Toggle } from "../ui/Toggle";
import { UpdateSettings } from "./UpdateSettings";

interface SettingsScreenProps {
  settings: AppSettings;
  theme: ThemeMode;
  edition: AppEdition;
  onSave: (settings: AppSettings) => void;
  onDetectPaths: () => void;
  onThemePreview: (theme: ThemeMode) => void;
  onChooseDirectory: (kind: "client" | "server") => Promise<string | null>;
  updateInfo: AppUpdateInfo | null;
  updatePhase: AppUpdatePhase;
  updateProgress: AppUpdateProgress | null;
  updateError: string | null;
  onCheckUpdate: () => void;
  onShowUpdate: () => void;
}

export function SettingsScreen({
  settings,
  theme,
  edition,
  onSave,
  onDetectPaths,
  onThemePreview,
  onChooseDirectory,
  updateInfo,
  updatePhase,
  updateProgress,
  updateError,
  onCheckUpdate,
  onShowUpdate,
}: SettingsScreenProps) {
  const [draft, setDraft] = useState(settings);

  useEffect(() => setDraft(settings), [settings]);
  useEffect(() => {
    setDraft((current) =>
      current.theme === theme ? current : { ...current, theme },
    );
  }, [theme]);

  function update(patch: Partial<AppSettings>) {
    setDraft((current) => ({ ...current, ...patch }));
  }

  return (
    <section className="page page-settings">
      <header className="page-header">
        <div>
          <h1>设置</h1>
          <p>路径、启动参数、主题与云源。凭据统一交给后端密钥仓库处理。</p>
        </div>
        <div className="heading-tools">
          <Button icon="search" onClick={onDetectPaths}>
            自动检测路径
          </Button>
          <Button
            variant="primary"
            onClick={() =>
              onSave({
                ...draft,
                cloud: {
                  ...draft.cloud,
                  maxDownloadSegments: clampCloudDownloadSegments(
                    draft.cloud.maxDownloadSegments,
                  ),
                },
              })
            }
          >
            保存设置
          </Button>
        </div>
      </header>

      <div className="settings-sheet">
        <section className="settings-group">
          <div className="section-title">
            <span>游戏路径</span>
            <b>客户端与服务端分开保存</b>
          </div>
          <div className="form-grid">
            <label className="form-span-2">
              <span>SCUM 客户端</span>
              <div className="input-with-button">
                <input
                  value={draft.scumInstallPath}
                  onChange={(event) => update({ scumInstallPath: event.target.value })}
                  placeholder="X:/SteamLibrary/steamapps/common/SCUM"
                />
                <Button
                  size="sm"
                  icon="folder"
                  onClick={async () => {
                    const path = await onChooseDirectory("client");
                    if (path) update({ scumInstallPath: path });
                  }}
                >
                  选择
                </Button>
              </div>
            </label>
            <label className="form-span-2">
              <span>SCUM Server 服务端</span>
              <div className="input-with-button">
                <input
                  value={draft.serverInstallPath}
                  onChange={(event) => update({ serverInstallPath: event.target.value })}
                  placeholder="X:/SteamLibrary/steamapps/common/SCUM Server"
                />
                <Button
                  size="sm"
                  icon="folder"
                  onClick={async () => {
                    const path = await onChooseDirectory("server");
                    if (path) update({ serverInstallPath: path });
                  }}
                >
                  选择
                </Button>
              </div>
            </label>
          </div>
        </section>

        <UpdateSettings
          info={updateInfo}
          phase={updatePhase}
          progress={updateProgress}
          error={updateError}
          onCheck={onCheckUpdate}
          onShowDetails={onShowUpdate}
        />

        <section className="settings-group">
          <div className="section-title">
            <span>启动参数</span>
            <b>存在 PAK 时自动附加反作弊兼容参数</b>
          </div>
          <div className="setting-switches">
            <label>
              <span>
                <b>启用日志</b>
                <small>向游戏附加 `-log`</small>
              </span>
              <Toggle
                checked={draft.launchOptions.log}
                onChange={(log) =>
                  update({ launchOptions: { ...draft.launchOptions, log } })
                }
                label="启用日志"
              />
            </label>
            <label>
              <span>
                <b>文件打开日志</b>
                <small>向游戏附加 `-fileopenlog`</small>
              </span>
              <Toggle
                checked={draft.launchOptions.fileOpenLog}
                onChange={(fileOpenLog) =>
                  update({ launchOptions: { ...draft.launchOptions, fileOpenLog } })
                }
                label="文件打开日志"
              />
            </label>
            <label>
              <span>
                <b>禁用 BattlEye</b>
                <small>存在 PAK 模组时强制开启</small>
              </span>
              <Toggle
                checked={draft.launchOptions.noBattlEye}
                onChange={(noBattlEye) =>
                  update({ launchOptions: { ...draft.launchOptions, noBattlEye } })
                }
                label="禁用 BattlEye"
              />
            </label>
            <label>
              <span>
                <b>服务端端口</b>
                <small>仅启动服务端时使用</small>
              </span>
              <input
                className="compact-input"
                value={draft.launchOptions.port}
                inputMode="numeric"
                onChange={(event) =>
                  update({ launchOptions: { ...draft.launchOptions, port: event.target.value } })
                }
              />
            </label>
          </div>
        </section>

        <section className="settings-group">
          <div className="section-title">
            <span>外观</span>
            <b>同一布局，不同材质</b>
          </div>
          <div className="theme-options">
            <button
              type="button"
              className={draft.theme === "light" ? "is-active" : ""}
              onClick={() => {
                update({ theme: "light" });
                onThemePreview("light");
              }}
            >
              <span className="theme-swatch theme-light">
                <i />
                <i />
              </span>
              <b>暖纸亮色</b>
              <small>#e9e5da / #f5f1e7</small>
            </button>
            <button
              type="button"
              className={draft.theme === "dark" ? "is-active" : ""}
              onClick={() => {
                update({ theme: "dark" });
                onThemePreview("dark");
              }}
            >
              <span className="theme-swatch theme-dark">
                <i />
                <i />
              </span>
              <b>中性炭黑</b>
              <small>#151515 / #1c1c1c</small>
            </button>
          </div>
        </section>

        <section className="settings-group settings-cloud">
          <div className="section-title">
            <span>云源线路</span>
            <b>{edition === "server" ? "服务器版使用内置共享凭据" : "公开版仅访问公开目录"}</b>
          </div>
          <div className="settings-cloud-fields">
            <label>
              <span>候选地址</span>
              <textarea
                className="note-input settings-textarea"
                rows={4}
                value={draft.cloud.baseUrls.join("\n")}
                placeholder="https://your-catalog.example"
                onChange={(event) =>
                  update({
                    cloud: {
                      ...draft.cloud,
                      baseUrls: event.target.value
                        .split("\n")
                        .map((line) => line.trim())
                        .filter(Boolean),
                    },
                  })
                }
              />
            </label>
            <label className="settings-segment-field">
              <span>并行分片上限</span>
              <input
                type="number"
                min={8}
                max={128}
                step={1}
                value={draft.cloud.maxDownloadSegments}
                onChange={(event) => {
                  const value = Number(event.target.value);
                  update({
                    cloud: {
                      ...draft.cloud,
                      maxDownloadSegments: Number.isFinite(value) ? value : 8,
                    },
                  });
                }}
                onBlur={() =>
                  update({
                    cloud: {
                      ...draft.cloud,
                      maxDownloadSegments: clampCloudDownloadSegments(
                        draft.cloud.maxDownloadSegments,
                      ),
                    },
                  })
                }
              />
              <small>单文件默认 16 路；单个模组最多 128 路，多个模组共享全局 256 连接上限。</small>
            </label>
          </div>
          <div className="settings-note">
            {edition === "server"
              ? "共享密钥只由服务器安装包携带并交给 Rust 后端使用，前端不会读取密钥内容。"
              : "公开版不会读取或发送私人密钥；需要私人模组时请改用服务器安装包。"}
          </div>
        </section>
      </div>
    </section>
  );
}
