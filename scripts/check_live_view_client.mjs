import {readFileSync} from "node:fs";
import {spawnSync} from "node:child_process";

const asset = new URL("../assets/opal_live_view.js", import.meta.url);
const entry = new URL("../assets/opal_live_view_entry.js", import.meta.url);
const source = readFileSync(entry, "utf8");

if (/\bbindingPrefix\s*:/.test(source)) {
  console.error("assets/opal_live_view_entry.js must use Phoenix's default phx-* bindings");
  process.exit(1);
}

const before = readFileSync(asset);
const build = spawnSync("npm", ["run", "build:live-view-client"], {
  cwd: new URL("..", import.meta.url),
  stdio: "inherit",
});

if (build.status !== 0) process.exit(build.status ?? 1);

const after = readFileSync(asset);
if (!before.equals(after)) {
  console.error("assets/opal_live_view.js was stale; rebuild and commit it");
  process.exit(1);
}
