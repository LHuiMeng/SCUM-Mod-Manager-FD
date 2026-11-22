import { describe, expect, it } from "vitest";
import { resolveFileDrop } from "./fileDrop";

describe("resolveFileDrop", () => {
  it("shows the drop target only while dragging over the library", () => {
    expect(resolveFileDrop("library", { type: "enter" }).active).toBe(true);
    expect(resolveFileDrop("settings", { type: "enter" }).active).toBe(false);
    expect(resolveFileDrop("library", { type: "leave" }).active).toBe(false);
  });

  it("routes dropped files to import on the library page", () => {
    expect(
      resolveFileDrop("library", {
        type: "drop",
        paths: ["C:/mods/TestWeapon.pak", "C:/mods/BetterAI"],
      }),
    ).toEqual({
      active: false,
      paths: ["C:/mods/TestWeapon.pak", "C:/mods/BetterAI"],
      requiresLibrary: false,
    });
  });

  it("asks the user to return to the library when dropping elsewhere", () => {
    expect(
      resolveFileDrop("cloud", { type: "drop", paths: ["C:/mods/TestWeapon.pak"] }),
    ).toEqual({
      active: false,
      paths: [],
      requiresLibrary: true,
    });
  });
});
