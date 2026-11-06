import { describe, expect, it } from "vitest";
import { normalizePort } from "./serverPort";

describe("normalizePort", () => {
  it("keeps valid ports and trims spaces", () => {
    expect(normalizePort(" 8080 ")).toBe("8080");
    expect(normalizePort("7777")).toBe("7777");
  });

  it("falls back for empty or out-of-range values", () => {
    expect(normalizePort("")).toBe("7777");
    expect(normalizePort("0")).toBe("7777");
    expect(normalizePort("65536")).toBe("7777");
    expect(normalizePort("abc")).toBe("7777");
  });
});
