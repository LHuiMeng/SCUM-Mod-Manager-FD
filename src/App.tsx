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
  SftpManagedManifest,
  SftpUploadKind,
  ThemeMode,
  ToastMessage,
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
import { CLOUD_AUTO_ATTEMPTS, runCloudCatalogAttempts } from "./lib/cloudCatalog";
import {
  buildServerLibrarySnapshot,
  normalizeServerLibraryState,
  readStoredServerLibraryState,
  serverLibraryDisabledPaths,
  storeServerLibraryState,
  type ServerLibraryState,
} from "./lib/serverLibrary";
import { AppShell } from "./components/shell/AppShell";
import {
  LibraryScreen,
  type ServerLibraryView,
} from "./components/library/LibraryScreen";
import { ImportConflictDialog } from "./components/library/ImportConflictDialog";
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
  const [libraryMode, setLibraryMode] = useState<"local" | "server">("local");
  const [serverLibraryState, setServerLibraryState] =
    useState<ServerLibraryState | null>(null);
  const [updateInfo, setUpdateInfo] = useState<AppUpdateInfo | null>(null);
  const [updatePhase, setUpdatePhase] = useState<AppUpdatePhase>("idle");
  const [updateProgress, setUpdateProgress] = useState<AppUpdateProgress | null>(null);
  const [updateError, setUpdateError] = useState<string | null>(null);
  const [updateDialogOpen, setUpdateDialogOpen] = useState(false);
  const [fileDragActive, setFileDragActive] = useState(false);
  const [pendingImport, setPendingImport] = useState<PendingImport | null>(null);
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
      labels: {
        mergedName: t("serverLibrary.mergedName"),
        mergedTag: t("serverLibrary.mergedTag"),
        mergedDescription: (sources) =>
          t("serverLibrary.mergedDescription", {
            sources: sources.join("、"),
          }),
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
        notify(t("toast.loadFailed.title"), String(error), "error");
      });
    return () => {
      cancelled = true;
    };
  }, [loadLocale, notify]);

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

  async function handleLaunch() {
    if (!snapshot || snapshot.gameStatus.running) return;
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
      setRemoteConflicts(null);
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
    } catch (error) {
      setSftpScan(null);
      setSftpScanAccountId(null);
      setRemoteNotes({});
      setRemoteConflicts(null);
      setRemoteConflictProgress(null);
      setServerError(String(error));
      notify(t("toast.sftpFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
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
    try {
      const result = await api.uploadServerMods(accountId, kind, selected);
      notify(t("toast.uploadDone.title"), result.message, "success");
      await handleTestSftp(accountId, true);
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.uploadFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
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

  function commitServerLibraryState(next: ServerLibraryState) {
    if (!activeServerAccountId || !sftpScan) return;
    const normalized = normalizeServerLibraryState(next, sftpScan);
    setServerLibraryState(normalized);
    storeServerLibraryState(activeServerAccountId, normalized, sftpScan);
  }

  function handleServerLibraryToggle(id: string, enabled: boolean) {
    const state = serverLibraryView?.state;
    if (!state || serverLibraryView?.manifest) return;
    commitServerLibraryState({
      ...state,
      enabled: { ...state.enabled, [id]: enabled },
    });
  }

  function handleServerLibraryReorder(ids: string[]) {
    const state = serverLibraryView?.state;
    if (!state || serverLibraryView?.manifest) return;
    commitServerLibraryState({ ...state, order: ids });
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
    const result = await api.testSftpConnection(accountId);
    if (!result.ok) throw new Error(result.message);
    setSnapshot(await api.getSnapshot());
    setSftpScan(result);
    setSftpScanAccountId(accountId);
    setSftpTrustPrompt(null);
    setRemoteConflictProgress(null);
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

  async function handleApplyServerLibrary() {
    const view = serverLibraryView;
    if (!view || busy) return;
    setBusy(true);
    setServerError(null);
    setRemoteConflictLoading(true);
    setRemoteConflictProgress(null);
    try {
      const result: SftpApplyResult = await api.applySftpModLayout(
        view.accountId,
        view.state.order,
        serverLibraryDisabledPaths(view.state),
        view.state.winners,
      );
      notify(t("toast.serverLibraryApplied.title"), result.message, "success");
      await refreshServerLibrary(view.accountId);
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.serverLibraryApplyFailed.title"), String(error), "error");
    } finally {
      setRemoteConflictLoading(false);
      setBusy(false);
    }
  }

  async function handleRestoreServerLibrary() {
    const accountId = serverLibraryView?.accountId;
    if (!accountId || busy) return;
    setBusy(true);
    setServerError(null);
    try {
      const result = await api.restoreSftpModLayout(accountId);
      notify(t("toast.serverLibraryRestored.title"), result.message, "success");
      await refreshServerLibrary(accountId);
    } catch (error) {
      setServerError(String(error));
      notify(t("toast.serverLibraryRestoreFailed.title"), String(error), "error");
    } finally {
      setBusy(false);
    }
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
                      busy,
                      onRefresh: () => void handleServerLibraryRefresh(),
                      onToggle: handleServerLibraryToggle,
                      onReorder: handleServerLibraryReorder,
                      onSaveConflictWinners: handleServerLibrarySaveWinners,
                      onApply: () => void handleApplyServerLibrary(),
                      onRestore: () => void handleRestoreServerLibrary(),
                    } satisfies ServerLibraryView)
                  : null
              }
              search={search}
              onSearchChange={setSearch}
              onScan={handleScan}
              onImport={handleImport}
              onToggle={handleToggle}
              onReorder={handleReorder}
              onEdit={handleEdit}
              onDelete={handleDelete}
              onSaveConflictWinners={handleSaveConflictWinners}
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
