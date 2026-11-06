import { describe, expect, it } from "vitest";
import type {
  LibrarySnapshot,
  SftpConflictReport,
  SftpConnectionResult,
} from "../types";
import {
  buildServerLibrarySnapshot,
  normalizeServerLibraryState,
  serverLibraryDisabledPaths,
  serverLibraryReleasedPaths,
} from "./serverLibrary";

const scan: SftpConnectionResult = {
  ok: true,
  message: "",
  detectedModsPath: "/srv/mods",
  detectedUe4ssPath: "/srv/ue4ss",
  pakMods: [
    {
      name: "Alpha.pak",
      path: "/srv/mods/Alpha.pak",
      isDirectory: false,
      size: 100,
      modifiedAt: "2026-01-01T00:00:00Z",
    },
    {
      name: "Beta.pak",
      path: "/srv/mods/Beta.pak",
      isDirectory: false,
      size: 200,
      modifiedAt: "2026-01-02T00:00:00Z",
    },
  ],
  ue4ssMods: [],
  scannedDirectories: 1,
  homePath: "/home/test",
  hostKeyFingerprint: "SHA256:test",
  requiresTrust: false,
};

const report: SftpConflictReport = {
  groups: [
    {
      resourcePath: "SCUM/Content/Shared.uasset",
      owners: [
        { name: "Alpha.pak", path: "/srv/mods/Alpha.pak", kind: "pak" },
        { name: "Beta.pak", path: "/srv/mods/Beta.pak", kind: "pak" },
      ],
    },
  ],
  analyzedMods: 2,
  skippedMods: 0,
  message: "",
};

const base: LibrarySnapshot = {
  mods: [],
  conflicts: [],
  settings: {
    scumInstallPath: "",
    serverInstallPath: "",
    theme: "light",
    language: "zh-CN",
    keepDeployedModsOnExit: false,
    useDeployLinks: false,
    autoMergeConflicts: true,
    launchOptions: {
      log: false,
      fileOpenLog: true,
      noBattlEye: true,
      port: "7042",
    },
    cloud: { baseUrls: [], activeBaseUrl: "", maxDownloadSegments: 16 },
    sftpAccounts: [],
    activeSftpAccountId: null,
  },
  gameStatus: { running: false, mode: null, pid: null, startedAt: null },
  lastDeployedAt: null,
  lastScannedAt: null,
  localModsPath: "",
  clientModsPath: "",
};

