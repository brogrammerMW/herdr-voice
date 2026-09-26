import { describe, expect, it } from "vitest";
import { authorizeUpgrade } from "../src/security.js";
import { stableJSON, validateManifest } from "../src/manifest.js";
import { createHash } from "node:crypto";

describe("loopback websocket admission", () => {
  it("admits only native loopback clients with the session bearer", () => {
    expect(authorizeUpgrade({ host: "127.0.0.1:1234", authorization: "Bearer secret" }, "127.0.0.1", "secret")).toBe(true);
    expect(authorizeUpgrade({ host: "localhost:1234", authorization: "Bearer secret" }, "::1", "secret")).toBe(true);
    expect(authorizeUpgrade({ host: "127.0.0.1:1234", authorization: "Bearer wrong" }, "127.0.0.1", "secret")).toBe(false);
    expect(authorizeUpgrade({ host: "127.0.0.1:1234", authorization: "Bearer secret", origin: "http://127.0.0.1" }, "127.0.0.1", "secret")).toBe(false);
    expect(authorizeUpgrade({ host: "evil.example", authorization: "Bearer secret" }, "127.0.0.1", "secret")).toBe(false);
    expect(authorizeUpgrade({ host: "127.0.0.1:1234", authorization: "Bearer secret" }, "10.0.0.8", "secret")).toBe(false);
  });
});

describe("tool manifest", () => {
  it("matches Swift sorted JSON without escaping slash characters", () => {
    const tools = [{ name: "x", description: "and/or patch/12 ~/dev/app", parameters: { type: "object", properties: {} } }];
    const canonical = stableJSON(tools);
    expect(canonical).toContain("and/or patch/12 ~/dev/app");
    const digest = createHash("sha256").update(canonical).digest("hex");
    expect(digest).toBe("aa1900e9b7b626caee2c5710d503b7f575eff8a3204b3150d030e7fc37bd2092");
    expect(validateManifest({ count: 1, names: ["x"], digest }, tools)).toBe(true);
  });
});
