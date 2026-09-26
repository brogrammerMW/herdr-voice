import { homedir } from "node:os";
import { join, resolve } from "node:path";

// Same rule as Swift's LocalState: HERDR_PLUGIN_STATE_DIR when set, else ~/.local/state/herdr-voice.
const base = process.env.HERDR_PLUGIN_STATE_DIR || join(homedir(), ".local/state/herdr-voice");
export const stateDir = join(resolve(base), "local-openlive");
export const inventoryFile = join(stateDir, "model-inventory.json");
