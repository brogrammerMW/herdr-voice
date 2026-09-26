import { cp, mkdir, readFile, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pin = JSON.parse(await readFile(join(root, "UPSTREAM.json"), "utf8"));
const upstream = resolve(process.env.HERDR_OPENLIVE_UPSTREAM ?? join(homedir(), ".local/share/herdr-openlive/upstream"));
let actual = "";
try {
  actual = execFileSync("git", ["-C", upstream, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
} catch {
  throw new Error(`OpenLive source missing at ${upstream}; run scripts/local-openlive-setup`);
}
if (actual !== pin.commit) throw new Error(`OpenLive pin mismatch: expected ${pin.commit}, found ${actual}`);
const upstreamLicense = await readFile(join(upstream, "LICENSE"), "utf8");
const committedLicense = await readFile(join(root, "OPENLIVE-LICENSE"), "utf8");
if (upstreamLicense !== committedLicense) throw new Error("committed OpenLive license does not match the pinned source");

const vendor = join(root, "vendor");
await rm(vendor, { recursive: true, force: true });
await mkdir(join(vendor, "live"), { recursive: true });
await mkdir(join(vendor, "harness"), { recursive: true });
for (const file of ["models.worker.ts", "supertonic.ts", "voiceText.ts"]) {
  await cp(join(upstream, "apps/web/src/lib/live", file), join(vendor, "live", file));
}
await cp(join(upstream, "packages/harness/src"), join(vendor, "harness"), { recursive: true });
process.stdout.write(`synced OpenLive ${pin.commit}\n`);
