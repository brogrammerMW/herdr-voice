import { createHash, timingSafeEqual } from "node:crypto";
import type { ToolDef } from "../vendor/harness/types.js";

export function validateManifest(manifest: { count: number; names: string[]; digest: string }, tools: ToolDef[]): boolean {
  if (manifest.count !== tools.length || manifest.names.length !== tools.length) return false;
  if (!manifest.names.every((name, index) => name === tools[index]?.name)) return false;
  const expected = createHash("sha256").update(stableJSON(tools)).digest();
  let actual: Buffer;
  try { actual = Buffer.from(manifest.digest, "hex"); } catch { return false; }
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function stableJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value as object).sort().map((key) => `${JSON.stringify(key)}:${stableJSON((value as any)[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}
