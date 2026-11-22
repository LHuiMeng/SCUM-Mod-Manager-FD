import { describe, expect, it } from "vitest";
import {
  isRemotePathWithin,
  normalizeRemotePath,
  remoteBreadcrumbs,
  remoteParent,
} from "./remotePath";

describe("remote path navigation", () => {
  it("normalizes separators and trailing slashes", () => {
    expect(normalizeRemotePath("  srv//scum/SCUM/ ")).toBe("/srv/scum/SCUM");
    expect(normalizeRemotePath("/srv/scum/../SCUM/./Content")).toBe(
      "/srv/SCUM/Content",
    );
    expect(normalizeRemotePath("/")).toBe("/");
    expect(normalizeRemotePath("")).toBe("/");
  });

  it("finds parents including the filesystem root", () => {
    expect(remoteParent("/srv/scum/SCUM/~mods")).toBe("/srv/scum/SCUM");
    expect(remoteParent("/srv")).toBe("/");
    expect(remoteParent("/")).toBe("/");
  });

  it("builds clickable breadcrumbs for every path segment", () => {
    expect(remoteBreadcrumbs("/srv/scum/SCUM")).toEqual([
      { name: "/", path: "/" },
      { name: "srv", path: "/srv" },
      { name: "scum", path: "/srv/scum" },
      { name: "SCUM", path: "/srv/scum/SCUM" },
    ]);
  });

  it("allows a root itself and descendants but not sibling prefixes", () => {
    expect(isRemotePathWithin("/srv/scum/~mods", "/srv/scum/~mods/Mod.pak")).toBe(true);
    expect(isRemotePathWithin("/srv/scum/~mods", "/srv/scum/~mods")).toBe(true);
    expect(isRemotePathWithin("/srv/scum/~mods", "/srv/scum/~mods-old/Mod.pak")).toBe(false);
    expect(isRemotePathWithin("/", "/srv/scum")).toBe(true);
  });
});
