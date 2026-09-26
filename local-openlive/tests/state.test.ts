import { mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { defaultStateDir, migrateLegacyState, PARTITION, statePaths } from "../src/state.js";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "herdr-state-"));
  const legacyUserData = join(root, "Electron");
  const runtime = join(root, "plugin", "local-openlive");
  mkdirSync(join(legacyUserData, "Partitions", PARTITION, "Cache"), { recursive: true });
  writeFileSync(join(legacyUserData, "Partitions", PARTITION, "Cache", "model.bin"), "weights");
  mkdirSync(runtime, { recursive: true });
  writeFileSync(join(runtime, ".local-model-inventory.json"), '{"count":1}\n');
  return { root, legacyUserData, runtime, paths: statePaths(join(root, "state", "local-openlive")) };
}

describe("local state directory", () => {
  it("prefers HERDR_PLUGIN_STATE_DIR and falls back to ~/.local/state/herdr-voice", () => {
    expect(defaultStateDir({ HERDR_PLUGIN_STATE_DIR: "/s" }, "/h")).toBe("/s/local-openlive");
    expect(defaultStateDir({}, "/h")).toBe("/h/.local/state/herdr-voice/local-openlive");
  });

  it("rejects a relative or missing boot stateDir", () => {
    expect(() => statePaths("state")).toThrow(/absolute/);
    expect(() => statePaths(undefined)).toThrow(/absolute/);
  });

  it("copies the legacy cache and inventory once, leaving the old cache in place", () => {
    const { legacyUserData, runtime, paths } = fixture();
    expect(migrateLegacyState(paths, legacyUserData, runtime)).toHaveLength(2);
    expect(readFileSync(join(paths.userData, "Partitions", PARTITION, "Cache", "model.bin"), "utf8")).toBe("weights");
    expect(existsSync(join(legacyUserData, "Partitions", PARTITION))).toBe(true);
    expect(readFileSync(paths.inventory, "utf8")).toBe('{"count":1}\n');
    expect(statSync(paths.inventory).mode & 0o777).toBe(0o600);
    expect(migrateLegacyState(paths, legacyUserData, runtime)).toEqual([]);
  });

  it("never overwrites state that already exists", () => {
    const { legacyUserData, runtime, paths } = fixture();
    mkdirSync(join(paths.userData, "Partitions", PARTITION), { recursive: true });
    writeFileSync(paths.inventory, '{"count":2}\n');
    expect(migrateLegacyState(paths, legacyUserData, runtime)).toEqual([]);
    expect(readFileSync(paths.inventory, "utf8")).toBe('{"count":2}\n');
    expect(existsSync(join(paths.userData, "Partitions", PARTITION, "Cache"))).toBe(false);
  });
});
