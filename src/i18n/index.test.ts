import { describe, expect, it } from "vitest";
import {
  interpolate,
  normalizeLanguage,
  translate,
} from "./index";

describe("i18n", () => {
  it("falls back from user overrides to the selected built-in dictionary", () => {
    expect(translate("en-US", null, "library.scan")).toBe("Scan");
    expect(
      translate("en-US", { "library.scan": "Rescan archive" }, "library.scan"),
    ).toBe("Rescan archive");
  });

  it("interpolates variables and leaves unknown placeholders intact", () => {
    expect(
      interpolate("{count} mods in {name}", { count: 3, name: "Library" }),
    ).toBe("3 mods in Library");
    expect(interpolate("{count} / {total}", { count: 1 })).toBe("1 / {total}");
  });

  it("uses singular English messages while keeping user overrides authoritative", () => {
    expect(
      translate("en-US", null, "common.conflictCount", { count: 1 }),
    ).toBe("1 conflict");
    expect(
      translate("en-US", null, "conflict.pathCount", { count: 1 }),
    ).toBe("1 file");
    expect(
      translate(
        "en-US",
        { "common.conflictCount": "Custom conflict count: {count}" },
        "common.conflictCount",
        { count: 1 },
      ),
    ).toBe("Custom conflict count: 1");
  });

  it("normalizes unsupported language codes to Simplified Chinese", () => {
    expect(normalizeLanguage("en-US")).toBe("en-US");
    expect(normalizeLanguage("fr-FR")).toBe("zh-CN");
  });
});
