import { describe, expect, it } from "vitest";
import { brainLabel, validateBrain } from "../src/brain.js";

describe("local brain configuration", () => {
  it("defaults the loopback brain to OpenAI Chat without a key", () => {
    const brain = validateBrain({ kind: "local", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3.5:4b" });
    expect(brain.protocol).toBe("openai-chat");
    expect(brainLabel(brain)).toBe("Local OpenLive / qwen3.5:4b");
  });

  it.each([
    [{ kind: "local", baseURL: "https://example.com/v1", model: "qwen3.5:4b" }, "loopback-only"],
    [{ kind: "local", baseURL: "http://127.0.0.1:11434/v1", model: "qwen-cloud" }, "cloud model"],
    [{ kind: "keyed", baseURL: "https://secret@example.com/v1", model: "remote", label: "Example", apiKey: "key" }, "credentials"],
    [{ kind: "keyed", baseURL: "https://example.com/v1", model: "remote", label: "Example" }, "Keychain API key"],
    [{ kind: "custom", baseURL: "https://example.com/v1", model: "remote" }, "hybrid label"],
  ] as const)("rejects unsafe or incomplete settings", (value, message) => {
    expect(() => validateBrain(value as Parameters<typeof validateBrain>[0])).toThrow(message);
  });

  it.each(["openai-chat", "openai", "anthropic"] as const)("accepts the pinned %s protocol", (protocol) => {
    expect(validateBrain({ kind: "custom", baseURL: "https://example.com", model: "model", label: "Example", protocol }).protocol)
      .toBe(protocol);
  });
});
