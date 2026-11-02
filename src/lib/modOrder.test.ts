import { describe, expect, it } from "vitest";
import { reorderVisibleIds } from "./modOrder";

describe("reorderVisibleIds", () => {
  it("reorders a filtered subset without moving unrelated mods", () => {
    const result = reorderVisibleIds(
      ["a", "plain-1", "b", "plain-2", "c"],
      new Set(["a", "b", "c"]),
      "c",
      0,
    );

    expect(result).toEqual(["c", "plain-1", "a", "plain-2", "b"]);
  });

  it("rejects moves outside the visible range", () => {
    expect(
      reorderVisibleIds(["a", "b"], new Set(["a", "b"]), "a", 2),
    ).toBeNull();
    expect(
      reorderVisibleIds(["a", "b"], new Set(["a", "b"]), "missing", 0),
    ).toBeNull();
  });
});
