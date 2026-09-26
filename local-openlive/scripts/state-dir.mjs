import { homedir } from "node:os";
import { join } from "node:path";

// Same fixed path as Swift's LocalState; HERDR_PLUGIN_STATE_DIR is ignored so terminal setup and the plugin pane agree.
export const stateDir = join(homedir(), ".local/state/herdr-voice/local-openlive");
export const inventoryFile = join(stateDir, "model-inventory.json");
