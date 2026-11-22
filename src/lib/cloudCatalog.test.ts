import { describe, expect, it, vi } from "vitest";
import {
  CLOUD_AUTO_ATTEMPTS,
  CLOUD_RETRY_DELAYS_MS,
  runCloudCatalogAttempts,
} from "./cloudCatalog";

describe("cloud catalog retry policy", () => {
  it("makes at most four automatic attempts with increasing delays", async () => {
    const fetchCatalog = vi.fn().mockRejectedValue(new Error("offline"));
    const onAttempt = vi.fn();
    const wait = vi.fn().mockResolvedValue(undefined);

    await expect(
      runCloudCatalogAttempts(fetchCatalog, { onAttempt, wait }),
    ).rejects.toThrow("offline");

    expect(fetchCatalog).toHaveBeenCalledTimes(CLOUD_AUTO_ATTEMPTS);
    expect(onAttempt.mock.calls.map(([attempt]) => attempt)).toEqual([1, 2, 3, 4]);
    expect(wait.mock.calls.map(([milliseconds]) => milliseconds)).toEqual(
      [...CLOUD_RETRY_DELAYS_MS],
    );
  });

  it("stops after a successful automatic attempt", async () => {
    const fetchCatalog = vi
      .fn()
      .mockRejectedValueOnce(new Error("first"))
      .mockResolvedValueOnce("catalog");
    const wait = vi.fn().mockResolvedValue(undefined);

    await expect(runCloudCatalogAttempts(fetchCatalog, { wait })).resolves.toEqual({
      result: "catalog",
      attempts: 2,
    });
    expect(wait).toHaveBeenCalledTimes(1);
  });

  it("performs exactly one request for a manual attempt", async () => {
    const fetchCatalog = vi.fn().mockRejectedValue(new Error("manual failure"));
    const wait = vi.fn();

    await expect(
      runCloudCatalogAttempts(fetchCatalog, { maxAttempts: 1, wait }),
    ).rejects.toThrow("manual failure");
    expect(fetchCatalog).toHaveBeenCalledTimes(1);
    expect(wait).not.toHaveBeenCalled();
  });
});
