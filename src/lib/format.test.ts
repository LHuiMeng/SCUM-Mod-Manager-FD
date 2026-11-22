import { describe, expect, it } from "vitest";
import { compactHash, formatBytes, modMonogram, modTypeLabel } from "./format";

describe("format helpers", () => {
  it("formats binary file sizes", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(1024 ** 3)).toBe("1.00 GB");
  });

  it("returns stable Chinese type labels", () => {
    expect(modTypeLabel("clientPak")).toBe("客户端 PAK");
    expect(modTypeLabel("ue4ssMod")).toBe("UE4SS MOD");
  });

  it("creates compact mod monograms", () => {
    expect(modMonogram("SCUM_WeaponPack_Elite")).toBe("SW");
    expect(modMonogram("UI")).toBe("UI");
  });

  it("keeps hashes readable without exposing the full value", () => {
    expect(compactHash("")).toBe("尚未计算");
    expect(compactHash("1234567890abcdef")).toBe("1234…cdef");
  });
});