describe("server library model", () => {
  it("normalizes order, enabled state, and disabled paths", () => {
    const state = normalizeServerLibraryState(
      {
        order: ["/srv/mods/Beta.pak", "/missing.pak"],
        enabled: { "/srv/mods/Beta.pak": false },
        winners: { shared: "/srv/mods/Alpha.pak" },
      },
      scan,
    );
    expect(state.order).toEqual([
      "/srv/mods/Beta.pak",
      "/srv/mods/Alpha.pak",
    ]);
    expect(serverLibraryDisabledPaths(state)).toEqual([
      "/srv/mods/Beta.pak",
    ]);
  });

  it("builds conflict groups and applies custom winners", () => {
    const state = normalizeServerLibraryState(
      {
        order: ["/srv/mods/Beta.pak", "/srv/mods/Alpha.pak"],
        enabled: {},
        winners: {
          "scum/content/shared.uasset": "/srv/mods/Beta.pak",
        },
      },
      scan,
    );
    const result = buildServerLibrarySnapshot({
      base,
      scan,
      report,
      state,
      manifest: null,
      labels: {
        mergedName: "Merged",
        mergedTag: "Merged",
        mergedDescription: (sources) => sources.join(", "),
        disabledTag: "Disabled",
        disabledDescription: "Disabled backup",
        deletedTag: "Deleted",
        deletedDescription: "Deleted backup",
      },
    });
    expect(result.snapshot.mods.map((mod) => mod.name)).toEqual([
      "Beta.pak",
      "Alpha.pak",
    ]);
    expect(result.snapshot.conflicts[0].defaultWinnerId).toBe(
      "/srv/mods/Alpha.pak",
    );
    expect(result.snapshot.conflicts[0].winnerId).toBe(
      "/srv/mods/Beta.pak",
    );
    expect(result.state.winners).toEqual({
      "scum/content/shared.uasset": "/srv/mods/Beta.pak",
    });
  });

  it("hides conflicts for disabled mods", () => {
    const state = normalizeServerLibraryState(
      {
        order: [],
        enabled: { "/srv/mods/Beta.pak": false },
        winners: {},
      },
      scan,
    );
    const result = buildServerLibrarySnapshot({
      base,
      scan,
      report,
      state,
      manifest: null,
      labels: {
        mergedName: "Merged",
        mergedTag: "Merged",
        mergedDescription: (sources) => sources.join(", "),
        disabledTag: "Disabled",
        disabledDescription: "Disabled backup",
        deletedTag: "Deleted",
        deletedDescription: "Deleted backup",
      },
    });
    expect(result.conflicts).toEqual([]);
  });

  it("marks the managed merged PAK and its sources", () => {
    const mergedScan: SftpConnectionResult = {
      ...scan,
      pakMods: [
        {
          name: "999_SCUM_Mod_Desk_Merged.pak",
          path: "/srv/mods/999_SCUM_Mod_Desk_Merged.pak",
          isDirectory: false,
          size: 300,
          modifiedAt: null,
        },
      ],
    };
    const result = buildServerLibrarySnapshot({
      base,
      scan: mergedScan,
      report: { groups: [], analyzedMods: 1, skippedMods: 0, message: "" },
      state: normalizeServerLibraryState(null, mergedScan),
      manifest: {
        version: 1,
        createdAt: "2026-01-03T00:00:00Z",
        mergedPath: "/srv/mods/999_SCUM_Mod_Desk_Merged.pak",
        mergedName: "999_SCUM_Mod_Desk_Merged.pak",
        sources: [
          { name: "Alpha.pak", path: "/srv/mods/Alpha.pak" },
          { name: "Beta.pak", path: "/srv/mods/Beta.pak" },
        ],
        backups: [],
        renames: [],
        createdPaths: [],
        winners: {},
      },
      labels: {
        mergedName: "Merged mod",
        mergedTag: "Merged",
        mergedDescription: (sources) => `Sources: ${sources.join(", ")}`,
        disabledTag: "Disabled",
        disabledDescription: "Disabled backup",
        deletedTag: "Deleted",
        deletedDescription: "Deleted backup",
      },
    });
    expect(result.snapshot.mods[0].name).toBe("Merged mod");
    expect(result.snapshot.mods[0].description).toBe(
      "Sources: Alpha.pak, Beta.pak",
    );
    expect(result.snapshot.mods[0].enabled).toBe(true);
  });

  it("hides pending deletions from the server list", () => {
    const state = normalizeServerLibraryState(
      {
        order: [],
        enabled: {},
        winners: {},
        deleted: ["/srv/mods/Beta.pak"],
      },
      scan,
    );
    const result = buildServerLibrarySnapshot({
      base,
      scan,
      report,
      state,
      manifest: null,
      labels: {
        mergedName: "Merged",
        mergedTag: "Merged",
        mergedDescription: (sources) => sources.join(", "),
        disabledTag: "Disabled",
        disabledDescription: "Disabled backup",
        deletedTag: "Deleted",
        deletedDescription: "Deleted backup",
      },
    });
    expect(result.state.deleted).toEqual(["/srv/mods/Beta.pak"]);
    expect(result.snapshot.mods.map((mod) => mod.name)).toEqual(["Alpha.pak"]);
    expect(result.conflicts).toEqual([]);
  });

  it("hides deployment order prefixes from managed server PAK names", () => {
    const managedScan: SftpConnectionResult = {
      ...scan,
      pakMods: [
        {
          name: "000_Alpha.pak",
          path: "/srv/mods/000_Alpha.pak",
          isDirectory: false,
          size: 100,
          modifiedAt: "2026-01-01T00:00:00Z",
        },
        {
          name: "001_Beta.pak",
          path: "/srv/mods/001_Beta.pak",
          isDirectory: false,
          size: 200,
          modifiedAt: "2026-01-02T00:00:00Z",
        },
      ],
    };
    const result = buildServerLibrarySnapshot({
      base,
      scan: managedScan,
      report: null,
      state: normalizeServerLibraryState(null, managedScan),
      manifest: {
        version: 1,
        createdAt: "2026-01-03T00:00:00Z",
        mergedPath: null,
        mergedName: null,
        sources: [],
        backups: [],
        winners: {},
        renames: [
          {
            name: "Alpha.pak",
            originalPath: "/srv/mods/Alpha.pak",
            deployedPath: "/srv/mods/000_Alpha.pak",
            hasSignature: false,
          },
          {
            name: "Beta.pak",
            originalPath: "/srv/mods/Beta.pak",
            deployedPath: "/srv/mods/001_Beta.pak",
            hasSignature: false,
          },
        ],
        createdPaths: [],
      },
      labels: {
        mergedName: "Merged",
        mergedTag: "Merged",
        mergedDescription: (sources) => sources.join(", "),
        disabledTag: "Disabled",
        disabledDescription: "Disabled backup",
        deletedTag: "Deleted",
        deletedDescription: "Deleted backup",
      },
    });

    expect(result.snapshot.mods.map((mod) => mod.name)).toEqual([
      "Alpha.pak",
      "Beta.pak",
    ]);
  });

  it("keeps disabled mods in state when the server moved them into the backup batch", () => {
    const scanWithBackup: SftpConnectionResult = {
      ...scan,
      pakMods: [scan.pakMods[1]],
      managedManifest: {
        version: 1,
        createdAt: "2026-01-01T00:00:00Z",
        mergedPath: null,
        mergedName: null,
        sources: [],
        backups: [
          {
            name: "Alpha.pak",
            originalPath: "/srv/mods/Alpha.pak",
            backupPath: "/srv/mods/_SCUM_Mod_Desk_Backups/1/Alpha.pak.bak",
            reason: "disabled",
          },
        ],
        renames: [],
        createdPaths: [],
        winners: {},
        provenancePaths: [],
      },
    };

    const state = normalizeServerLibraryState(
      {
        order: ["/srv/mods/Alpha.pak", "/srv/mods/Beta.pak"],
        enabled: { "/srv/mods/Alpha.pak": false },
        winners: {},
        deleted: [],
      },
      scanWithBackup,
    );

    expect(state.enabled["/srv/mods/Alpha.pak"]).toBe(false);
    // 备份里没被用户显式打开的条目必须默认禁用，否则会被当成 released 重新启用
    const fresh = normalizeServerLibraryState(null, scanWithBackup);
    expect(fresh.enabled["/srv/mods/Alpha.pak"]).toBe(false);
    expect(serverLibraryReleasedPaths(fresh, scanWithBackup)).toEqual([]);
    expect(serverLibraryDisabledPaths(state)).toEqual(["/srv/mods/Alpha.pak"]);
    expect(state.order).toEqual(["/srv/mods/Alpha.pak", "/srv/mods/Beta.pak"]);
    expect(serverLibraryReleasedPaths(state, scanWithBackup)).toEqual([]);
  });

  it("reports released paths when a disabled mod is switched back on", () => {
    const scanWithBackup: SftpConnectionResult = {
      ...scan,
      pakMods: [scan.pakMods[1]],
      managedManifest: {
        version: 1,
        createdAt: "2026-01-01T00:00:00Z",
        mergedPath: null,
        mergedName: null,
        sources: [],
        backups: [
          {
            name: "Alpha.pak",
            originalPath: "/srv/mods/Alpha.pak",
            backupPath: "/srv/mods/_SCUM_Mod_Desk_Backups/1/Alpha.pak.bak",
            reason: "disabled",
          },
        ],
        renames: [],
        createdPaths: [],
        winners: {},
        provenancePaths: [],
      },
    };
    const state = normalizeServerLibraryState(
      {
        order: ["/srv/mods/Alpha.pak", "/srv/mods/Beta.pak"],
        enabled: { "/srv/mods/Alpha.pak": true },
        winners: {},
        deleted: [],
      },
      scanWithBackup,
    );
    expect(serverLibraryReleasedPaths(state, scanWithBackup)).toEqual([
      "/srv/mods/Alpha.pak",
    ]);
  });

  it("renders backup-only mods as disabled rows after upload", () => {
    const manifest = {
      version: 1,
      createdAt: "2026-01-01T00:00:00Z",
      mergedPath: null,
      mergedName: null,
      sources: [],
      backups: [
        {
          name: "Alpha.pak",
          originalPath: "/srv/mods/Alpha.pak",
          backupPath: "/srv/mods/_SCUM_Mod_Desk_Backups/1/Alpha.pak.bak",
          reason: "disabled",
        },
      ],
      renames: [],
      createdPaths: [],
      winners: {},
      provenancePaths: [],
    };
    const scanWithBackup: SftpConnectionResult = {
      ...scan,
      pakMods: [scan.pakMods[1]],
      managedManifest: manifest,
    };
    const state = normalizeServerLibraryState(
      { order: [], enabled: {}, winners: {}, deleted: [] },
      scanWithBackup,
    );
    const result = buildServerLibrarySnapshot({
      base,
      scan: scanWithBackup,
      report: null,
      state,
      manifest,
      labels: {
        mergedName: "Merged",
        mergedTag: "Merged",
        mergedDescription: (sources) => sources.join(", "),
        disabledTag: "Disabled",
        disabledDescription: "Disabled backup",
        deletedTag: "Deleted",
        deletedDescription: "Deleted backup",
      },
    });
    const alpha = result.snapshot.mods.find((mod) => mod.id === "/srv/mods/Alpha.pak");
    expect(alpha?.enabled).toBe(false);
    expect(alpha?.tags).toEqual(["Disabled"]);
    expect(result.snapshot.mods.map((mod) => mod.name)).toEqual(["Beta.pak", "Alpha.pak"]);
  });
});
