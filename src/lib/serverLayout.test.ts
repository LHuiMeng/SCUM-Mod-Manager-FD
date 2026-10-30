import { describe, expect, it } from "vitest";
import {
  clampServerPanelRect,
  DEFAULT_SERVER_LAYOUT,
  fitServerLayoutToStage,
  moveServerPanelRect,
  normalizeServerLayout,
  resizeServerPanelRect,
} from "./serverLayout";

describe("server workspace layout", () => {
  it("normalizes every panel to a stage-relative rectangle", () => {
    const layout = normalizeServerLayout({
      rects: {
        viewer: { x: 0.8, y: 0.8, w: 0.4, h: 0.4 },
        files: { x: -1, y: Number.NaN, w: 2, h: 0.2 },
      },
    });
    expect(layout.rects.viewer.x).toBe(0.6);
    expect(layout.rects.viewer.y).toBe(0.6);
    expect(layout.rects.files.x).toBe(0);
    expect(layout.rects.files.w).toBe(1);
    expect(layout.rects.files.y).toBe(DEFAULT_SERVER_LAYOUT.rects.files.y);
    expect(layout.rects.account).toEqual(DEFAULT_SERVER_LAYOUT.rects.account);
  });

  it("keeps a moved panel inside the stage", () => {
    const moved = moveServerPanelRect(
      "account",
      { x: 0.05, y: 0.1, w: 0.4, h: 0.3 },
      0.8,
      -0.5,
      { width: 1200, height: 700 },
    );
    expect(moved.x).toBe(0.6);
    expect(moved.y).toBe(0);
  });

  it("enforces a usable minimum when resizing", () => {
    const resized = resizeServerPanelRect(
      "files",
      { x: 0.1, y: 0.1, w: 0.4, h: 0.3 },
      -1,
      -1,
      { width: 1000, height: 600 },
    );
    expect(resized.w).toBe(0.32);
    expect(resized.h).toBeCloseTo(260 / 600);
    expect(resized.x).toBe(0.1);
    expect(resized.y).toBe(0.1);
  });

  it("fits persisted rectangles into a smaller stage without changing storage", () => {
    const layout = normalizeServerLayout({
      rects: {
        account: { x: 0, y: 0, w: 0.25, h: 0.2 },
        files: { x: 0.5, y: 0, w: 0.3, h: 0.2 },
        viewer: { x: 0, y: 0.7, w: 0.98, h: 0.25 },
      },
    });
    const fitted = fitServerLayoutToStage(layout, { width: 700, height: 620 });
    expect(fitted.rects.account.w).toBeCloseTo(280 / 700);
    expect(fitted.rects.files.w).toBeCloseTo(320 / 700);
    expect(fitted.rects.viewer.h).toBeCloseTo(280 / 620);
    expect(layout.rects.account.w).toBe(0.25);
  });

  it("recovers from invalid persisted values", () => {
    const layout = normalizeServerLayout({
      rects: {
        viewer: { x: Number.POSITIVE_INFINITY, y: null, w: 0, h: -2 },
      },
    });
    expect(layout.rects.viewer.x).toBe(DEFAULT_SERVER_LAYOUT.rects.viewer.x);
    expect(layout.rects.viewer.y).toBe(DEFAULT_SERVER_LAYOUT.rects.viewer.y);
    expect(layout.rects.viewer.w).toBe(0.001);
    expect(layout.rects.viewer.h).toBe(0.001);
  });

  it("clamps a direct rectangle against both axes", () => {
    expect(
      clampServerPanelRect(
        "viewer",
        { x: 0.9, y: 0.9, w: 0.5, h: 0.5 },
        { width: 900, height: 700 },
      ),
    ).toEqual({ x: 0.5, y: 0.5, w: 0.5, h: 0.5 });
  });
});
