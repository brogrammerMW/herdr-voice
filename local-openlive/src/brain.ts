import type { ProviderInfo } from "../vendor/harness/types.js";

export type BrainConfig = {
  kind: "local" | "keyed" | "custom";
  baseURL: string;
  model: string;
  protocol?: "openai-chat" | "openai" | "anthropic";
  reasoningEffort?: string;
  apiKey?: string;
  label?: string;
};

export function validateBrain(value: BrainConfig): BrainConfig {
  if (!(["local", "keyed", "custom"] as const).includes(value.kind)) throw new Error("unsupported brain kind");
  const url = new URL(value.baseURL);
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("brain URL must use HTTP(S)");
  if (url.username || url.password || url.search || url.hash) throw new Error("brain URL must not contain credentials or query data");
  if (value.kind === "local" && !["127.0.0.1", "localhost", "::1"].includes(url.hostname)) {
    throw new Error("local brain must be loopback-only");
  }
  if (value.kind === "local" && /(?:^|[-_:])cloud(?:$|[-_:])/i.test(value.model)) {
    throw new Error("local brain refuses cloud model names");
  }
  if (value.kind !== "local" && !value.label) throw new Error("remote brain requires an explicit hybrid label");
  if (value.kind === "keyed" && !value.apiKey) throw new Error("keyed brain requires a Keychain API key");
  if (!/^[a-z0-9._:/@+-]{1,200}$/i.test(value.model)) throw new Error("invalid brain model");
  if (value.label && (value.label.length > 80 || /[\r\n]/.test(value.label))) throw new Error("invalid brain label");
  const protocol = value.protocol ?? "openai-chat";
  if (!(["openai-chat", "openai", "anthropic"] as const).includes(protocol)) throw new Error("unsupported brain protocol");
  if (value.reasoningEffort && !/^[a-z0-9_-]{1,40}$/i.test(value.reasoningEffort)) {
    throw new Error("invalid reasoning effort");
  }
  return { ...value, protocol };
}

export function brainLabel(value: BrainConfig): string {
  return value.kind === "local" ? `Local OpenLive / ${value.model}` : `Hybrid: ${value.label}`;
}

export function providerInfo(config: BrainConfig): ProviderInfo {
  return { id: "herdr-local-brain", name: brainLabel(config), protocol: config.protocol ?? "openai-chat",
    baseURL: config.baseURL, keyless: config.kind === "local", custom: config.kind === "custom" };
}
