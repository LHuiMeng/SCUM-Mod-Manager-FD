import { useCallback, useEffect, useRef, useState } from "react";
import { api, chooseDirectory, chooseFiles, isTauri } from "./api/tauri";
import type {
  AppInfo,
  AppSettings,
  AppUpdateInfo,
  AppUpdatePhase,
  AppUpdateProgress,
  CloudDownloadProgress,
  LibrarySnapshot,
  NavSection,
  RemoteFile,
  RemoteMod,
  RuntimeLog,
  SftpAccount,
  ThemeMode,
  ToastMessage,
} from "./types";
import { formatClock, formatBytes } from "./lib/format";
import { resolveFileDrop } from "./lib/fileDrop";
import { cloudDownloadIsActive } from "./lib/cloudDownload";
import { AppShell } from "./components/shell/AppShell";
import { LibraryScreen } from "./components/library/LibraryScreen";
import { CloudScreen } from "./components/cloud/CloudScreen";
import { ServerScreen } from "./components/server/ServerScreen";
import { LogScreen } from "./components/logs/LogScreen";
import { SettingsScreen } from "./components/settings/SettingsScreen";
import { UpdateDialog } from "./components/settings/UpdateDialog";
import { ToastStack } from "./components/ui/ToastStack";

interface SftpTrustPrompt {
  accountId: string;
  fingerprint: string;
  message: string;
}

function applyTheme(theme: ThemeMode) {
  document.documentElement.dataset.theme = theme;
  document.documentElement.style.colorScheme = theme;
  localStorage.setItem("scum-theme", theme);
}

