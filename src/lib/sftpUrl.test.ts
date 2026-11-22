import { describe, expect, it } from "vitest";
import {
  looksLikeConnectionString,
  parseConnectionString,
  parseHostPort,
} from "./sftpUrl";

describe("连接链接解析", () => {
  it("按链接里的端口解析 sftp 链接，并解码密码", () => {
    expect(
      parseConnectionString(
        `sftp://modder:${"p%40ss"}@example.test:8822`,
      ),
    ).toEqual({
      protocol: "sftp",
      username: "modder",
      host: "example.test",
      port: 8822,
      password: "p@ss",
      path: "",
    });
  });

  it("ftp 链接用链接里的端口，不用默认 21", () => {
    expect(
      parseConnectionString("ftp://modder@example.test:8821"),
    ).toEqual({
      protocol: "ftp",
      username: "modder",
      host: "example.test",
      port: 8821,
      password: "",
      path: "",
    });
  });

  it("没有口令、没有端口时回落到协议默认端口，并保留远端路径", () => {
    expect(
      parseConnectionString(
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
    expect(parseConnectionString("ftp://modder@example.test").port).toBe(21);
    expect(parseConnectionString("ftps://modder@example.test").port).toBe(990);
  });

  it("省略前缀时按 sftp 解析", () => {
    expect(
      parseConnectionString("modder@example.test:8822"),
    ).toMatchObject({
      protocol: "sftp",
      host: "example.test",
      port: 8822,
      username: "modder",
    });
  });

  it("拒绝不支持的协议与缺用户名的链接", () => {
    expect(() => parseConnectionString("https://example.test")).toThrow(
      "仅支持 sftp://、ftp:// 与 ftps://",
    );
    expect(() =>
      parseConnectionString("sftp://example.test:22"),
    ).toThrow("缺少用户名");
  });
});

describe("地址框输入判定", () => {
  it("区分裸主机名与连接链接", () => {
    expect(looksLikeConnectionString("sftp.example.com")).toBe(false);
    expect(looksLikeConnectionString("example.test:8822")).toBe(false);
    expect(looksLikeConnectionString("sftp://user@host:22")).toBe(true);
    expect(looksLikeConnectionString("ftp://user@host:21")).toBe(true);
    expect(looksLikeConnectionString("user@host")).toBe(true);
  });

  it("只带主机和端口时拆出端口", () => {
    expect(parseHostPort("example.test:8822")).toEqual({
      host: "example.test",
      port: 8822,
    });
    expect(parseHostPort("sftp.example.com")).toBeNull();
    expect(parseHostPort("sftp://user@host:22")).toBeNull();
    expect(parseHostPort("host:70000")).toBeNull();
  });
});
