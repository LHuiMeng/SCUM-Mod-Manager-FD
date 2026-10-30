import { describe, expect, it } from "vitest";
import { parseSftpConnectionUrl } from "./sftpUrl";

describe("SFTP connection URL parser", () => {
  it("parses a pasted SFTP URL with an optional password", () => {
    const encodedPassword = "p%40ss";
    expect(
      parseSftpConnectionUrl(
        `sftp://sftp_2658a4cc:${encodedPassword}@43.249.194.126:8822`,
      ),
    ).toEqual({
      protocol: "sftp",
      username: "sftp_2658a4cc",
      host: "43.249.194.126",
      port: 8822,
      password: "p@ss",
      path: "",
    });
  });

  it("supports a missing password, default port, encoded account, and remote path", () => {
    expect(
      parseSftpConnectionUrl(
        "sftp://mod%20user@example.test/SCUM/Content/Paks/~mods",
      ),
    ).toEqual({
      protocol: "sftp",
      username: "mod user",
      host: "example.test",
      port: 22,
      password: "",
      path: "/SCUM/Content/Paks/~mods",
    });
  });

  it("rejects non-SFTP protocols and incomplete accounts", () => {
    expect(() => parseSftpConnectionUrl("https://example.test")).toThrow(
      "仅支持 sftp://",
    );
    expect(() => parseSftpConnectionUrl("sftp://example.test:22")).toThrow(
      "缺少用户名",
    );
  });
});
