import { describe, expect, it } from "vitest";
import { mockInvoke, mockSnapshot } from "./mock";

describe("browser preview settings", () => {
  it("reclaims deployed mods by default", () => {
    const settings = mockSnapshot().settings as unknown as Record<string, unknown>;

    expect(settings.keepDeployedModsOnExit).toBe(false);
  });

  it("persists the deployment retention setting", async () => {
    const next = {
      ...mockSnapshot().settings,
      keepDeployedModsOnExit: true,
    };

    await mockInvoke("save_settings", { settings: next });

    const saved = mockSnapshot().settings as unknown as Record<string, unknown>;
    expect(saved.keepDeployedModsOnExit).toBe(true);
  });
});
