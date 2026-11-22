import { describe, expect, it } from "vitest";
import type { CloudDownloadProgress } from "../types";
import {
  clampCloudDownloadSegments,
  cloudDownloadDetail,
  cloudDownloadIsActive,
  cloudDownloadPercent,
  cloudDownloadPhaseLabel,
} from "./cloudDownload";

function progress(
  value: Omit<CloudDownloadProgress, "id">,
): CloudDownloadProgress {
  return { id: "demo", ...value };
}

describe("cloud download presentation", () => {
  it("clamps the manual segment ceiling to 8..128", () => {
    expect(clampCloudDownloadSegments(4)).toBe(8);
    expect(clampCloudDownloadSegments(16.4)).toBe(16);
    expect(clampCloudDownloadSegments(128)).toBe(128);
    expect(clampCloudDownloadSegments(999)).toBe(128);
    expect(clampCloudDownloadSegments(Number.NaN)).toBe(8);
  });

  it("reports percent from the latest segment progress", () => {
    expect(
      cloudDownloadPercent(progress({
        phase: "downloading",
        downloaded: 64 * 1024 * 1024,
        total: 128 * 1024 * 1024,
        segments: 16,
      })),
    ).toBe(50);
  });

  it("shows completed phases at full progress", () => {
    expect(
      cloudDownloadPercent(progress({
        phase: "verifying",
        downloaded: 128 * 1024 * 1024,
        total: 128 * 1024 * 1024,
        segments: 0,
      })),
    ).toBe(100);
    expect(
      cloudDownloadPercent(progress({
        phase: "queued",
        downloaded: 0,
        total: 128 * 1024 * 1024,
        segments: 0,
      })),
    ).toBe(0);
  });

  it("describes queued, segmented and verification states", () => {
    expect(cloudDownloadPhaseLabel("queued")).toBe("等待下载槽位");
    expect(cloudDownloadPhaseLabel("downloading")).toBe("正在分片下载");
    expect(
      cloudDownloadDetail(progress({
        phase: "downloading",
        downloaded: 32 * 1024 * 1024,
        total: 128 * 1024 * 1024,
        segments: 16,
      })),
    ).toContain("16 路并发");
    expect(
      cloudDownloadDetail(progress({
        phase: "verifying",
        downloaded: 128 * 1024 * 1024,
        total: 128 * 1024 * 1024,
        segments: 0,
      })),
    ).toContain("SHA-256");
  });

  it("only treats unfinished transfer phases as active", () => {
    expect(
      cloudDownloadIsActive(progress({
        phase: "queued",
        downloaded: 0,
        total: 128,
        segments: 0,
      })),
    ).toBe(true);
    expect(
      cloudDownloadIsActive(progress({
        phase: "completed",
        downloaded: 128,
        total: 128,
        segments: 0,
      })),
    ).toBe(false);
    expect(
      cloudDownloadIsActive(progress({
        phase: "error",
        downloaded: 32,
        total: 128,
        segments: 8,
      })),
    ).toBe(false);
  });
});
