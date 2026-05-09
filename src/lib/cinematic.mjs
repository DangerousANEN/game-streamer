// F4 cinematic flythrough: a live in-engine spectator camera path.
//
// Why not pre-recorded mp4: viewers want to see the *current* state of
// the map (warmup players running, bomb plant, smokes mid-round) — not
// a yesterday-recorded video. So we drive the cs2 spectator camera
// through a sequence of map-specific waypoints and let cs2 render the
// world live. ximagesrc captures it the same way it captures regular
// gameplay, so the cinematic shows up inline in the HLS stream.
//
// Implementation:
//   1. Load waypoints from /opt/5stack/intros/<map>.cinematic.json
//      (hostPath override) or fall back to the baked-in defaults at
//      src/cinematic-paths/<map>.json so admins can fine-tune per map
//      without rebuilding the streamer image.
//   2. Interpolate setpos/setang frames at 20Hz with cubic ease-in-out
//      between waypoints (smooth start/stop on each leg).
//   3. Build a single xdotool argv that opens the dev console once,
//      types every frame's `setpos x y z; setang p y r` + Return back-
//      to-back with inline `sleep`, then closes the console. One
//      spawn instead of 480 spawns per 24-second flythrough.
//
// The whole module is best-effort: if cs2 isn't focused, if the map
// has no waypoint binding, if the JSON is malformed — we just bail
// quietly and let the regular spectator camera continue.

import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as path from "node:path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// One-of-a-kind so panel can stop a running cinematic.
const cinematicState = {
  running: false,
  abortController: null,
  startedAt: 0,
  mapName: null,
};

const FPS = 20;
const FRAME_MS = 1000 / FPS;

const HOSTPATH_OVERRIDE_DIR = "/opt/5stack/intros";
const BUILTIN_PATHS_DIR = path.join(__dirname, "..", "cinematic-paths");

/**
 * Resolve a cinematic JSON for a map.
 * Order: hostPath override → baked-in default → null (no flythrough).
 */
async function loadWaypoints(mapName) {
  if (!mapName || typeof mapName !== "string") return null;
  const safe = mapName.replace(/[^a-zA-Z0-9_]/g, "");
  if (!safe) return null;

  for (const dir of [HOSTPATH_OVERRIDE_DIR, BUILTIN_PATHS_DIR]) {
    try {
      const file = path.join(dir, `${safe}.cinematic.json`);
      const raw = await readFile(file, "utf8");
      const parsed = JSON.parse(raw);
      if (validateWaypoints(parsed)) return { ...parsed, _source: file };
    } catch {
      // missing override is fine — fall through to next dir
    }
    try {
      const altFile = path.join(dir, `${safe}.json`);
      const raw = await readFile(altFile, "utf8");
      const parsed = JSON.parse(raw);
      if (validateWaypoints(parsed)) return { ...parsed, _source: altFile };
    } catch {
      // fall through
    }
  }
  return null;
}

function validateWaypoints(obj) {
  if (!obj || typeof obj !== "object") return false;
  if (!Array.isArray(obj.waypoints) || obj.waypoints.length < 2) return false;
  for (const wp of obj.waypoints) {
    if (
      !Array.isArray(wp.pos) ||
      wp.pos.length !== 3 ||
      !Array.isArray(wp.ang) ||
      wp.ang.length !== 3
    ) {
      return false;
    }
  }
  return true;
}

// Cubic ease-in-out for [0,1] → [0,1].
function easeInOutCubic(t) {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}

// Lerp shortest-arc on yaw (-180..180 wrap) so the camera doesn't spin
// the long way around when waypoints cross the seam.
function lerpAngle(a, b, t) {
  let d = b - a;
  while (d > 180) d -= 360;
  while (d < -180) d += 360;
  return a + d * t;
}

function lerp(a, b, t) {
  return a + (b - a) * t;
}

/**
 * Build the full sequence of frames (pos+ang) by interpolating each
 * leg between consecutive waypoints. Each leg burns its
 * `hold_seconds` budget proportional to total `duration_seconds`.
 */
