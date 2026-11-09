import { describe, expect, it } from "vitest";
import {
  pruneModSelection,
  updateModSelection,
  type ModSelectionState,
} from "./modSelection";

const visible = ["alpha", "beta", "gamma", "delta"];

function state(
  selected: string[],
  anchor: string | null,
  primary: string | null,
): ModSelectionState {
  return { selected, anchor, primary };
}

describe("updateModSelection", () => {
  it("replaces the selection on a plain click", () => {
    expect(
      updateModSelection(
        state(["alpha", "beta"], "alpha", "beta"),
        "gamma",
        visible,
        "replace",
      ),
    ).toEqual(state(["gamma"], "gamma", "gamma"));
  });

  it("toggles one row with ctrl and keeps the rest selected", () => {
    expect(
      updateModSelection(
        state(["alpha"], "alpha", "alpha"),
        "gamma",
        visible,
        "toggle",
      ),
    ).toEqual(state(["alpha", "gamma"], "gamma", "gamma"));

    expect(
      updateModSelection(
        state(["alpha", "gamma"], "gamma", "alpha"),
        "gamma",
        visible,
        "toggle",
      ),
    ).toEqual(state(["alpha"], "gamma", "alpha"));
  });

  it("selects an inclusive range with shift", () => {
    expect(
      updateModSelection(
        state(["beta"], "beta", "beta"),
        "delta",
        visible,
        "range",
      ),
    ).toEqual(state(["beta", "gamma", "delta"], "beta", "delta"));
  });

  it("selects backwards ranges from the anchor", () => {
    expect(
      updateModSelection(
        state(["delta"], "delta", "delta"),
        "beta",
        visible,
        "range",
      ),
    ).toEqual(state(["beta", "gamma", "delta"], "delta", "beta"));
  });

  it("falls back to the clicked row when the anchor was filtered out", () => {
    expect(
      updateModSelection(
        state(["alpha"], "alpha", "alpha"),
        "gamma",
        ["beta", "gamma"],
        "range",
      ),
    ).toEqual(state(["gamma"], "gamma", "gamma"));
  });

  it("prunes ids that are no longer visible", () => {
    expect(pruneModSelection(["alpha", "beta"], ["beta", "gamma"])).toEqual([
      "beta",
    ]);
  });
});
