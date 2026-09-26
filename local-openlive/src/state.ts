import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, renameSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

export const PARTITION = "herdr-local-openlive-v1";
export const INVENTORY_FILE = "model-inventory.json";
const LEGACY_INVENTORY_FILE = ".local-model-inventory.json";

// Same rule as Swift's LocalState and scripts/state-dir.mjs: HERDR_PLUGIN_STATE_DIR, else ~/.local/state/herdr-voice.
export function defaultStateDir(env: NodeJS.ProcessEnv = process.env, home = homedir()): string {
  return join(resolve(env.HERDR_PLUGIN_STATE_DIR || join(home, ".local/state/herdr-voice")), "local-openlive");
}

// Paths under the state directory Swift passes in the boot JSON. It lives outside the plugin folder, which
// `herdr plugin install` replaces on every update.
export function statePaths(stateDir: unknown): { stateDir: string; userData: string; inventory: string } {
  if (typeof stateDir !== "string" || !isAbsolute(stateDir)) throw new Error("boot stateDir must be an absolute path");
  return { stateDir, userData: join(stateDir, "electron"), inventory: join(stateDir, INVENTORY_FILE) };
}

// One-time carry-over from the pre-state-dir layout: the Electron default userData and the inventory in the
// runtime folder. The cache is copied, not moved, so an older install that still uses the old path keeps working.
// Returns what it migrated, for a log line.
export function migrateLegacyState(paths: ReturnType<typeof statePaths>, legacyUserData: string, runtimeRoot: string): string[] {
  const migrated: string[] = [];
  mkdirSync(paths.stateDir, { recursive: true, mode: 0o700 });
  const target = join(paths.userData, "Partitions", PARTITION);
  const legacy = join(legacyUserData, "Partitions", PARTITION);
  if (!existsSync(target) && legacy !== target && existsSync(legacy)) {
    // Copy beside the target, then rename, so an interrupted copy never looks like a finished cache.
    const partial = `${target}.partial`;
    rmSync(partial, { recursive: true, force: true });
    mkdirSync(join(paths.userData, "Partitions"), { recursive: true });
    cpSync(legacy, partial, { recursive: true });
    renameSync(partial, target);
    migrated.push(`model cache from ${legacy}`);
  }
  const legacyInventory = join(runtimeRoot, LEGACY_INVENTORY_FILE);
  if (!existsSync(paths.inventory) && existsSync(legacyInventory)) {
    copyFileSync(legacyInventory, paths.inventory);
    chmodSync(paths.inventory, 0o600);
    migrated.push(`model inventory from ${legacyInventory}`);
  }
  return migrated;
}