export default function App() {
  const [snapshot, setSnapshot] = useState<LibrarySnapshot | null>(null);
  const [appInfo, setAppInfo] = useState<AppInfo | null>(null);
  const [section, setSection] = useState<NavSection>("library");
  const [theme, setThemeState] = useState<ThemeMode>(
    () => (localStorage.getItem("scum-theme") as ThemeMode | null) ?? "light",
  );
  const [search, setSearch] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [toasts, setToasts] = useState<ToastMessage[]>([]);
  const toastId = useRef(0);
  const [cloudMods, setCloudMods] = useState<RemoteMod[]>([]);
  const [cloudLoading, setCloudLoading] = useState(false);
  const [cloudError, setCloudError] = useState<string | null>(null);
  const [cloudLoaded, setCloudLoaded] = useState(false);
  const [cloudDownloads, setCloudDownloads] = useState<
    Record<string, CloudDownloadProgress>
  >({});
  const [logs, setLogs] = useState<RuntimeLog[]>([]);
  const [remoteFiles, setRemoteFiles] = useState<RemoteFile[]>([]);
  const [serverError, setServerError] = useState<string | null>(null);
  const [sftpTrustPrompt, setSftpTrustPrompt] = useState<SftpTrustPrompt | null>(null);
  const [updateInfo, setUpdateInfo] = useState<AppUpdateInfo | null>(null);
  const [updatePhase, setUpdatePhase] = useState<AppUpdatePhase>("idle");
  const [updateProgress, setUpdateProgress] = useState<AppUpdateProgress | null>(null);
  const [updateError, setUpdateError] = useState<string | null>(null);
  const [updateDialogOpen, setUpdateDialogOpen] = useState(false);
  const [fileDragActive, setFileDragActive] = useState(false);
  const [windowMaximized, setWindowMaximized] = useState(false);
  const bootUpdateChecked = useRef(false);
  const importPathsRef = useRef<(paths: string[]) => Promise<void>>(async () => undefined);
  const sectionRef = useRef<NavSection>("library");
  const launchSettingsRevision = useRef(0);
  const launchSettingsQueue = useRef<Promise<void>>(Promise.resolve());
  const activeCloudDownloads = useRef(new Set<string>());

  const notify = useCallback(
    (title: string, detail?: string, tone: ToastMessage["tone"] = "default") => {
      const id = ++toastId.current;
      setToasts((current) => [...current.slice(-2), { id, title, detail, tone }]);
      window.setTimeout(() => {
        setToasts((current) => current.filter((toast) => toast.id !== id));
      }, 3600);
    },
    [],
  );

  const importPaths = useCallback(
    async (paths: string[]) => {
      if (paths.length === 0) return;
      if (!snapshot) {
        notify("模组库仍在加载", "请稍后重新拖入。", "default");
        return;
      }
      if (busy) {
        notify("正在处理上一项任务", "请稍后再拖放模组。");
        return;
      }
      setBusy(true);
      notify("正在导入拖放内容", `${paths.length} 个文件或文件夹`, "default");
      try {
        const result = await api.importMods(paths);
        const next = await api.getSnapshot();
        setSnapshot(next);
        setSelectedId((current) =>
          next.mods.some((mod) => mod.id === current) ? current : next.mods[0]?.id ?? null,
        );
        notify("导入完成", result.message, "success");
      } catch (error) {
        notify("导入失败", String(error), "error");
      } finally {
        setBusy(false);
      }
    },
    [busy, notify, snapshot],
  );

  useEffect(() => {
    importPathsRef.current = importPaths;
  }, [importPaths]);

  useEffect(() => {
    applyTheme(theme);
  }, [theme]);

  useEffect(() => {
    let cancelled = false;
    Promise.all([api.getSnapshot(), api.getAppInfo()])
      .then(([next, info]) => {
        if (cancelled) return;
        setAppInfo(info);
        setSnapshot(next);
        const savedTheme =
          (localStorage.getItem("scum-theme") as ThemeMode | null) ?? next.settings.theme;
        setThemeState(savedTheme);
        setSelectedId(
          [...next.mods].sort((a, b) => a.loadOrder - b.loadOrder)[0]?.id ?? null,
        );
      })
      .catch((error) => {
        notify("无法加载本地数据", String(error), "error");
      });
    return () => {
      cancelled = true;
    };
  }, [notify]);

  useEffect(() => {
    if (!isTauri()) return;
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void import("@tauri-apps/api/event")
      .then(({ listen }) =>
        listen<AppUpdateProgress>("app-update-progress", (event) => {
          setUpdateProgress(event.payload);
          setUpdatePhase(event.payload.phase);
        }),
      )
      .then((stop) => {
        if (disposed) stop();
        else unlisten = stop;
      })
      .catch(() => undefined);
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    if (!isTauri()) return;
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void import("@tauri-apps/api/event")
      .then(({ listen }) =>
        listen<CloudDownloadProgress>("cloud-download-progress", (event) => {
          const progress = event.payload;
          setCloudDownloads((current) => {
            const previous = current[progress.id];
            const total = progress.total ?? previous?.total ?? null;
            // 失败事件里的 downloaded 是 0，不能让它把已下载的量抹掉。
            const keepsProgress =
              progress.phase === "downloading" || progress.phase === "error";
            const downloaded =
              keepsProgress && previous
                ? Math.max(progress.downloaded, previous.downloaded)
                : progress.downloaded;
            return {
              ...current,
              [progress.id]: {
                ...progress,
                downloaded,
                total,
              },
            };
          });
        }),
      )
      .then((stop) => {
        if (disposed) stop();
        else unlisten = stop;
      })
      .catch(() => undefined);
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    if (!isTauri()) return;
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void import("@tauri-apps/api/event")
      .then(({ listen }) =>
        listen<LibrarySnapshot["gameStatus"]>("game-status-changed", (event) => {
          const status = event.payload;
          setSnapshot((current) =>
            current ? { ...current, gameStatus: status } : current,
          );
          if (status.running) return;
          void api
            .getSnapshot()
            .then((next) => {
              if (!disposed) {
                setSnapshot((current) =>
                  current ? { ...next, settings: current.settings } : next,
                );
              }
            })
            .catch(() => undefined);
        }),
      )
      .then((stop) => {
        if (disposed) stop();
        else unlisten = stop;
      })
      .catch(() => undefined);
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    if (!isTauri()) return;
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void import("@tauri-apps/api/webview")
      .then(({ getCurrentWebview }) =>
        getCurrentWebview().onDragDropEvent((event) => {
          const result = resolveFileDrop(sectionRef.current, event.payload);
          setFileDragActive(result.active);
          if (result.paths.length > 0) {
            void importPathsRef.current(result.paths);
          } else if (result.requiresLibrary) {
            notify("请先打开模组库", "将 PAK、ZIP 或 UE4SS 文件夹拖到模组列表即可导入。");
          }
        }),
      )
      .then((stop) => {
        if (disposed) stop();
        else unlisten = stop;
      })
      .catch((error) => {
        if (!disposed) notify("拖放导入初始化失败", String(error), "error");
      });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [notify]);

  useEffect(() => {
    sectionRef.current = section;
    if (section !== "library") setFileDragActive(false);
  }, [section]);

  useEffect(() => {
    if (!isTauri()) return;
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void import("@tauri-apps/api/window")
      .then(async ({ getCurrentWindow }) => {
        const current = getCurrentWindow();
        const sync = async () => {
          const maximized = await current.isMaximized();
          if (!disposed) setWindowMaximized(maximized);
        };
        await sync();
        const stop = await current.onResized(() => void sync());
        if (disposed) stop();
        else unlisten = stop;
      })
      .catch(() => undefined);
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  const refreshLogs = useCallback(async () => {
    try {
      setLogs(await api.getLogs());
    } catch (error) {
      notify("日志读取失败", String(error), "error");
    }
  }, [notify]);

  const checkForUpdate = useCallback(
    async (silent = false) => {
      setUpdatePhase("checking");
      setUpdateError(null);
      try {
        const result = await api.checkAppUpdate();
        setUpdateInfo(result);
        if (!result.configured) {
          setUpdatePhase("unconfigured");
          if (!silent) {
            notify("更新通道尚未配置", "开发构建不会连接公开更新服务器。");
          }
          return;
        }
        if (result.available) {
          setUpdatePhase("available");
          if (!silent) setUpdateDialogOpen(true);
          return;
        }
        setUpdatePhase("up-to-date");
        if (!silent) {
          notify("已是最新版本", `当前版本 ${result.currentVersion}`, "success");
        }
      } catch (error) {
        const message = String(error);
        setUpdateError(message);
        setUpdatePhase("error");
        if (!silent) notify("检查更新失败", message, "error");
      }
    },
    [notify],
  );

  useEffect(() => {
    if (!snapshot || bootUpdateChecked.current) return;
    bootUpdateChecked.current = true;
    void checkForUpdate(true);
  }, [checkForUpdate, snapshot]);

  useEffect(() => {
    if (section === "logs") void refreshLogs();
  }, [refreshLogs, section]);

  const refreshCloud = useCallback(
    async (force = false) => {
      if (!snapshot) return;
      if (snapshot.settings.cloud.baseUrls.length === 0) {
        setCloudError(null);
        setCloudLoaded(true);
        return;
      }
      if (cloudLoading || (cloudLoaded && !force)) return;
      setCloudLoading(true);
      setCloudError(null);
      try {
        const mods = await api.fetchCloudCatalog();
        setCloudMods(mods);
        setCloudLoaded(true);
      } catch (error) {
        setCloudError(String(error));
      } finally {
        setCloudLoading(false);
      }
    },
    [cloudLoaded, cloudLoading, snapshot],
  );

  useEffect(() => {
    if (section === "cloud") void refreshCloud();
  }, [refreshCloud, section]);

  function changeTheme(nextTheme: ThemeMode) {
    setThemeState(nextTheme);
    applyTheme(nextTheme);
    void api.setTheme(nextTheme).catch(() => undefined);
  }

  async function handleScan() {
    if (!snapshot || busy) return;
    setBusy(true);
    try {
      const next = await api.scanLibrary();
      setSnapshot(next);
      setSelectedId((current) =>
        next.mods.some((mod) => mod.id === current) ? current : next.mods[0]?.id ?? null,
      );
      notify("扫描完成", `发现 ${next.mods.length} 个本地模组`, "success");
    } catch (error) {
      notify("扫描失败", String(error), "error");
    } finally {
      setBusy(false);
    }
  }

  async function handleImport() {
    const paths = await chooseFiles();
    if (paths.length === 0) {
      if (!isTauri()) {
        notify("浏览器预览不读取文件系统", "请在桌面版中选择或拖入模组。");
      }
      return;
    }
    await importPaths(paths);
  }

  async function handleToggle(id: string, enabled: boolean) {
    if (!snapshot) return;
    const optimistic = {
      ...snapshot,
      mods: snapshot.mods.map((mod) => (mod.id === id ? { ...mod, enabled } : mod)),
    };
    setSnapshot(optimistic);
    try {
      setSnapshot(await api.setModEnabled(id, enabled));
    } catch (error) {
      setSnapshot(snapshot);
      notify("状态保存失败", String(error), "error");
    }
  }

  async function handleReorder(ids: string[]) {
    if (!snapshot) return;
    const byId = new Map(snapshot.mods.map((mod) => [mod.id, mod]));
    const optimistic = {
      ...snapshot,
      mods: ids.flatMap((id, index) => {
        const mod = byId.get(id);
        return mod ? [{ ...mod, loadOrder: index }] : [];
      }),
    };
    setSnapshot(optimistic);
    try {
      setSnapshot(await api.reorderMods(ids));
    } catch (error) {
      setSnapshot(snapshot);
      notify("加载顺序保存失败", String(error), "error");
    }
  }

  async function handleEdit(id: string, tags: string[], notes: string) {
    try {
      setSnapshot(await api.updateModMetadata(id, tags, notes));
      notify("模组信息已保存", undefined, "success");
    } catch (error) {
      notify("保存失败", String(error), "error");
    }
  }

  async function handleLaunch() {
    if (!snapshot || snapshot.gameStatus.running) return;
    if (!snapshot.settings.scumInstallPath.trim()) {
      notify("尚未设置客户端路径", "请先在设置中定位 SCUM 安装目录。", "error");
      setSection("settings");
      return;
    }
    setBusy(true);
    try {
      const status = await api.launchGame("client");
      setSnapshot((current) =>
        current ? { ...current, gameStatus: status } : current,
      );
      notify("游戏已启动", "启用模组已完成部署", "success");
    } catch (error) {
      notify("启动失败", String(error), "error");
    } finally {
      setBusy(false);
    }
  }

  async function handleKill() {
    if (!snapshot) return;
    setBusy(true);
    try {
      const status = await api.killGame();
      setSnapshot(await api.getSnapshot().then((next) => ({ ...next, gameStatus: status })));
      notify("游戏已关闭", "本次部署的模组已回收", "success");
    } catch (error) {
      notify("关闭失败", String(error), "error");
    } finally {
      setBusy(false);
    }
  }

  async function handleSaveSettings(settings: AppSettings) {
    try {
      const saved = await api.saveSettings(settings);
      setSnapshot((current) => (current ? { ...current, settings: saved } : current));
      setThemeState(saved.theme);
      applyTheme(saved.theme);
      notify("设置已保存", undefined, "success");
    } catch (error) {
      notify("设置保存失败", String(error), "error");
    }
  }

  function handleLaunchOptionsChange(launchOptions: AppSettings["launchOptions"]) {
    if (!snapshot) return;
    const revision = ++launchSettingsRevision.current;
    const settings = { ...snapshot.settings, launchOptions };
    setSnapshot((current) =>
      current ? { ...current, settings } : current,
    );
    launchSettingsQueue.current = launchSettingsQueue.current
      .catch(() => undefined)
      .then(async () => {
        const saved = await api.saveSettings(settings);
        if (revision !== launchSettingsRevision.current) return;
        setSnapshot((current) =>
          current
            ? {
                ...current,
                settings: {
                  ...current.settings,
                  launchOptions: saved.launchOptions,
                },
              }
            : current,
        );
      })
      .catch(async (error) => {
        if (revision !== launchSettingsRevision.current) return;
        notify("启动选项保存失败", String(error), "error");
        try {
          const next = await api.getSnapshot();
          if (revision === launchSettingsRevision.current) setSnapshot(next);
        } catch {
          // Keep the current view usable; a later settings save can retry.
        }
      });
  }

  async function handleInstallUpdate() {
    if (!updateInfo?.available) return;
    setUpdateError(null);
    setUpdateProgress({
      phase: "downloading",
      downloaded: 0,
      total: updateInfo.size,
    });
    setUpdatePhase("downloading");
    try {
      const result = await api.installAppUpdate();
      setUpdatePhase("installing");
      notify("安装程序已启动", result.message, "success");
    } catch (error) {
      const message = String(error);
      setUpdateError(message);
      setUpdatePhase("error");
      notify("安装更新失败", message, "error");
    }
  }

  async function handleDetectPaths() {
    try {
      const paths = await api.detectPaths();
      if (!snapshot) return;
      const next = { ...snapshot.settings, ...paths };
      const saved = await api.saveSettings(next);
      setSnapshot({ ...snapshot, settings: saved });
      notify(
        "路径检测完成",
        paths.scumInstallPath || paths.serverInstallPath
          ? "已更新客户端与服务端路径"
          : "未从 Steam 库中找到 SCUM",
        "success",
      );
    } catch (error) {
      notify("路径检测失败", String(error), "error");
    }
  }

  async function handleDownloadRemoteMod(id: string) {
    const current = cloudDownloads[id];
    if (
      activeCloudDownloads.current.has(id) ||
      (current && cloudDownloadIsActive(current))
    ) {
      return;
    }
    const remote = cloudMods.find((mod) => mod.id === id);
    const total = remote?.fileSize || null;
    activeCloudDownloads.current.add(id);
    setCloudDownloads((downloads) => ({
      ...downloads,
      [id]: {
        id,
        phase: "queued",
        downloaded: 0,
        total,
        segments: 0,
      },
    }));
    try {
      const result = await api.downloadRemoteMod(id);
      notify("下载完成", result.message, "success");
      setCloudDownloads((downloads) => {
        const latest = downloads[id];
        const completedTotal = latest?.total ?? total;
        return {
          ...downloads,
          [id]: {
            id,
            phase: "completed",
            downloaded: completedTotal ?? latest?.downloaded ?? 0,
            total: completedTotal,
            segments: 0,
          },
        };
      });
      setCloudMods((current) =>
        current.map((mod) => (mod.id === id ? { ...mod, installed: true } : mod)),
      );
      try {
        setSnapshot(await api.getSnapshot());
      } catch (error) {
        notify("模组库刷新失败", String(error), "error");
      }
    } catch (error) {
      const message = String(error);
      notify("下载失败", message, "error");
      setCloudDownloads((downloads) => {
        const latest = downloads[id];
        return {
          ...downloads,
          [id]: {
            id,
            phase: "error",
            downloaded: latest?.downloaded ?? 0,
            total: latest?.total ?? total,
            segments: latest?.segments ?? 0,
            message,
          },
        };
      });
    } finally {
      activeCloudDownloads.current.delete(id);
    }
  }

  async function handleSaveSftpAccount(
    account: Omit<SftpAccount, "id" | "hasPassword">,
    password: string,
  ) {
    try {
      const next = await api.saveSftpAccount(account, password);
      setSnapshot(next);
      setSftpTrustPrompt(null);
      notify("SFTP 账户已安全保存", "密码已交由 Rust 后端加密存储", "success");
    } catch (error) {
      setServerError(String(error));
      notify("账户保存失败", String(error), "error");
    }
  }

  async function handleTestSftp(accountId: string) {
    setServerError(null);
    try {
      const result = await api.testSftpConnection(accountId);
      if (result.requiresTrust && result.hostKeyFingerprint) {
        setSftpTrustPrompt({
          accountId,
          fingerprint: result.hostKeyFingerprint,
          message: result.message,
        });
        notify("需要确认服务器主机指纹", "核对指纹后才能发送密码并建立连接。");
        return;
      }
      setSftpTrustPrompt(null);
      if (!result.ok) throw new Error(result.message);
      notify("连接成功", result.message, "success");
      if (result.detectedModsPath) {
        await handleLoadRemoteFiles(result.detectedModsPath);
      }
    } catch (error) {
      setServerError(String(error));
      notify("SFTP 连接失败", String(error), "error");
    }
  }

  async function handleTrustSftpHost() {
    if (!sftpTrustPrompt) return;
    setServerError(null);
    try {
      await api.trustSftpHost(sftpTrustPrompt.accountId, sftpTrustPrompt.fingerprint);
      const accountId = sftpTrustPrompt.accountId;
      setSftpTrustPrompt(null);
      notify("主机密钥已信任", "正在重新验证账户与远端目录", "success");
      await handleTestSftp(accountId);
    } catch (error) {
      setServerError(String(error));
      notify("主机密钥保存失败", String(error), "error");
    }
  }

  async function handleLoadRemoteFiles(path: string) {
    setServerError(null);
    setBusy(true);
    try {
      setRemoteFiles(await api.listRemoteFiles(path));
    } catch (error) {
      setServerError(String(error));
    } finally {
      setBusy(false);
    }
  }

  async function handleUpload(accountId: string, paths: string[]) {
    const selected = paths.length > 0 ? paths : await chooseFiles();
    if (selected.length === 0) {
      notify("没有选择服务器模组", "浏览器预览下不会读取真实文件系统。");
      return;
    }
    setBusy(true);
    try {
      const result = await api.uploadServerMods(accountId, selected);
      notify("上传完成", result.message, "success");
      const account = snapshot?.settings.sftpAccounts.find((item) => item.id === accountId);
      if (account) await handleLoadRemoteFiles(account.modsPath);
    } catch (error) {
      setServerError(String(error));
      notify("上传失败", String(error), "error");
    } finally {
      setBusy(false);
    }
  }

  async function handleChooseDirectory(kind: "client" | "server") {
    const path = await chooseDirectory();
    if (!path) {
      notify("未选择目录", `请在 Tauri 桌面版中选择${kind === "client" ? "客户端" : "服务端"}目录。`);
    }
    return path;
  }

  if (!snapshot) {
    return (
      <div className="boot-screen">
        <span className="boot-mark">SM</span>
        <div>
          <b>SCUM MOD DESK</b>
          <span>正在读取本地模组数据</span>
        </div>
        <i />
      </div>
    );
  }

  const enabled = snapshot.mods.filter((mod) => mod.enabled);
  const deployedBytes = enabled.reduce((sum, mod) => sum + mod.fileSize, 0);

  return (
    <>
      <AppShell
        section={section}
        theme={theme}
        gameStatus={snapshot.gameStatus}
        deployedSize={formatBytes(deployedBytes)}
        lastChecked={formatClock(snapshot.lastScannedAt)}
        updateAvailable={updatePhase === "available"}
        updateVersion={updateInfo?.version ?? null}
        maximized={windowMaximized}
        onSectionChange={(next) => {
          setSection(next);
          if (next !== "library") setSearch("");
        }}
        onToggleTheme={() => changeTheme(theme === "dark" ? "light" : "dark")}
        onOpenUpdate={() => updateInfo?.available && setUpdateDialogOpen(true)}
        onMinimize={() => void api.minimize()}
        onMaximize={() => void api.toggleMaximize()}
        onClose={() => void api.close()}
      >
        <div className="page-transition" key={section}>
          {section === "library" ? (
            <LibraryScreen
              snapshot={snapshot}
              search={search}
              onSearchChange={setSearch}
              onScan={handleScan}
              onImport={handleImport}
              onToggle={handleToggle}
              onReorder={handleReorder}
              onEdit={handleEdit}
              onLaunch={handleLaunch}
              onKill={handleKill}
              onOpenFolder={(id) => void api.openModFolder(id)}
              onLaunchOptionsChange={handleLaunchOptionsChange}
              onNavigate={setSection}
              gameStatus={snapshot.gameStatus}
              selectedId={selectedId}
              onSelect={setSelectedId}
              fileDragActive={fileDragActive}
            />
          ) : null}
          {section === "cloud" ? (
            <CloudScreen
              mods={cloudMods}
              loading={cloudLoading}
              downloads={cloudDownloads}
              error={cloudError}
              configured={snapshot.settings.cloud.baseUrls.length > 0}
              edition={appInfo?.edition ?? "public"}
              maxSegments={snapshot.settings.cloud.maxDownloadSegments}
              onRefresh={() => void refreshCloud(true)}
              onDownload={(id) => void handleDownloadRemoteMod(id)}
              onOpenSettings={() => setSection("settings")}
            />
          ) : null}
          {section === "server" ? (
            <ServerScreen
              accounts={snapshot.settings.sftpAccounts}
              activeAccountId={snapshot.settings.activeSftpAccountId}
              files={remoteFiles}
              loading={busy}
              error={serverError}
              trustPrompt={sftpTrustPrompt}
              onSaveAccount={(account, password) =>
                void handleSaveSftpAccount(account, password)
              }
              onTestAccount={(id) => void handleTestSftp(id)}
              onTrustHost={() => void handleTrustSftpHost()}
              onDismissTrust={() => setSftpTrustPrompt(null)}
              onLoadFiles={(_id, path) => void handleLoadRemoteFiles(path)}
              onUpload={(id, paths) => void handleUpload(id, paths)}
              onOpenSettings={() => setSection("settings")}
            />
          ) : null}
          {section === "logs" ? (
            <LogScreen
              logs={logs}
              onRefresh={() => void refreshLogs()}
              onClear={() => {
                void api.clearLogs().then(() => setLogs([]));
              }}
            />
          ) : null}
          {section === "settings" ? (
            <SettingsScreen
              settings={snapshot.settings}
              theme={theme}
              edition={appInfo?.edition ?? "public"}
              onSave={(settings) => void handleSaveSettings(settings)}
              onDetectPaths={() => void handleDetectPaths()}
              onThemePreview={changeTheme}
              onChooseDirectory={handleChooseDirectory}
              updateInfo={updateInfo}
              updatePhase={updatePhase}
              updateProgress={updateProgress}
              updateError={updateError}
              onCheckUpdate={() => void checkForUpdate(false)}
              onShowUpdate={() => setUpdateDialogOpen(true)}
            />
          ) : null}
        </div>
      </AppShell>
      {updateDialogOpen && updateInfo?.available ? (
        <UpdateDialog
          info={updateInfo}
          phase={updatePhase}
          progress={updateProgress}
          error={updateError}
          onClose={() => setUpdateDialogOpen(false)}
          onInstall={() => void handleInstallUpdate()}
        />
      ) : null}
      <ToastStack
        messages={toasts}
        onDismiss={(id) => setToasts((current) => current.filter((toast) => toast.id !== id))}
      />
    </>
  );
}
