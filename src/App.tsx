import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  api,
  chooseDirectory,
  chooseFiles,
  chooseSavePath,
  chooseServerPakFiles,
  isTauri,
} from "./api/tauri";
import type {
  AppInfo,
  AppSettings,
  AppUpdateInfo,
  AppUpdatePhase,
  AppUpdateProgress,
  CloudDownloadProgress,
  Language,
  LibrarySnapshot,
  LocaleBundle,
  NavSection,
  ImportConflict,
  RemoteFile,
  RemoteMod,
  RuntimeLog,
  SftpAccount,
  SftpApplyResult,
  SftpConflictProgress,
  SftpConflictReport,
  SftpConnectionResult,
  ModConfigFile,
  SftpManagedManifest,
  SftpOperationProgress,
  SftpPrepareResult,
  SftpUploadKind,
  SftpUploadProgress,
  ThemeMode,
  ToastMessage,
  CrashReport,
  PendingLink,
  ReclaimProgress,
} from "./types";
import { formatClock, formatBytes } from "./lib/format";
import {
  I18nProvider,
  normalizeLanguage,
  readStoredLanguage,
  storeLanguage,
  SUPPORTED_LANGUAGES,
  translate,
  type Translator,
} from "./i18n";
import { resolveFileDrop } from "./lib/fileDrop";
import { cloudDownloadIsActive } from "./lib/cloudDownload";

import {
  applyOperationEvent,
  clearOperation,
  emptyOperations,
} from "./lib/operations";
import { CLOUD_AUTO_ATTEMPTS, runCloudCatalogAttempts } from "./lib/cloudCatalog";
import {
  buildServerLibrarySnapshot,
  normalizeServerLibraryState,
  readStoredServerLibraryState,
  serverLibraryDisabledPaths,
  serverLibraryReleasedPaths,
  storeServerLibraryState,
  type ServerLibraryState,
} from "./lib/serverLibrary";
import { AppShell } from "./components/shell/AppShell";
import { OperationDock } from "./components/shell/OperationDock";
import {
  LibraryScreen,
  type ServerLibraryView,
} from "./components/library/LibraryScreen";
import { ImportConflictDialog } from "./components/library/ImportConflictDialog";
import { ServerUploadPlanDialog } from "./components/library/ServerUploadPlanDialog";
import { ConfigEditorDialog } from "./components/library/ConfigEditorDialog";
import { CloudScreen } from "./components/cloud/CloudScreen";
import { ServerScreen } from "./components/server/ServerScreen";
import { BackupsScreen } from "./components/backups/BackupsScreen";
import { LogScreen } from "./components/logs/LogScreen";
import { SettingsScreen } from "./components/settings/SettingsScreen";
import { UpdateDialog } from "./components/settings/UpdateDialog";
import { ToastStack } from "./components/ui/ToastStack";
import { Button } from "./components/ui/Button";
import { Modal } from "./components/ui/Modal";

interface SftpTrustPrompt {
  accountId: string;
  fingerprint: string;
  message: string;
}

interface PendingImport {
  paths: string[];
  conflicts: ImportConflict[];
}

function applyTheme(theme: ThemeMode) {
  document.documentElement.dataset.theme = theme;
  document.documentElement.style.colorScheme = theme;
  localStorage.setItem("scum-theme", theme);
}

export default function App() {
  return <LocalizedApp />;
}

