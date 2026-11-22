import { describe, expect, it } from "vitest";
import type { ModEntry, RemoteFile } from "../types";
import { mockInvoke, mockSnapshot } from "./mock";

describe("browser preview settings", () => {
  it("reclaims deployed mods by default", () => {
    const settings = mockSnapshot().settings as unknown as Record<string, unknown>;

    expect(settings.keepDeployedModsOnExit).toBe(false);
    expect(settings.autoMergeConflicts).toBe(true);
  });

  it("persists deployment and conflict merge settings", async () => {
    const next = {
      ...mockSnapshot().settings,
      keepDeployedModsOnExit: true,
      autoMergeConflicts: false,
    };

    await mockInvoke("save_settings", { settings: next });

    const saved = mockSnapshot().settings as unknown as Record<string, unknown>;
    expect(saved.keepDeployedModsOnExit).toBe(true);
    expect(saved.autoMergeConflicts).toBe(false);
  });
});

describe("remote SFTP operations (mock)", () => {
  it("creates remote folders idempotently", async () => {
    const target = "/srv/scum/SCUM/Content/Paks/~mods/QA_Sub";
    const first = (await mockInvoke("sftp_mkdir", {
      path: target,
    })) as unknown as { path: string };
    expect(first.path).toBe(target);
    await mockInvoke("sftp_mkdir", { path: target });
    const files = (await mockInvoke("list_remote_files")) as unknown as RemoteFile[];
    expect(files.filter((file) => file.name === "QA_Sub")).toHaveLength(1);
  });

  it("renames a remote PAK entry in place", async () => {
    const result = (await mockInvoke("rename_sftp_entry", {
      path: "/srv/scum/SCUM/Content/Paks/~mods/SCUM_WeaponPack_Elite.pak",
      newName: "Renamed_WeaponPack.pak",
    })) as unknown as { path: string };
    expect(result.path).toBe(
      "/srv/scum/SCUM/Content/Paks/~mods/Renamed_WeaponPack.pak",
    );
  });

  it("refuses to move a PAK to a non-PAK name", async () => {
    await expect(
      mockInvoke("move_sftp_entry", {
        path: "/srv/scum/SCUM/Content/Paks/~mods/LootBalance_Plus.pak",
        newPath: "/srv/scum/SCUM/Content/Paks/~mods/LootBalance_Plus.txt",
      }),
    ).rejects.toThrow("PAK");
  });

  it("imports remote PAKs and UE4SS directories into the local library", async () => {
    const pak = (await mockInvoke("download_sftp_mod_to_library", {
      path: "/srv/scum/SCUM/Content/Paks/~mods/ServerPak.pak",
    })) as unknown as { mods: ModEntry[] };
    const pakMod = pak.mods.find((mod) => mod.name === "ServerPak.pak");
    expect(pakMod?.type).toBe("clientPak");
    expect(pakMod?.tags).toContain("服务器");

    const ue4ss = (await mockInvoke("download_sftp_mod_to_library", {
      path: "/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods/SCUMTweaks",
    })) as unknown as { mods: ModEntry[] };
    const ue4ssMod = ue4ss.mods.find((mod) => mod.name === "SCUMTweaks");
    expect(ue4ssMod?.type).toBe("ue4ssMod");
  });
});
