import { describe, expect, it } from "vitest";
import worker from "../cloudflare/scum-mods-gate/worker.js";

const sharedKey = "unit-test-shared-key";
const payload = new TextEncoder().encode("pak-data");

function environment(headCalls = { count: 0 }) {
  return {
    GATE_TOKEN: sharedKey,
    MODS: {
      head: async () => {
        headCalls.count += 1;
        return {
          size: payload.byteLength,
          httpEtag: '"test-etag"',
          httpMetadata: { contentType: "application/octet-stream" },
        };
      },
      get: async () => ({ body: payload }),
    },
  };
}

function request(headers = {}) {
  return new Request("https://gate.example.test/mods/demo.pak", { headers });
}

describe("cloud gate shared key", () => {
  it("rejects anonymous downloads", async () => {
    const calls = { count: 0 };
    const response = await worker.fetch(request(), environment(calls));

    expect(response.status).toBe(403);
    expect(calls.count).toBe(0);
  });

  it("accepts the legacy X-Scum-Gate header", async () => {
    const response = await worker.fetch(
      request({ "X-Scum-Gate": sharedKey }),
      environment(),
    );

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("pak-data");
  });

  it("accepts the same key as a bearer token for catalog compatibility", async () => {
    const response = await worker.fetch(
      request({ Authorization: `Bearer ${sharedKey}` }),
      environment(),
    );

    expect(response.status).toBe(200);
  });

  it("rejects a different key", async () => {
    const response = await worker.fetch(
      request({
        Authorization: "Bearer wrong-key",
        "X-Scum-Gate": "wrong-key",
      }),
      environment(),
    );

    expect(response.status).toBe(403);
  });
});