function LocalizedApp() {
  const initialLanguage = useRef<Language>(readStoredLanguage() ?? "zh-CN");
  const [language, setLanguageState] = useState<Language>(initialLanguage.current);
  const [localeMessages, setLocaleMessages] = useState<Record<string, string>>({});
  const languageRef = useRef(language);
  languageRef.current = language;
  const [snapshot, setSnapshot] = useState<LibrarySnapshot | null>(null);
  const [appInfo, setAppInfo] = useState<AppInfo | null>(null);
  const [section, setSection] = useState<NavSection>("library");
  const [theme, setThemeState] = useState<ThemeMode>(
    () => (localStorage.getItem("scum-theme") as ThemeMode | null) ?? "light",
  );
  const [search, setSearch] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [conflictMergeBusy, setConflictMergeBusy] = useState(false);
  const [toasts, setToasts] = useState<ToastMessage[]>([]);
  const toastId = useRef(0);
  const [cloudMods, setCloudMods] = useState<RemoteMod[]>([]);
  const [cloudLoading, setCloudLoading] = useState(false);
  const [cloudError, setCloudError] = useState<string | null>(null);
  const [cloudLoaded, setCloudLoaded] = useState(false);
  const [cloudAttempt, setCloudAttempt] = useState(0);
  const [cloudManualOnly, setCloudManualOnly] = useState(false);
  const [cloudDownloads, setCloudDownloads] = useState<
    Record<string, CloudDownloadProgress>
  >({});
  const [logs, setLogs] = useState<RuntimeLog[]>([]);
  const [remoteFiles, setRemoteFiles] = useState<RemoteFile[]>([]);
  const [serverError, setServerError] = useState<string | null>(null);
  const [sftpTrustPrompt, setSftpTrustPrompt] = useState<SftpTrustPrompt | null>(null);
  const [sftpScan, setSftpScan] = useState<SftpConnectionResult | null>(null);
  const [sftpScanAccountId, setSftpScanAccountId] = useState<string | null>(null);
  const [remoteNotes, setRemoteNotes] = useState<Record<string, string>>({});
  const [remoteConflicts, setRemoteConflicts] = useState<SftpConflictReport | null>(null);
  const [remoteConflictLoading, setRemoteConflictLoading] = useState(false);
  const [remoteConflictProgress, setRemoteConflictProgress] =
    useState<SftpConflictProgress | null>(null);
  const [uploadProgress, setUploadProgress] = useState<SftpUploadProgress | null>(null);
  const sftpAccountRef = useRef<string | null>(null);
  const conflictRequestRef = useRef(0);
  const uploadActiveRef = useRef(false);
  const analyzedAccountRef = useRef<string | null>(null);
  const [libraryMode, setLibraryMode] = useState<"local" | "server">("local");
  const [serverLibraryState, setServerLibraryState] =
    useState<ServerLibraryState | null>(null);
  const [serverPrepare, setServerPrepare] = useState<SftpPrepareResult | null>(null);
  const [serverPrepareBusy, setServerPrepareBusy] = useState(false);
  const [serverUploading, setServerUploading] = useState(false);
  const [pendingLinks, setPendingLinks] = useState<PendingLink[]>([]);
  const [crashReport, setCrashReport] = useState<CrashReport | null>(null);
  const [updateInfo, setUpdateInfo] = useState<AppUpdateInfo | null>(null);
  const [updatePhase, setUpdatePhase] = useState<AppUpdatePhase>("idle");
  const [updateProgress, setUpdateProgress] = useState<AppUpdateProgress | null>(null);
  const [updateError, setUpdateError] = useState<string | null>(null);
  const [updateDialogOpen, setUpdateDialogOpen] = useState(false);
  const [fileDragActive, setFileDragActive] = useState(false);
  const [pendingImport, setPendingImport] = useState<PendingImport | null>(null);
  // 启动失败时必须让用户看到原因并能重试，而不是永远停在 loading。
  const [bootError, setBootError] = useState<string | null>(null);
  const [bootAttempt, setBootAttempt] = useState(0);
  const [serverRestoreConfirm, setServerRestoreConfirm] = useState<string | null>(null);
  const [serverPlanOpen, setServerPlanOpen] = useState(false);
  const [configEditor, setConfigEditor] = useState<{
    modId: string;
    modName: string;
    files: ModConfigFile[];
  } | null>(null);
  const [windowMaximized, setWindowMaximized] = useState(false);
  const bootUpdateChecked = useRef(false);
  const importPathsRef = useRef<(paths: string[]) => Promise<void>>(async () => undefined);
  const sectionRef = useRef<NavSection>("library");
  const launchSettingsRevision = useRef(0);
  const launchSettingsQueue = useRef<Promise<void>>(Promise.resolve());
  const toggleRevisions = useRef(new Map<string, number>());
  const activeCloudDownloads = useRef(new Set<string>());
  const snapshotRef = useRef<LibrarySnapshot | null>(null);
  const cloudRequestActive = useRef(false);
  const cloudAutoStartedFor = useRef("");
  const cloudSourcesRevision = useRef(0);
  const localeRequest = useRef(0);
  const languageSaveRevision = useRef(0);
  const languageSaveQueue = useRef<Promise<void>>(Promise.resolve());
  snapshotRef.current = snapshot;

  const t = useCallback<Translator>(
    (key, variables) => translate(language, localeMessages, key, variables),
    [language, localeMessages],
  );

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

  const activeServerAccountId =
    snapshot?.settings.activeSftpAccountId &&
    sftpScanAccountId === snapshot.settings.activeSftpAccountId
      ? sftpScanAccountId
      : null;
  const serverLibraryView = useMemo(() => {
    if (!snapshot || !sftpScan || !remoteConflicts || !activeServerAccountId) {
      return null;
    }
    const state = normalizeServerLibraryState(
      serverLibraryState ?? readStoredServerLibraryState(activeServerAccountId, sftpScan),
      sftpScan,
    );
    const built = buildServerLibrarySnapshot({
      base: snapshot,
      scan: sftpScan,
      report: remoteConflicts,
      state,
      manifest: sftpScan.managedManifest ?? null,
      notes: remoteNotes,
      labels: {
        mergedName: t("serverLibrary.mergedName"),
        mergedTag: t("serverLibrary.mergedTag"),
        mergedDescription: (sources) =>
          t("serverLibrary.mergedDescription", {
            sources: sources.join("、"),
          }),
        disabledTag: t("serverLibrary.disabledTag"),
        disabledDescription: t("serverLibrary.disabledDescription"),
        deletedTag: t("serverLibrary.deletedTag"),
        deletedDescription: t("serverLibrary.deletedDescription"),
      },
    });
    return {
      ...built,
      accountId: activeServerAccountId,
      available: true,
      manifest: (sftpScan.managedManifest ?? null) as SftpManagedManifest | null,
    };
  }, [
    activeServerAccountId,
    remoteConflicts,
    remoteNotes,
    serverLibraryState,
    sftpScan,
    snapshot,
    t,
  ]);

  const completeImport = useCallback(
    async (paths: string[], replaceExisting: boolean) => {
      const result = await api.importMods(paths, replaceExisting);
      const next = await api.getSnapshot();
      setSnapshot(next);
      setSelectedId((current) =>
        next.mods.some((mod) => mod.id === current)
          ? current
          : next.mods[0]?.id ?? null,
      );
      notify(t("toast.importDone.title"), result.message, "success");
      return result;
    },
    [notify, t],
  );

  const importPaths = useCallback(
    async (paths: string[]) => {
      if (paths.length === 0) return;
      if (!snapshot) {
        notify(t("toast.libraryLoading.title"), t("toast.libraryLoading.detail"), "default");
        return;
      }
      if (busy) {
        notify(t("toast.busy.title"), t("toast.busy.detail"));
        return;
      }
      setBusy(true);
      try {
        const conflicts = await api.inspectModImport(paths);
        if (conflicts.length > 0) {
          setPendingImport({ paths, conflicts });
          return;
        }
        notify(
          t("toast.importing.title"),
          t("common.filesAndFolders", { count: paths.length }),
          "default",
        );
        await completeImport(paths, false);
      } catch (error) {
        notify(t("toast.importFailed.title"), String(error), "error");
      } finally {
        setBusy(false);
      }
    },
    [busy, completeImport, notify, snapshot, t],
  );

  async function handleReplaceImport() {
    if (!pendingImport || busy) return;
    setBusy(true);
    notify(
      t("toast.importing.title"),
      t("common.filesAndFolders", { count: pendingImport.paths.length }),
      "default",
    );
    try {
      await completeImport(pendingImport.paths, true);
      setPendingImport(null);
    } catch (error) {
      notify(t("toast.importFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
    }
  }

  function handleKeepExistingImport() {
    if (busy) return;
    setPendingImport(null);
    notify(
      t("toast.importKept.title"),
      t("toast.importKept.detail"),
      "default",
    );
  }

  const loadLocale = useCallback(
    async (nextLanguage: Language): Promise<LocaleBundle> => {
      const request = ++localeRequest.current;
      const bundle = await api.getLocale(nextLanguage);
      if (request === localeRequest.current) {
        setLocaleMessages(bundle.messages ?? {});
        if (bundle.warnings.length > 0) {
          notify(
            translate(nextLanguage, null, "toast.localeReadFailed.title"),
            translate(nextLanguage, null, "toast.localeReadFailed.detail", {
              error: bundle.warnings[0],
            }),
            "error",
          );
        }
      }
      return bundle;
    },
    [notify],
  );

  const changeLanguage = useCallback(
    async (nextLanguage: Language, persist = true) => {
      const normalized = normalizeLanguage(nextLanguage);
      const previous = languageRef.current;
      if (normalized === previous) {
        void loadLocale(normalized).catch(() => undefined);
        return;
      }
      const revision = ++languageSaveRevision.current;
      setLanguageState(normalized);
      languageRef.current = normalized;
      setToasts([]);
      storeLanguage(normalized);
      try {
        await loadLocale(normalized);
      } catch (error) {
        // Built-in dictionaries remain usable when the optional locale command fails.
        setLocaleMessages({});
        if (persist) {
          notify(
            translate(normalized, null, "toast.localeReadFailed.title"),
            translate(normalized, null, "toast.localeReadFailed.detail", {
              error: String(error),
            }),
            "error",
          );
        }
      }
      if (!persist) return;
      if (revision !== languageSaveRevision.current) return;
      const saveTask = languageSaveQueue.current
        .catch(() => undefined)
        .then(async () => {
          if (revision !== languageSaveRevision.current) return;
          const current = snapshot;
          if (!current) return;
          await api.setLanguage(normalized);
          if (revision !== languageSaveRevision.current) return;
          setSnapshot((value) =>
            value
              ? { ...value, settings: { ...value.settings, language: normalized } }
              : value,
          );
        });
      languageSaveQueue.current = saveTask.catch(() => undefined);
      try {
        await saveTask;
      } catch (error) {
        if (revision !== languageSaveRevision.current) return;
        setLanguageState(previous);
        languageRef.current = previous;
        storeLanguage(previous);
        if (snapshot) {
          void loadLocale(previous).catch(() => setLocaleMessages({}));
        }
        notify(
          translate(previous, null, "toast.localeSaveFailed.title"),
          translate(previous, null, "toast.localeSaveFailed.detail", {
            language:
              SUPPORTED_LANGUAGES.find((item) => item.id === previous)?.label ??
              previous,
            error: String(error),
          }),
          "error",
        );
      }
    },
    [loadLocale, notify, snapshot],
  );

  useEffect(() => {
    importPathsRef.current = importPaths;
  }, [importPaths]);

  useEffect(() => {
    applyTheme(theme);
  }, [theme]);

  useEffect(() => {
    document.documentElement.lang = language;
  }, [language]);

  useEffect(() => {
    let cancelled = false;
    setBootError(null);
    Promise.all([api.getSnapshot(), api.getAppInfo()])
      .then(([next, info]) => {
        if (cancelled) return;
        setAppInfo(info);
        setSnapshot(next);
        const savedTheme =
          (localStorage.getItem("scum-theme") as ThemeMode | null) ?? next.settings.theme;
        setThemeState(savedTheme);
        const savedLanguage =
          readStoredLanguage() ??
          normalizeLanguage(next.settings.language);
        setLanguageState(savedLanguage);
        languageRef.current = savedLanguage;
        storeLanguage(savedLanguage);
        void loadLocale(savedLanguage).catch((error) => {
          if (cancelled) return;
          notify(
            translate(savedLanguage, null, "toast.localeReadFailed.title"),
            translate(savedLanguage, null, "toast.localeReadFailed.detail", {
              error: String(error),
            }),
            "error",
          );
        });
        setSelectedId(
          [...next.mods].sort((a, b) => a.loadOrder - b.loadOrder)[0]?.id ?? null,
        );
      })
      .catch((error) => {
        if (cancelled) return;
        setBootError(String(error));
        notify(t("toast.loadFailed.title"), String(error), "error");
      });
    return () => {
      cancelled = true;
    };
  }, [bootAttempt, loadLocale, notify]);

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
        listen<LibrarySnapshot>("library-changed", (event) => {
          const next = event.payload;
          setSnapshot(next);
          setSelectedId((current) =>
            next.mods.some((mod) => mod.id === current)
              ? current
              : [...next.mods].sort((a, b) => a.loadOrder - b.loadOrder)[0]?.id ??
                null,
          );
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
    void api
      .getPendingLinks()
      .then((links) => setPendingLinks(links))
      .catch(() => undefined);
    void api
      .getLastCrash()
      .then((report) => {
        if (report) setCrashReport(report);
      })
      .catch(() => undefined);
  }, []);

  useEffect(() => {
    if (!isTauri()) return;
    let disposed = false;
    let unlistenGame: (() => void) | null = null;
    let unlistenReclaim: (() => void) | null = null;
    const lastReclaimNotice = { at: 0 };
    void import("@tauri-apps/api/event")
      .then(async ({ listen }) => {
        const stopGame = await listen<CrashReport>("game-crash-report", (event) => {
          setCrashReport(event.payload);
        });
        const stopReclaim = await listen<ReclaimProgress>("reclaim-progress", (event) => {
          const progress = event.payload;
          const now = Date.now();
          if (progress.waitedMs > 0 && now - lastReclaimNotice.at < 5000) return;
          lastReclaimNotice.at = now;
          notify(t("toast.reclaimWaiting.title"), progress.message, "default");
        });
        return [stopGame, stopReclaim] as const;
      })
      .then((stops) => {
        if (disposed) stops.forEach((stop) => stop());
        else {
          unlistenGame = stops[0];
          unlistenReclaim = stops[1];
        }
      })
      .catch(() => undefined);
    return () => {
      disposed = true;
      unlistenGame?.();
      unlistenReclaim?.();
    };
  }, [notify, t]);

  useEffect(() => {
    if (!activeServerAccountId || !sftpScan) {
      setServerLibraryState(null);
      setLibraryMode("local");
      return;
    }
    setServerLibraryState(
      readStoredServerLibraryState(activeServerAccountId, sftpScan),
    );
  }, [activeServerAccountId, sftpScan]);

  useEffect(() => {
    if (libraryMode !== "server" || !activeServerAccountId) return;
    if (analyzedAccountRef.current === activeServerAccountId) return;
    void analyzeRemoteConflictsInBackground(activeServerAccountId);
  }, [libraryMode, activeServerAccountId, sftpScan]);

  useEffect(() => {
    if (libraryMode === "server" && !serverLibraryView) {
      setLibraryMode("local");
    }
  }, [libraryMode, serverLibraryView]);

  useEffect(() => {
    if (!isTauri()) return;
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void import("@tauri-apps/api/event")
      .then(({ listen }) =>
        listen<SftpConflictProgress>("sftp-conflict-progress", (event) => {
          setRemoteConflictProgress(event.payload);
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

  // 统一操作流：所有服务器长操作（分析/融合/上传/下载/恢复）都走这一条。
  const [operations, setOperations] = useState(emptyOperations);
  useEffect(() => {
    if (!isTauri()) return;
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void import("@tauri-apps/api/event")
      .then(({ listen }) =>
        listen<SftpOperationProgress>("sftp-operation-progress", (event) => {
          setOperations((state) => applyOperationEvent(state, event.payload, Date.now()));
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

  // 浏览器预览：mock 用 window 事件模拟后端推送（Tauri 的 listen 在浏览器里不存在）。
  useEffect(() => {
    if (isTauri()) return;
    const handler = (event: Event) => {
      const detail = (event as CustomEvent<SftpOperationProgress>).detail;
      if (detail) setOperations((state) => applyOperationEvent(state, detail, Date.now()));
    };
    window.addEventListener("mock:sftp-operation-progress", handler);
    return () => window.removeEventListener("mock:sftp-operation-progress", handler);
  }, []);

  useEffect(() => {
    if (!isTauri()) return;
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void import("@tauri-apps/api/event")
      .then(({ listen }) =>
        listen<SftpUploadProgress>("sftp-upload-progress", (event) => {
          if (!uploadActiveRef.current) return;
          setUploadProgress(event.payload);
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
            notify(t("toast.openLibrary.title"), t("toast.openLibrary.detail"));
          }
        }),
      )
      .then((stop) => {
        if (disposed) stop();
        else unlisten = stop;
      })
      .catch((error) => {
        if (!disposed) notify(t("toast.dragInitFailed.title"), String(error), "error");
      });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [notify, t]);

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
      notify(t("toast.logsReadFailed.title"), String(error), "error");
    }
  }, [notify, t]);

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
            notify(
              t("toast.updateUnconfigured.title"),
              t("toast.updateUnconfigured.detail"),
            );
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
          notify(
            t("toast.upToDate.title"),
            t("toast.upToDate.detail", { version: result.currentVersion }),
            "success",
          );
        }
      } catch (error) {
        const message = String(error);
        setUpdateError(message);
        setUpdatePhase("error");
        if (!silent) notify(t("toast.updateCheckFailed.title"), message, "error");
      }
    },
    [notify, t],
  );

  useEffect(() => {
    if (!snapshot || bootUpdateChecked.current) return;
    bootUpdateChecked.current = true;
    void checkForUpdate(true);
  }, [checkForUpdate, snapshot]);

  useEffect(() => {
    if (section === "logs") void refreshLogs();
  }, [refreshLogs, section]);

  // 云源线路一改，上一份目录就不再是"当前目录"：清空它，避免旧条数继续挂在横幅上。
  const cloudSourcesKey = snapshot?.settings.cloud.baseUrls.join("\n") ?? "";
  useEffect(() => {
    cloudSourcesRevision.current += 1;
    cloudAutoStartedFor.current = "";
    setCloudMods([]);
    setCloudLoaded(false);
    setCloudError(null);
    setCloudAttempt(0);
    setCloudManualOnly(false);
  }, [cloudSourcesKey]);

  const loadCloudCatalog = useCallback(async (mode: "auto" | "manual") => {
    const current = snapshotRef.current;
    if (!current || cloudRequestActive.current) return;
    if (current.settings.cloud.baseUrls.length === 0) {
      setCloudMods([]);
      setCloudError(null);
      setCloudLoaded(true);
      setCloudManualOnly(false);
      return;
    }

    const revision = cloudSourcesRevision.current;
    cloudRequestActive.current = true;
    setCloudLoading(true);
    setCloudError(null);
    setCloudAttempt(0);
    if (mode === "auto") setCloudManualOnly(false);
    try {
      const outcome = await runCloudCatalogAttempts(() => api.fetchCloudCatalog(), {
        maxAttempts: mode === "auto" ? CLOUD_AUTO_ATTEMPTS : 1,
        onAttempt: (attempt) => {
          if (revision === cloudSourcesRevision.current) setCloudAttempt(attempt);
        },
      });
      if (revision !== cloudSourcesRevision.current) return;
      setCloudMods(outcome.result);
      setCloudLoaded(true);
      setCloudManualOnly(false);
    } catch (error) {
      if (revision !== cloudSourcesRevision.current) return;
      setCloudError(String(error));
      setCloudManualOnly(true);
    } finally {
      cloudRequestActive.current = false;
      setCloudLoading(false);
    }
  }, []);

  // 首次进入云端页自动尝试 4 次；失败后只接受用户手动重试，避免循环请求。
  useEffect(() => {
    if (section !== "cloud" || !snapshot) return;
    if (snapshot.settings.cloud.baseUrls.length === 0) {
      setCloudMods([]);
      setCloudError(null);
      setCloudLoaded(true);
      setCloudManualOnly(false);
      return;
    }
    if (cloudLoading || cloudLoaded || cloudManualOnly) return;
    if (cloudAutoStartedFor.current === cloudSourcesKey) return;
    cloudAutoStartedFor.current = cloudSourcesKey;
    void loadCloudCatalog("auto");
  }, [
    cloudLoaded,
    cloudLoading,
    cloudManualOnly,
    cloudSourcesKey,
    loadCloudCatalog,
    section,
    snapshot,
  ]);

  function changeTheme(nextTheme: ThemeMode) {
    setThemeState(nextTheme);
    applyTheme(nextTheme);
    setSnapshot((current) =>
      current
        ? { ...current, settings: { ...current.settings, theme: nextTheme } }
        : current,
    );
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
      notify(
        t("toast.scanDone.title"),
        t("toast.scanDone.detail", { count: next.mods.length }),
        "success",
      );
    } catch (error) {
      notify(t("toast.scanFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
    }
  }

  async function handleImport() {
    const paths = await chooseFiles();
    if (paths.length === 0) {
      if (!isTauri()) {
        notify(t("toast.browserPreview.title"), t("toast.browserPreview.detail"));
      }
      return;
    }
    await importPaths(paths);
  }

  async function handleToggle(id: string, enabled: boolean) {
    if (!snapshot) return;
    const revision = (toggleRevisions.current.get(id) ?? 0) + 1;
    toggleRevisions.current.set(id, revision);
    setSnapshot((current) =>
      current
        ? {
            ...current,
            mods: current.mods.map((mod) =>
              mod.id === id ? { ...mod, enabled } : mod,
            ),
          }
        : current,
    );
    try {
      const next = await api.setModEnabled(id, enabled);
      if (toggleRevisions.current.get(id) === revision) {
        setSnapshot(next);
      }
    } catch (error) {
      if (toggleRevisions.current.get(id) === revision) {
        setSnapshot((current) =>
          current
            ? {
                ...current,
                mods: current.mods.map((mod) =>
                  mod.id === id ? { ...mod, enabled: !enabled } : mod,
                ),
              }
            : current,
        );
        notify(t("toast.statusSaveFailed.title"), String(error), "error");
      }
    }
  }

  async function handleToggleMany(ids: string[], enabled: boolean) {
    if (!snapshot || ids.length === 0) return;
    const requested = new Set(ids);
    const previous = snapshot;
    setSnapshot({
      ...snapshot,
      mods: snapshot.mods.map((mod) =>
        requested.has(mod.id) ? { ...mod, enabled } : mod,
      ),
    });
    try {
      const next = await api.setModsEnabled(ids, enabled);
      setSnapshot(next);
      notify(
        t(
          enabled
            ? "toast.bulkEnabled.title"
            : "toast.bulkDisabled.title",
          { count: ids.length },
        ),
        undefined,
        "success",
      );
    } catch (error) {
      setSnapshot(previous);
      notify(t("toast.bulkToggleFailed.title"), String(error), "error");
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
      notify(t("toast.orderSaveFailed.title"), String(error), "error");
    }
  }

  async function handleEdit(id: string, tags: string[], notes: string) {
    try {
      setSnapshot(await api.updateModMetadata(id, tags, notes));
      notify(t("toast.metadataSaved.title"), undefined, "success");
    } catch (error) {
      notify(t("toast.saveFailed.title"), String(error), "error");
    }
  }

  async function handleDelete(id: string): Promise<boolean> {
    const target = snapshot?.mods.find((mod) => mod.id === id);
    if (!snapshot || !target) return false;
    if (snapshot.gameStatus.running) {
      notify(t("inspector.deleteRunning"), undefined, "error");
      return false;
    }
    try {
      const next = await api.deleteMod(id);
      setSnapshot(next);
      setSelectedId((current) =>
        next.mods.some((mod) => mod.id === current)
          ? current
          : [...next.mods].sort((a, b) => a.loadOrder - b.loadOrder)[0]?.id ?? null,
      );
      notify(
        t("inspector.deleteSuccessTitle"),
        t("inspector.deleteSuccessDetail", { name: target.name }),
        "success",
      );
      return true;
    } catch (error) {
      notify(t("inspector.deleteErrorTitle"), String(error), "error");
      return false;
    }
  }

  async function handleRename(id: string, newName: string): Promise<string | null> {
    try {
      const result = await api.renameMod(id, newName);
      setSnapshot(result.snapshot);
      setSelectedId(result.id);
      notify(
        t("toast.modRenamed.title"),
        t("toast.modRenamed.detail", { name: result.name }),
        "success",
      );
      return null;
    } catch (error) {
      return String(error);
    }
  }

  async function handleSaveConflictWinners(
    winners: Record<string, string>,
  ): Promise<boolean> {
    try {
      setSnapshot(await api.saveConflictWinners(winners));
      notify(
        t("toast.conflictSaved.title"),
        t("toast.conflictSaved.detail"),
        "success",
      );
      return true;
    } catch (error) {
      notify(t("toast.conflictSaveFailed.title"), String(error), "error");
      return false;
    }
  }

  async function handleMergeConflicts() {
    if (!snapshot || snapshot.gameStatus.running || busy) return;
    setBusy(true);
    setConflictMergeBusy(true);
    try {
      const result = await api.prepareConflictMerge();
      notify(
        t("toast.conflictMergeDone.title"),
        result.message,
        result.required ? "success" : "default",
      );
    } catch (error) {
      notify(t("toast.conflictMergeFailed.title"), String(error), "error");
    } finally {
      setConflictMergeBusy(false);
      setBusy(false);
    }
  }

  async function handleLaunch() {
    // 连点会发出两次 launch_game：Rust 侧有启动互斥，前端也不该重复排队。
    if (busy || !snapshot || snapshot.gameStatus.running) return;
    if (!snapshot.settings.scumInstallPath.trim()) {
      notify(
        t("toast.clientPathMissing.title"),
        t("toast.clientPathMissing.detail"),
        "error",
      );
      setSection("settings");
      return;
    }
    setBusy(true);
    try {
      const status = await api.launchGame("client");
      setSnapshot((current) =>
        current ? { ...current, gameStatus: status } : current,
      );
      notify(t("toast.gameStarted.title"), t("toast.gameStarted.detail"), "success");
    } catch (error) {
      notify(t("toast.launchFailed.title"), String(error), "error");
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
      notify(
        t("toast.gameClosed.title"),
        t(
          snapshot.settings.keepDeployedModsOnExit
            ? "toast.gameClosed.keptDetail"
            : "toast.gameClosed.detail",
        ),
        "success",
      );
    } catch (error) {
      notify(t("toast.closeFailed.title"), String(error), "error");
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
      if (saved.language !== languageRef.current) {
        setLanguageState(saved.language);
        languageRef.current = saved.language;
        storeLanguage(saved.language);
        void loadLocale(saved.language).catch(() => setLocaleMessages({}));
      }
      notify(t("toast.settingsSaved.title"), undefined, "success");
    } catch (error) {
      notify(t("toast.settingsSaveFailed.title"), String(error), "error");
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
        notify(t("toast.launchOptionsSaveFailed.title"), String(error), "error");
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
      notify(t("toast.installerStarted.title"), result.message, "success");
    } catch (error) {
      const message = String(error);
      setUpdateError(message);
      setUpdatePhase("error");
      notify(t("toast.installUpdateFailed.title"), message, "error");
    }
  }

  async function handleDetectPaths() {
    try {
      return await api.detectPaths();
    } catch (error) {
      notify(t("toast.pathDetectFailed.title"), String(error), "error");
      return null;
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
      notify(t("toast.downloadDone.title"), result.message, "success");
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
        notify(t("toast.libraryRefreshFailed.title"), String(error), "error");
      }
    } catch (error) {
      const message = String(error);
      notify(t("toast.downloadFailed.title"), message, "error");
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
      setSftpScan(null);
      setSftpScanAccountId(null);
      setRemoteNotes({});
      setRemoteConflicts(null);
      setRemoteConflictProgress(null);
      setRemoteFiles([]);
      notify(t("toast.sftpSaved.title"), t("toast.sftpSaved.detail"), "success");
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.accountSaveFailed.title"), String(error), "error");
    }
  }

  async function handleTestSftp(accountId: string, silent = false) {
    setServerError(null);
    setBusy(true);
    try {
      const result = await api.testSftpConnection(accountId);
      if (result.requiresTrust && result.hostKeyFingerprint) {
        setSftpScan(null);
        setSftpScanAccountId(null);
        setRemoteNotes({});
        setRemoteConflicts(null);
        setRemoteConflictProgress(null);
        setSftpTrustPrompt({
          accountId,
          fingerprint: result.hostKeyFingerprint,
          message: result.message,
        });
        notify(
          t("toast.hostTrustRequired.title"),
          t("toast.hostTrustRequired.detail"),
        );
        return;
      }
      setSftpTrustPrompt(null);
      if (!result.ok) throw new Error(result.message);
      setSnapshot(await api.getSnapshot());
      setSftpScan(result);
      setSftpScanAccountId(accountId);
      sftpAccountRef.current = accountId;
      // 先给一个空报告，模组库的“服务器模组”标签立刻可用；冲突分析在后台补上。
      setRemoteConflicts({
        groups: [],
        analyzedMods: 0,
        skippedMods: 0,
        message: t("serverLibrary.conflictsNotAnalyzed"),
      });
      setRemoteConflictProgress(null);
      try {
        setRemoteNotes(await api.getSftpRemoteNotes(accountId));
      } catch {
        setRemoteNotes({});
      }
      if (!silent) notify(t("toast.connectionDone.title"), result.message, "success");
      if (result.detectedModsPath) {
        await handleLoadRemoteFiles(result.detectedModsPath);
      } else {
        setRemoteFiles([]);
      }
      // 不在这里自动下载全量服务器模组；等用户真正打开“服务器模组”时再分析。
      analyzedAccountRef.current = null;
    } catch (error) {
      setSftpScan(null);
      setSftpScanAccountId(null);
      sftpAccountRef.current = null;
      setRemoteNotes({});
      setRemoteConflicts(null);
      setRemoteConflictProgress(null);
      setServerError(String(error));
      notify(t("toast.sftpFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
    }
  }

  async function analyzeRemoteConflictsInBackground(accountId: string) {
    const token = ++conflictRequestRef.current;
    analyzedAccountRef.current = accountId;
    setRemoteConflictLoading(true);
    try {
      const report = await api.analyzeSftpConflicts(accountId);
      if (token !== conflictRequestRef.current) return;
      setRemoteConflicts(report);
      analyzedAccountRef.current = accountId;
    } catch (error) {
      if (token !== conflictRequestRef.current) return;
      // 失败后允许下次切回服务器标签时重试；空报告仍让标签保持可用。
      analyzedAccountRef.current = null;
      setServerError(String(error));
    } finally {
      if (token === conflictRequestRef.current) setRemoteConflictLoading(false);
    }
  }

  async function handleTrustSftpHost() {
    if (!sftpTrustPrompt) return;
    setServerError(null);
    try {
      await api.trustSftpHost(sftpTrustPrompt.accountId, sftpTrustPrompt.fingerprint);
      const accountId = sftpTrustPrompt.accountId;
      setSftpTrustPrompt(null);
      notify(t("toast.hostTrusted.title"), t("toast.hostTrusted.detail"), "success");
      await handleTestSftp(accountId);
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.hostTrustSaveFailed.title"), String(error), "error");
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

  async function handleDownloadSftpFile(
    accountId: string,
    path: string,
    name: string,
  ) {
    const localPath = await chooseSavePath(name);
    if (!localPath) return;
    setBusy(true);
    try {
      const result = await api.downloadSftpFile(accountId, path, localPath);
      notify(t("toast.downloadDone.title"), result.message, "success");
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.downloadFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
    }
  }

  async function handleUpload(accountId: string, kind: SftpUploadKind) {
    const selected =
      kind === "pak"
        ? await chooseServerPakFiles()
        : await chooseDirectory().then((path) => (path ? [path] : []));
    if (selected.length === 0) {
      notify(t("toast.noServerMods.title"), t("toast.noServerMods.detail"));
      return;
    }
    setBusy(true);
    uploadActiveRef.current = true;
    setUploadProgress({
      file: "",
      completedFiles: 0,
      totalFiles: selected.length,
      completedBytes: 0,
      totalBytes: 0,
      message: kind === "pak" ? t("serverLibrary.uploadingPak") : t("serverLibrary.uploadingUe4ss"),
    });
    try {
      const result = await api.uploadServerMods(accountId, kind, selected);
      notify(t("toast.uploadDone.title"), result.message, "success");
      await handleTestSftp(accountId, true);
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.uploadFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
      uploadActiveRef.current = false;
      setUploadProgress(null);
    }
  }

  async function handleRenameSftpEntry(
    accountId: string,
    path: string,
    newName: string,
  ): Promise<string | null> {
    setBusy(true);
    try {
      const result = await api.renameSftpEntry(accountId, path, newName);
      notify(t("toast.remoteRenameDone.title"), result.message, "success");
      await handleTestSftp(accountId, true);
      return result.path;
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.remoteRenameFailed.title"), String(error), "error");
      return null;
    } finally {
      setBusy(false);
    }
  }

  async function handleDeleteSftpEntry(accountId: string, path: string): Promise<boolean> {
    setBusy(true);
    try {
      const result = await api.deleteSftpEntry(accountId, path);
      notify(t("toast.remoteDeleteDone.title"), result.message, "success");
      await handleTestSftp(accountId, true);
      return true;
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.remoteDeleteFailed.title"), String(error), "error");
      return false;
    } finally {
      setBusy(false);
    }
  }

  async function handleMkdirSftpEntry(
    accountId: string,
    targetPath: string,
  ): Promise<boolean> {
    setBusy(true);
    try {
      const result = await api.mkdirSftpEntry(accountId, targetPath);
      notify(t("toast.remoteMkdirDone.title"), result.message, "success");
      await handleTestSftp(accountId, true);
      return true;
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.remoteMkdirFailed.title"), String(error), "error");
      return false;
    } finally {
      setBusy(false);
    }
  }

  async function handleMoveSftpEntry(
    accountId: string,
    path: string,
    newPath: string,
  ): Promise<boolean> {
    setBusy(true);
    try {
      const result = await api.moveSftpEntry(accountId, path, newPath);
      notify(t("toast.remoteMoveDone.title"), result.message, "success");
      await handleTestSftp(accountId, true);
      return true;
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.remoteMoveFailed.title"), String(error), "error");
      return false;
    } finally {
      setBusy(false);
    }
  }

  async function handleDownloadSftpModToLibrary(
    accountId: string,
    path: string,
  ) {
    setBusy(true);
    try {
      setSnapshot(await api.downloadSftpModToLibrary(accountId, path));
      notify(
        t("toast.serverImportDone.title"),
        t("toast.serverImportDone.detail"),
        "success",
      );
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.serverImportFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
    }
  }

  async function handleSwitchSftpAccount(accountId: string) {
    if (!snapshot || snapshot.settings.activeSftpAccountId === accountId) return;
    try {
      const saved = await api.saveSettings({
        ...snapshot.settings,
        activeSftpAccountId: accountId,
      });
      setSnapshot((current) =>
        current ? { ...current, settings: saved } : current,
      );
    } catch (error) {
      notify(t("toast.settingsSaveFailed.title"), String(error), "error");
      return;
    }
    await handleTestSftp(accountId);
  }

  async function handleSaveRemoteNote(
    accountId: string,
    path: string,
    note: string,
  ): Promise<boolean> {
    try {
      setRemoteNotes(await api.saveSftpRemoteNote(accountId, path, note));
      notify(t("toast.remoteNoteSaved.title"), t("toast.remoteNoteSaved.detail"), "success");
      return true;
    } catch (error) {
      notify(t("toast.remoteNoteFailed.title"), String(error), "error");
      return false;
    }
  }

  async function handleAnalyzeSftpConflicts(accountId: string) {
    if (busy || remoteConflictLoading) return;
    setBusy(true);
    setRemoteConflictLoading(true);
    setRemoteConflictProgress(null);
    try {
      const report = await api.analyzeSftpConflicts(accountId);
      setRemoteConflicts(report);
      notify(
        t("toast.remoteConflictDone.title"),
        report.message,
        report.groups.length > 0 ? "default" : "success",
      );
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.remoteConflictFailed.title"), String(error), "error");
    } finally {
      setRemoteConflictLoading(false);
      setBusy(false);
    }
  }

  const serverLibraryViewRef = useRef<typeof serverLibraryView>(null);
  serverLibraryViewRef.current = serverLibraryView;
  const prepareTimer = useRef<number | null>(null);
  const prepareBusyRef = useRef(false);
  const serverLayoutRevision = useRef(0);

  function scheduleServerPrepare() {
    if (prepareTimer.current) window.clearTimeout(prepareTimer.current);
    const revision = serverLayoutRevision.current;
    prepareTimer.current = window.setTimeout(() => {
      const view = serverLibraryViewRef.current;
      if (!view || view.manifest || libraryMode !== "server") return;
      void runServerPrepare(view, revision);
    }, 900);
  }

  async function runServerPrepare(
    view: NonNullable<typeof serverLibraryView>,
    revision: number,
  ) {
    if (prepareBusyRef.current || view.manifest) return;
    prepareBusyRef.current = true;
    setServerPrepareBusy(true);
    try {
      const plan = await api.prepareSftpModLayout(
        view.accountId,
        view.state.order,
        serverLibraryDisabledPaths(view.state),
        view.state.deleted,
        view.state.winners,
      );
      // 分析期间布局可能已经上传（manifest 出现），此时结果作废，避免“已托管”又被
      // 一个陈旧的“等待上传”盖住。
      if (revision !== serverLayoutRevision.current || serverLibraryViewRef.current?.manifest) {
        return;
      }
      setServerPrepare(plan);
      // 缓存已经热了，再取一次冲突报告，让右侧冲突面板与融合结果同源。
      try {
        setRemoteConflicts(await api.analyzeSftpConflicts(view.accountId));
      } catch {
        // 冲突报告失败不影响上传按钮，prepare 结果已经是可信的。
      }
      if (plan.required) {
        notify(t("toast.serverPrepareReady.title"), plan.message, "default");
      }
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.serverPrepareFailed.title"), String(error), "error");
    } finally {
      prepareBusyRef.current = false;
      setServerPrepareBusy(false);
      // 分析过程中用户又改了布局：结果已过期，按最新状态再跑一轮。
      if (revision !== serverLayoutRevision.current) {
        scheduleServerPrepare();
      }
    }
  }

  function commitServerLibraryState(next: ServerLibraryState) {
    if (!activeServerAccountId || !sftpScan) return;
    const normalized = normalizeServerLibraryState(next, sftpScan);
    setServerLibraryState(normalized);
    storeServerLibraryState(activeServerAccountId, normalized, sftpScan);
    // 任何布局改动都会让上一轮融合结果过期，等后台重新分析完再允许上传。
    serverLayoutRevision.current += 1;
    setServerPrepare(null);
    scheduleServerPrepare();
  }

  function handleServerLibraryToggle(id: string, enabled: boolean) {
    const state = serverLibraryView?.state;
    if (!state || serverLibraryView?.manifest) return;
    commitServerLibraryState({
      ...state,
      enabled: { ...state.enabled, [id]: enabled },
    });
  }

  function handleServerLibraryToggleMany(ids: string[], enabled: boolean) {
    const state = serverLibraryView?.state;
    if (!state || serverLibraryView?.manifest) return;
    const nextEnabled = { ...state.enabled };
    for (const id of ids) {
      nextEnabled[id] = enabled;
    }
    commitServerLibraryState({ ...state, enabled: nextEnabled });
  }

  function handleServerLibraryReorder(ids: string[]) {
    const state = serverLibraryView?.state;
    if (!state || serverLibraryView?.manifest) return;
    commitServerLibraryState({ ...state, order: ids });
  }

  async function handleServerLibraryDelete(id: string): Promise<boolean> {
    const state = serverLibraryView?.state;
    if (!state || serverLibraryView?.manifest) return false;
    commitServerLibraryState({
      ...state,
      deleted: [...new Set([...state.deleted, id])],
    });
    notify(
      t("toast.serverDeletePending.title"),
      t("toast.serverDeletePending.detail"),
      "default",
    );
    return true;
  }

  async function handleServerLibraryUndoDeleted() {
    const state = serverLibraryView?.state;
    if (!state || serverLibraryView?.manifest) return;
    commitServerLibraryState({ ...state, deleted: [] });
    notify(
      t("toast.serverDeleteUndone.title"),
      t("toast.serverDeleteUndone.detail"),
      "success",
    );
  }

  async function handleServerLibraryEdit(
    id: string,
    _tags: string[],
    notes: string,
  ): Promise<boolean> {
    const state = serverLibraryView?.state;
    const accountId = serverLibraryView?.accountId;
    if (!state || !accountId || serverLibraryView?.manifest) return false;
    try {
      setRemoteNotes(await api.saveSftpRemoteNote(accountId, id, notes));
      notify(
        t("toast.remoteNoteSaved.title"),
        t("toast.serverNotePreparing.detail"),
        "success",
      );
      scheduleServerPrepare();
      return true;
    } catch (error) {
      notify(t("toast.remoteNoteFailed.title"), String(error), "error");
      return false;
    }
  }

  async function handleServerLibrarySaveWinners(
    winners: Record<string, string>,
  ): Promise<boolean> {
    const state = serverLibraryView?.state;
    if (!state || serverLibraryView?.manifest) return false;
    commitServerLibraryState({ ...state, winners });
    notify(
      t("toast.conflictSaved.title"),
      t("toast.conflictSaved.detail"),
      "success",
    );
    return true;
  }

  async function refreshServerLibrary(accountId: string) {
    serverLayoutRevision.current += 1;
    if (prepareTimer.current) {
      window.clearTimeout(prepareTimer.current);
      prepareTimer.current = null;
    }
    const result = await api.testSftpConnection(accountId);
    if (!result.ok) throw new Error(result.message);
    setSnapshot(await api.getSnapshot());
    setSftpScan(result);
    setSftpScanAccountId(accountId);
    setSftpTrustPrompt(null);
    setRemoteConflictProgress(null);
    setServerPrepare(null);
    setRemoteConflictLoading(true);
    try {
      const report = await api.analyzeSftpConflicts(accountId);
      setRemoteConflicts(report);
      try {
        setRemoteNotes(await api.getSftpRemoteNotes(accountId));
      } catch {
        setRemoteNotes({});
      }
      if (result.detectedModsPath) {
        setRemoteFiles(await api.listRemoteFiles(result.detectedModsPath));
      } else {
        setRemoteFiles([]);
      }
    } finally {
      setRemoteConflictLoading(false);
    }
  }

  async function handleServerLibraryRefresh() {
    const accountId = serverLibraryView?.accountId;
    if (!accountId || busy) return;
    setBusy(true);
    setServerError(null);
    try {
      await refreshServerLibrary(accountId);
      notify(t("toast.serverLibraryRefreshed.title"), undefined, "success");
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.serverLibraryRefreshFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
    }
  }

  async function handleOpenConfig(modId: string) {
    const mod = snapshot?.mods.find((item) => item.id === modId);
    if (!mod) return;
    try {
      const files = await api.listModConfigFiles(modId);
      if (files.length === 0) {
        notify(t("config.empty"), mod.name, "default");
        return;
      }
      setConfigEditor({ modId, modName: mod.name, files });
    } catch (error) {
      notify(t("config.loadFailed"), String(error), "error");
    }
  }

  async function handleApplyServerLibrary() {
    const view = serverLibraryView;
    if (!view || busy) return;
    setBusy(true);
    setServerError(null);
    setRemoteConflictLoading(true);
    setRemoteConflictProgress(null);
    setServerUploading(true);
    notify(
      t("toast.serverUploadStarted.title"),
      t("toast.serverUploadStarted.detail"),
      "default",
    );
    try {
      const result: SftpApplyResult = await api.applySftpModLayout(
        view.accountId,
        view.state.order,
        serverLibraryDisabledPaths(view.state),
        sftpScan ? serverLibraryReleasedPaths(view.state, sftpScan) : [],
        view.state.deleted,
        view.state.winners,
      );
      notify(t("toast.serverLibraryApplied.title"), result.message, "success");
      // 上传完成后任何未触发的融合计划都过期了，取消它，避免旧计划盖住“已托管”状态。
      serverLayoutRevision.current += 1;
      if (prepareTimer.current) {
        window.clearTimeout(prepareTimer.current);
        prepareTimer.current = null;
      }
      setServerPrepare(null);
      await refreshServerLibrary(view.accountId);
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.serverLibraryApplyFailed.title"), String(error), "error");
    } finally {
      setRemoteConflictLoading(false);
      setServerUploading(false);
      setBusy(false);
      // 命令结束就收掉操作条：后端若因断连漏发 finished，界面也不会一直转。
      setOperations((state) => clearOperation(state));
    }
  }

  function handleRestoreServerLibrary() {
    const accountId = serverLibraryView?.accountId;
    if (!accountId || busy) return;
    // 恢复会移动服务器上的文件，必须二次确认。
    setServerRestoreConfirm(accountId);
  }

  async function performRestoreServerLibrary() {
    const accountId = serverRestoreConfirm;
    if (!accountId) return;
    setServerRestoreConfirm(null);
    setBusy(true);
    setServerError(null);
    try {
      const result = await api.restoreSftpModLayout(accountId);
      notify(t("toast.serverLibraryRestored.title"), result.message, "success");
      setServerPrepare(null);
      await refreshServerLibrary(accountId);
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.serverLibraryRestoreFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
      setOperations((state) => clearOperation(state));
    }
  }

  async function handleReclaimPendingLinks() {
    // 回收可能要等被占用的文件释放（单文件最长 30s）：订阅后端进度，先把「正在等」告诉用户。
    let unlisten: (() => void) | null = null;
    try {
      if (isTauri()) {
        const { listen } = await import("@tauri-apps/api/event");
        unlisten = await listen<{ message?: string; waitedMs?: number }>(
          "reclaim-progress",
          (event) => {
            const payload = event.payload;
            if (payload?.message && (payload.waitedMs ?? 0) === 0) {
              notify(t("toast.linksReclaimed.title"), payload.message);
            }
          },
        );
      }
      const removed = await api.reclaimPendingLinks();
      setPendingLinks([]);
      notify(
        t("toast.linksReclaimed.title"),
        t("toast.linksReclaimed.detail", { count: removed }),
        "success",
      );
    } catch (error) {
      notify(t("toast.linksReclaimFailed.title"), String(error), "error");
    } finally {
      unlisten?.();
    }
  }

  function handleDismissPendingLinks() {
    setPendingLinks([]);
    void api.dismissPendingLinks();
  }

  async function handleDisableCrashSuspect(modId: string) {
    try {
      setSnapshot(await api.setModEnabled(modId, false));
      setCrashReport((current) =>
        current
          ? { ...current, suspects: current.suspects.filter((item) => item.modId !== modId) }
          : current,
      );
      notify(
        t("toast.crashModDisabled.title"),
        t("toast.crashModDisabled.detail"),
        "success",
      );
    } catch (error) {
      notify(t("toast.crashDisableFailed.title"), String(error), "error");
    }
  }

  function handleCloseCrash() {
    setCrashReport(null);
    void api.dismissCrash();
  }

  async function handleChooseDirectory(kind: "client" | "server") {
    const path = await chooseDirectory();
    if (!path) {
      notify(
        t("toast.directoryNotSelected.title"),
        t("toast.directoryNotSelected.detail", {
          kind: t(kind === "client" ? "common.client" : "common.server"),
        }),
      );
    }
    return path;
  }

  if (!snapshot) {
    if (bootError) {
      return (
        <div className="boot-screen">
          <span className="boot-mark">SM</span>
          <div>
            <b>{t("toast.loadFailed.title")}</b>
            <span>{bootError}</span>
          </div>
          <Button onClick={() => setBootAttempt((value) => value + 1)}>
            {t("common.retry")}
          </Button>
        </div>
      );
    }
    return (
      <div className="boot-screen">
        <span className="boot-mark">SM</span>
        <div>
          <b>SCUM MOD DESK</b>
          <span>{t("app.loadingData")}</span>
        </div>
        <i />
      </div>
    );
  }

  const enabled = snapshot.mods.filter((mod) => mod.enabled);
  const deployedBytes = enabled.reduce((sum, mod) => sum + mod.fileSize, 0);

  return (
    <I18nProvider
      language={language}
      overrides={localeMessages}
      onLanguageChange={(next) => void changeLanguage(next)}
    >
      <AppShell
        section={section}
        theme={theme}
        gameStatus={snapshot.gameStatus}
        hasClientPath={Boolean(snapshot.settings.scumInstallPath.trim())}
        enabledCount={enabled.length}
        deployedSize={formatBytes(deployedBytes)}
        lastChecked={formatClock(snapshot.lastScannedAt, language)}
        updateAvailable={updatePhase === "available"}
        updateVersion={updateInfo?.version ?? null}
        maximized={windowMaximized}
        statusSlot={
          <OperationDock current={operations.current} history={operations.history} />
        }
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
              mode={libraryMode}
              onModeChange={(next) => {
                if (next === "server" && !serverLibraryView) return;
                setLibraryMode(next);
                setSearch("");
                setSelectedId(null);
              }}
              server={
                serverLibraryView
                  ? ({
                      snapshot: serverLibraryView.snapshot,
                      state: serverLibraryView.state,
                      manifest: serverLibraryView.manifest,
                      prepare: serverPrepare,
                      preparing: serverPrepareBusy,
                      analyzing: remoteConflictLoading && !serverUploading,
                      uploading: serverUploading,
                      busy,
                      operation: operations.current,
                      onRefresh: () => void handleServerLibraryRefresh(),
                      onPrepare: () => {
                        const view = serverLibraryViewRef.current;
                        if (!view) return;
                        serverLayoutRevision.current += 1;
                        setServerPrepare(null);
                        void runServerPrepare(view, serverLayoutRevision.current);
                      },
                      onToggle: handleServerLibraryToggle,
                      onToggleMany: handleServerLibraryToggleMany,
                      onReorder: handleServerLibraryReorder,
                      onSaveConflictWinners: handleServerLibrarySaveWinners,
                      onEdit: handleServerLibraryEdit,
                      onDelete: handleServerLibraryDelete,
                      onUndoDeleted: handleServerLibraryUndoDeleted,
                      onApply: () => setServerPlanOpen(true),
                      onRestore: () => void handleRestoreServerLibrary(),
                    } satisfies ServerLibraryView)
                  : null
              }
              search={search}
              onSearchChange={setSearch}
              onScan={handleScan}
              onImport={handleImport}
              onToggle={handleToggle}
              onToggleMany={handleToggleMany}
              onRename={handleRename}
              onReorder={handleReorder}
              onEdit={handleEdit}
              onDelete={handleDelete}
              onSaveConflictWinners={handleSaveConflictWinners}
              onLaunch={handleLaunch}
              onKill={handleKill}
              onOpenFolder={(id) => void api.openModFolder(id)}
              onOpenConfig={(id) => void handleOpenConfig(id)}
              onLaunchOptionsChange={handleLaunchOptionsChange}
              onNavigate={setSection}
              gameStatus={snapshot.gameStatus}
              selectedId={selectedId}
              onSelect={setSelectedId}
              fileDragActive={fileDragActive}
              busy={busy}
              mergeBusy={conflictMergeBusy}
              onMergeConflicts={() => void handleMergeConflicts()}
            />
          ) : null}
          {section === "cloud" ? (
            <CloudScreen
              mods={cloudMods}
              loading={cloudLoading}
              downloads={cloudDownloads}
              error={cloudError}
              loaded={cloudLoaded}
              attempt={cloudAttempt}
              autoAttempts={CLOUD_AUTO_ATTEMPTS}
              manualOnly={cloudManualOnly}
              configured={snapshot.settings.cloud.baseUrls.length > 0}
              edition={appInfo?.edition ?? "public"}
              maxSegments={snapshot.settings.cloud.maxDownloadSegments}
              onRefresh={() => void loadCloudCatalog("manual")}
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
              scan={sftpScanAccountId === snapshot.settings.activeSftpAccountId ? sftpScan : null}
              connectedAccountId={sftpScanAccountId}
              notes={remoteNotes}
              conflicts={remoteConflicts}
              conflictLoading={remoteConflictLoading}
              conflictProgress={remoteConflictProgress}
              uploadProgress={uploadProgress}
              onSaveAccount={(account, password) =>
                void handleSaveSftpAccount(account, password)
              }
              onTestAccount={(id) => void handleTestSftp(id)}
              onTrustHost={() => void handleTrustSftpHost()}
              onDismissTrust={() => setSftpTrustPrompt(null)}
              onLoadFiles={(_id, path) => void handleLoadRemoteFiles(path)}
              onDownload={handleDownloadSftpFile}
              onUpload={(id, kind) => handleUpload(id, kind)}
              onRename={handleRenameSftpEntry}
              onDelete={handleDeleteSftpEntry}
              onSaveNote={handleSaveRemoteNote}
              onAnalyzeConflicts={handleAnalyzeSftpConflicts}
              onOpenSettings={() => setSection("settings")}
              onMkdir={handleMkdirSftpEntry}
              onMove={handleMoveSftpEntry}
              onDownloadToLibrary={handleDownloadSftpModToLibrary}
              onSwitchAccount={(id) => void handleSwitchSftpAccount(id)}
            />
          ) : null}
          {section === "backups" ? (
            <BackupsScreen
              onNotify={(title, detail, tone) => notify(title, detail, tone)}
              onRestored={() => {
                void api
                  .scanLibrary()
                  .then(setSnapshot)
                  .catch(() => undefined);
              }}
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
              language={language}
              edition={appInfo?.edition ?? "public"}
              version={appInfo?.version ?? null}
              dataRoot={appInfo?.dataRoot ?? null}
              onSave={(settings) => void handleSaveSettings(settings)}
              onDetectPaths={handleDetectPaths}
              onLaunchOptionsChange={handleLaunchOptionsChange}
              onThemePreview={changeTheme}
              onLanguagePreview={(next) => void changeLanguage(next)}
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
      {pendingImport ? (
        <ImportConflictDialog
          conflicts={pendingImport.conflicts}
          busy={busy}
          onClose={handleKeepExistingImport}
          onConfirm={() => void handleReplaceImport()}
        />
      ) : null}
      {pendingLinks.length > 0 ? (
        <Modal
          title={t("links.title")}
          description={t("links.description")}
          onClose={handleDismissPendingLinks}
          footer={
            <>
              <Button onClick={handleDismissPendingLinks}>
                {t("links.keep")}
              </Button>
              <Button
                variant="primary"
                icon="refresh"
                onClick={() => void handleReclaimPendingLinks()}
              >
                {t("links.reclaim")}
              </Button>
            </>
          }
        >
          <ul className="pending-link-list">
            {pendingLinks.map((link) => (
              <li key={link.path}>
                <b>{link.path}</b>
                <span>→ {link.target}</span>
                <small>
                  {link.kind === "pak"
                    ? t("links.kind.pak")
                    : link.kind === "ue4ss"
                      ? t("links.kind.ue4ss")
                      : t("links.kind.ue4ssMods")}
                </small>
              </li>
            ))}
          </ul>
        </Modal>
      ) : null}
      {configEditor ? (
        <ConfigEditorDialog
          modName={configEditor.modName}
          files={configEditor.files}
          load={(relativePath) =>
            api
              .readModConfigFile(configEditor.modId, relativePath)
              .then((file) => file.content)
          }
          save={async (relativePath, content) => {
            try {
              await api.writeModConfigFile(configEditor.modId, relativePath, content);
              notify(t("config.saved"), configEditor.modName, "success");
              return true;
            } catch (error) {
              notify(t("config.saveFailed"), String(error), "error");
              return false;
            }
          }}
          onClose={() => setConfigEditor(null)}
        />
      ) : null}
      {serverPlanOpen && serverPrepare && serverLibraryView ? (
        <ServerUploadPlanDialog
          prepare={serverPrepare}
          state={serverLibraryView.state}
          mods={serverLibraryView.snapshot.mods}
          busy={serverUploading}
          onClose={() => setServerPlanOpen(false)}
          onConfirm={() => {
            setServerPlanOpen(false);
            void handleApplyServerLibrary();
          }}
        />
      ) : null}
      {serverRestoreConfirm ? (
        <Modal
          title={t("serverLibrary.restore")}
          description={t("serverLibrary.confirmRestore")}
          onClose={() => setServerRestoreConfirm(null)}
          footer={
            <>
              <Button variant="ghost" onClick={() => setServerRestoreConfirm(null)}>
                {t("common.cancel")}
              </Button>
              <Button variant="danger" onClick={() => void performRestoreServerLibrary()}>
                {t("serverLibrary.restore")}
              </Button>
            </>
          }
        >
          <p>{t("serverLibrary.managedHint")}</p>
        </Modal>
      ) : null}
      {crashReport ? (
        <Modal
          title={t("crash.title")}
          description={crashReport.summary}
          onClose={handleCloseCrash}
          footer={
            <Button onClick={handleCloseCrash}>{t("crash.dismiss")}</Button>
          }
        >
          <div className="crash-report">
            {crashReport.suspects.length > 0 ? (
              <section>
                <b>{t("crash.suspects")}</b>
                <ul className="crash-suspect-list">
                  {crashReport.suspects.map((suspect) => (
                    <li key={suspect.modId}>
                      <div>
                        <strong>{suspect.name}</strong>
                        <span>{suspect.reason}</span>
                      </div>
                      <Button
                        size="sm"
                        variant="danger"
                        onClick={() => void handleDisableCrashSuspect(suspect.modId)}
                      >
                        {t("crash.disable")}
                      </Button>
                    </li>
                  ))}
                </ul>
              </section>
            ) : null}
            <section>
              <b>{t("crash.suggestions")}</b>
              <ol>
                {crashReport.suggestions.map((suggestion) => (
                  <li key={suggestion}>{suggestion}</li>
                ))}
              </ol>
            </section>
            {crashReport.evidence.length > 0 ? (
              <details>
                <summary>{t("crash.evidence")}</summary>
                <pre>{crashReport.evidence.join("\n")}</pre>
              </details>
            ) : null}
            {crashReport.logPath ? (
              <code className="crash-log-path">{crashReport.logPath}</code>
            ) : null}
          </div>
        </Modal>
      ) : null}
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
    </I18nProvider>
  );
}