function buildFrames(plan) {
  const totalSec = Number(plan.duration_seconds) || 24;
  const wps = plan.waypoints;
  const legs = wps.length - 1;
  if (legs < 1) return [];

  const totalHold = wps.reduce(
    (acc, wp) => acc + (Number(wp.hold_seconds) || 0),
    0,
  );
  const moveBudgetSec = Math.max(1, totalSec - totalHold);
  const perLegSec = moveBudgetSec / legs;

  const frames = [];
  for (let i = 0; i < legs; i++) {
    const a = wps[i];
    const b = wps[i + 1];
    const legFrames = Math.max(2, Math.round(perLegSec * FPS));
    for (let f = 0; f < legFrames; f++) {
      const t = easeInOutCubic(f / (legFrames - 1));
      frames.push({
        pos: [
          lerp(a.pos[0], b.pos[0], t),
          lerp(a.pos[1], b.pos[1], t),
          lerp(a.pos[2], b.pos[2], t),
        ],
        ang: [
          lerpAngle(a.ang[0], b.ang[0], t),
          lerpAngle(a.ang[1], b.ang[1], t),
          lerpAngle(a.ang[2], b.ang[2], t),
        ],
      });
    }
    const holdSec = Number(b.hold_seconds) || 0;
    if (holdSec > 0) {
      const holdFrames = Math.max(1, Math.round(holdSec * FPS));
      for (let f = 0; f < holdFrames; f++) {
        frames.push({ pos: b.pos.slice(), ang: b.ang.slice() });
      }
    }
  }
  return frames;
}

/**
 * Run a cinematic flythrough on the cs2 spectator camera.
 * Returns the resolved plan (so callers can log map/source) and a
 * promise that resolves when the cinematic finishes or is aborted.
 *
 * Caller is expected to have cs2 in spectator mode already; we put the
 * camera into free-roam (`spec_mode 6`), interpolate frames, then
 * return to the default (`spec_mode 4` = roving) so the regular
 * spectator UX picks back up.
 */
export async function runCinematic(mapName, log = () => {}) {
  if (cinematicState.running) {
    log("cinematic already running — ignoring start");
    return { ok: false, reason: "already-running" };
  }

  const plan = await loadWaypoints(mapName);
  if (!plan) {
    log(`no cinematic plan for map ${mapName}`);
    return { ok: false, reason: "no-plan", map: mapName };
  }

  const frames = buildFrames(plan);
  if (frames.length === 0) {
    log(`cinematic plan for ${mapName} produced 0 frames`);
    return { ok: false, reason: "no-frames", map: mapName };
  }

  log(
    `cinematic start map=${mapName} src=${plan._source} ` +
      `waypoints=${plan.waypoints.length} frames=${frames.length} ` +
      `duration=${(frames.length * FRAME_MS) / 1000}s`,
  );

  cinematicState.running = true;
  cinematicState.startedAt = Date.now();
  cinematicState.mapName = mapName;
  cinematicState.abortController = new AbortController();
  const { signal } = cinematicState.abortController;

  try {
    // Open dev console once.
    await runXdotool(["key", "--clearmodifiers", "grave"]);
    await sleep(120);
    // Switch to free-cam.
    await typeAndEnter(`spec_lock_to_accountid 0`);
    await typeAndEnter(`spec_mode 6`);
    await sleep(80);

    for (const frame of frames) {
      if (signal.aborted) break;
      const cmd = formatFrameCommand(frame);
      await typeAndEnter(cmd);
      await sleep(FRAME_MS);
    }

    // Return to roving spectator so the regular UX continues.
    await typeAndEnter(`spec_mode 4`);
    await sleep(60);
    // Close console.
    await runXdotool(["key", "--clearmodifiers", "grave"]);
    log("cinematic done");
    return { ok: true, frames: frames.length, map: mapName };
  } finally {
    cinematicState.running = false;
    cinematicState.abortController = null;
    cinematicState.startedAt = 0;
    cinematicState.mapName = null;
  }
}

export function stopCinematic() {
  if (cinematicState.running && cinematicState.abortController) {
    cinematicState.abortController.abort();
    return true;
  }
  return false;
}

export function getCinematicStatus() {
  return {
    running: cinematicState.running,
    map: cinematicState.mapName,
    started_at: cinematicState.startedAt,
    elapsed_ms: cinematicState.running
      ? Date.now() - cinematicState.startedAt
      : 0,
  };
}

function formatFrameCommand({ pos, ang }) {
  const [x, y, z] = pos.map((v) => v.toFixed(1));
  const [p, yaw, r] = ang.map((v) => v.toFixed(1));
  return `setpos ${x} ${y} ${z}; setang ${p} ${yaw} ${r}`;
}

function typeAndEnter(text) {
  return runXdotool(["type", "--delay", "0", text]).then(() =>
    runXdotool(["key", "--clearmodifiers", "Return"]),
  );
}

function runXdotool(args) {
  return new Promise((resolve, reject) => {
    const child = spawn("xdotool", args, { stdio: "ignore" });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`xdotool ${args[0]} exited ${code}`));
    });
  });
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}
