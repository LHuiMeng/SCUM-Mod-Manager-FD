import { describe, expect, it } from "vitest";
import {
  clampServerPanelHeight,
  DEFAULT_SERVER_LAYOUT,
  moveServerPanel,
  moveServerPanelBy,
  normalizeServerLayout,
} from "./serverLayout";

describe("server workspace layout", () => {
  it("clamps panel heights and restores defaults for invalid values", () => {
    expect(clampServerPanelHeight("viewer", 120)).toBe(260);
    expect(clampServerPanelHeight("viewer", 1200)).toBe(760);
    expect(clampServerPanelHeight("files", Number.NaN)).toBe(
      DEFAULT_SERVER_LAYOUT.heights.files,
    );
  });

  it("repairs missing or duplicate panels from persisted data", () => {
    const layout = normalizeServerLayout({
      order: ["viewer", "viewer"],
      heights: { viewer: 500 },
    });
    expect(layout.order).toEqual(["viewer", "account", "files"]);
    expect(layout.heights.viewer).toBe(500);
    expect(layout.heights.account).toBe(DEFAULT_SERVER_LAYOUT.heights.account);
  });

  it("moves panels by drop target and keyboard offset", () => {
    expect(moveServerPanel(["account", "files", "viewer"], "viewer", "account")).toEqual([
      "viewer",
      "account",
      "files",
    ]);
    expect(moveServerPanelBy(["account", "files", "viewer"], "files", 1)).toEqual([
      "account",
      "viewer",
      "files",
    ]);
  });
});
