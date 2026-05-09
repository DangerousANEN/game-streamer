#!/usr/bin/env node
// HTTP control daemon for cs2 spectator + demo-playback actions.
// Routes are defined inline with the handlers below.
//
// Why bound keys instead of xdotool-typing the dev console: the OpenHud
// overlay is raised above cs2 so ximagesrc captures both composited.
// `windowactivate` would restack cs2 above the overlay (Openbox can
// destroy the overlay window in the process). Instead, every action is
// pre-bound to a key in cs2's autoexec, and the overlay BrowserWindow
// is built `focusable: false` so cs2 always holds focus — `xdotool key`
// (XTest) reaches it directly with no restacking.
//
// Static binds mirror lib/openhud.sh:spec_static_binds_block — change
// both together. Started by src/flows/setup-steam.sh after Xorg.

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import {
  runCinematic,
  stopCinematic,
  getCinematicStatus,
} from "./lib/cinematic.mjs";

const DISPLAY = process.env.DISPLAY ?? ":0";
const PORT = parseInt(process.env.SPEC_PORT ?? "1350", 10);
// Bind to all interfaces. The api reaches us cross-pod via k8s service
// DNS (`<svc>.<ns>.svc.cluster.local:1350`), which resolves to the pod
// IP — loopback-only would break that. The cluster network is the
// trust boundary: only in-cluster pods can route to this port.
// Sensitive routes (`/demo/exec`, `/demo/render-clip`) are reachable
// from any in-cluster source by design.
const BIND = process.env.SPEC_BIND ?? "0.0.0.0";

// Static action -> cs2-bound F-key. Mirror of the binds written by
// run-live.sh into autoexec.cfg via lib/openhud.sh:spec_static_binds_block.
// If you change a key here, change it there (and vice versa).
const KEY_SPEC_NEXT = "F1";
const KEY_SPEC_PREV = "F2";
const KEY_SPEC_JUMP = "F3";
const KEY_AUTODIRECTOR_ON = "F4";
const KEY_AUTODIRECTOR_OFF = "F5";

// Demo-playback bound keys (run-demo.sh + lib/openhud.sh:demo_static_binds_block).
// Goal: avoid typed-console commands wherever the action's args are
// constant — typed console flashes briefly on the WHEP capture, bound
// keys go through XTest with no UI side-effect.
const KEY_DEMO_TOGGLE = "Pause";
const KEY_DEMO_SKIP_BACK = "Home";    // bound to demo_gototick -960 (~ -15s)
const KEY_DEMO_SKIP_FWD  = "End";     // bound to demo_gototick +960 (~ +15s)
// X is cs2's built-in spec-mode x-ray toggle — no autoexec bind
// needed, no console flash, no Steam-hotkey collision.
const KEY_XRAY_TOGGLE = "x";
const SPEED_KEY_BY_RATE = {
  "0.25": "Next",        // PageDown
  "0.5":  "semicolon",
  "1":    "Insert",
  "2":    "apostrophe",
  "4":    "Prior",       // PageUp
};

// Sidecar JSON dropped by run-demo.sh so /demo/round can resolve a
// round number to a tick without a round-trip back to the api.
const DEMO_ROUND_TICKS_PATH =
  process.env.DEMO_ROUND_TICKS_PATH ??
  path.join(process.env.LOG_DIR ?? "/tmp/game-streamer", "demo-round-ticks.json");

// autoexec binds BACKSPACE → `exec 5stack_exec`. execCfgCommand
// writes the cmd to this file then sends BACKSPACE. Pre-created empty
// by run-demo.sh.
const CS2_CFG_DIR =
  process.env.CS2_CFG_DIR ??
  (process.env.CS2_DIR ? `${process.env.CS2_DIR}/game/csgo/cfg` : null);
const EXEC_CFG_PATH = CS2_CFG_DIR ? `${CS2_CFG_DIR}/5stack_exec.cfg` : null;
const EXEC_CFG_KEY = "BackSpace";


// Demo session bookkeeping for tick estimation + idle-timeout. Held in
// memory for the life of the daemon (which is the life of the pod).
const demoState = {
  // Best-effort: tick at the moment of the most recent /demo/seek (or
  // session start). Combined with `lastSeekRealMs` and `rate` lets us
  // give the api a coarse current-tick estimate so the scrubber can
  // animate without polling cs2's console.
  lastTickAtSeek: 0,
  lastSeekRealMs: Date.now(),
  rate: 1,
  paused: false,
  totalTicks: parseInt(process.env.DEMO_TOTAL_TICKS ?? "0", 10) || 0,
  tickRate: parseFloat(process.env.DEMO_TICK_RATE ?? "64") || 64,
  // Bumped on every /demo/* POST. The api's idle reaper compares this
  // against `now()` to decide whether to tear the pod down.
  lastActivityMs: Date.now(),
};
function bumpActivity() { demoState.lastActivityMs = Date.now(); }

// Latest cs2 GSI snapshot. cs2 fires the `gamestate_integration_*.cfg`
// endpoints during demo playback the same as live matches — we get
// real game state instead of having to guess "is the demo playing
// yet" from log scrapes or fd checks. The web side reads
// `gsi.map_phase === "live"` (or any non-null phase) as the
// authoritative "demo is loaded and playing" signal.
const gsiState = {
  lastReceivedMs: 0,
  mapName: null,
  mapPhase: null,        // warmup | live | intermission | gameover
  roundPhase: null,      // freezetime | live | over
  roundNumber: null,     // 0-indexed CS2 demo round counter
  spectatedSteamId: null,
  // Slot → player snapshot derived from GSI's `allplayers` block.
  // `observer_slot` is what cs2 binds to the number-row digit keys
  // (1..9, 0, minus, equal). When the spec target dies and cs2
  // auto-switches to a teammate, observer_slot of the survivors
  // doesn't change — only `spectatedSteamId` updates. So slot 1
  // is always the same player, but they may be dead/alive.
  // Shape: Array<{slot, steam_id, name, team: "T"|"CT", alive, health}>
  // Empty until the first GSI tick lands.
  specSlots: [],
  // Team names from GSI's map.team_{ct,t}.name — set in cs2 by the
  // demo file (mp_teamname_1/2). Source of truth for team labels;
  // the api's lineup names can drift from the actual demo when a
  // demo from a different match was loaded against a match_map row.
  teamCtName: null,
  teamTName: null,
  teamCtScore: 0,
  teamTScore: 0,
  // Phase countdown info from GSI's `phase_countdowns` block. Used by
  // the OBS operator-view HUD to render a round-start / freeze /
  // bomb-detonation / defuse countdown without re-decoding the demo.
  // Shape: { phase: "freezetime"|"live"|"over"|null, phase_ends_in_s: number|null }
  phase: null,
  phaseEndsInS: null,
  // Bomb state (planted/defusing) — exposed for HUDs that draw a
  // dedicated bomb timer. Mirrors GSI's `bomb` block.
  // Shape: { state: "planted"|"defusing"|null, countdown_s: number|null }
  bombState: null,
  bombCountdownS: null,
};

// Per-player snapshot enriched from `allplayers[*].state` for the
// operator-view HUD (money, equip_value, kills/deaths/per-round). Held
// separately from `specSlots` so the existing keyboard/click pathway
// (which only cares about slot+steam_id+team+alive) doesn't pay the
// extra serialization cost. Resets every GSI tick.
let specPlayersExt = [];

// ── F3: round highlight detection ──────────────────────────────────
// Track per-player kill totals from GSI allplayers.match_stats.kills.
// On round_phase "live"→"over" we compute deltas (kills THIS round)
// and flag highlights (2K/3K/4K/Ace). During freeze time, auto-spec
// the round MVP and POST the highlight to the api for the panel.
const highlightState = {
  // Map<steamId, {kills, deaths, name, team}> snapshot taken at the
  // START of each round (round_phase "freezetime"→"live" transition).
  roundStartStats: new Map(),
  // Array of detected highlights for the current match, most recent
  // first. Capped at 200 entries.
  highlights: [],
  // Prevent double-firing on the same round.
  lastProcessedRound: -1,
};

function snapshotRoundStartStats(allPlayers) {
  highlightState.roundStartStats.clear();
  if (!allPlayers || typeof allPlayers !== "object") return;
  for (const [steamId, p] of Object.entries(allPlayers)) {
    if (!p || typeof p !== "object") continue;
    highlightState.roundStartStats.set(steamId, {
      kills: Number(p.match_stats?.kills ?? 0),
      deaths: Number(p.match_stats?.deaths ?? 0),
      name: typeof p.name === "string" ? p.name : steamId,
      team: p.team === "T" || p.team === "CT" ? p.team : null,
    });
  }
}

function detectRoundHighlights(roundNumber, allPlayers) {
  if (!allPlayers || typeof allPlayers !== "object") return [];
  if (highlightState.roundStartStats.size === 0) return [];

  const detected = [];
  const teamSize = {};
  for (const [, p] of Object.entries(allPlayers)) {
    if (!p || typeof p !== "object") continue;
    const t = p.team;
    if (t === "T" || t === "CT") teamSize[t] = (teamSize[t] ?? 0) + 1;
  }

  for (const [steamId, p] of Object.entries(allPlayers)) {
    if (!p || typeof p !== "object") continue;
    const prev = highlightState.roundStartStats.get(steamId);
    if (!prev) continue;
    const killsThisRound =
      Number(p.match_stats?.kills ?? 0) - prev.kills;
    if (killsThisRound < 2) continue;

    const enemyTeam = prev.team === "CT" ? "T" : "CT";
    const enemyCount = teamSize[enemyTeam] ?? 5;
    const isAce = killsThisRound >= enemyCount;

    let label;
    if (isAce) label = "ace";
    else if (killsThisRound >= 4) label = "4k";
    else if (killsThisRound === 3) label = "3k";
    else label = "2k";

    detected.push({
      round: roundNumber,
      steam_id: steamId,
      player_name: prev.name,
      team: prev.team,
      kills: killsThisRound,
      label,
      timestamp: new Date().toISOString(),
    });
  }
  // Sort by kill count descending so the best highlight is first.
  detected.sort((a, b) => b.kills - a.kills);
  return detected;
}

async function postHighlightsToApi(highlights) {
  const matchId = process.env.MATCH_ID;
  const apiBase = process.env.STATUS_API_BASE ?? process.env.API_BASE;
  if (!matchId || !apiBase || highlights.length === 0) return;
  try {
    await fetch(`${apiBase}/matches/${matchId}/highlights`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ highlights }),
      signal: AbortSignal.timeout(5_000),
    });
  } catch (e) {
    process.stderr.write(
      `[spec-server] POST highlights failed: ${e.message}\n`,
    );
  }
}

async function autoSpecHighlightPlayer(highlights) {
  // During freeze time, spec the round MVP so the camera is on them
  // when the next round starts. Find their observer_slot and fire
  // spec_player via xdotool key.
  if (highlights.length === 0) return;
  const mvpSteamId = highlights[0].steam_id;
  const slot = gsiState.specSlots.find((s) => s.steam_id === mvpSteamId);
  if (!slot) return;
  const digitKey = slot.slot <= 9 ? String(slot.slot) : "0";
  try {
    await sendKey(digitKey);
    process.stderr.write(
      `[spec-server] highlights: auto-spec player ${highlights[0].player_name} (slot ${slot.slot})\n`,
    );
  } catch {
    // Non-fatal: cs2 might not have focus, or the slot key isn't bound
    // yet — just keep going so the next round still gets evaluated.
  }
}

// One-shot "tell the api the demo is actually playing now" beacon
// + hide the auto-opened demoui Panorama panel. Fires on the first
// GSI receipt — that's the deterministic "demo loaded and rolling"
// signal we couldn't get from log scrapes. With this gate in place
// we don't have to time anything: GSI lands AFTER the demo panel
// has rendered, so F11 reliably toggles it from visible → hidden.
let demoPlayingReported = false;
// Flips true once the demoui-hide setTimeout has fired AND the
// keystroke has been delivered to cs2. Surfaced in /demo/state.gsi
// as `demoui_hidden`, which the batch-highlights pod polls before
// kicking off the first render — the previous "wait for GSI then
// sleep 4s" was flaky under lag, this is the deterministic signal.
let demouiHidden = false;
async function reportDemoPlayingOnce() {
  if (demoPlayingReported) return;
  demoPlayingReported = true;
  // Pause immediately so the user lands on a known frame; defer the
  // demoui hide so the panel has time to actually render before we
  // toggle it (toggling before paint is a no-op).
  void execCfgCommand("demo_pause").catch(() => undefined);
  setTimeout(() => {
    void execCfgCommand("demoui")
      .catch(() => undefined)
      .finally(() => {
        demouiHidden = true;
      });
  }, 3000);
  // Mirror the pause locally so the tick estimator + scrubber
  // freeze at tick 0 instead of advancing as if playback had
  // started. The web's first /demo/state read after this will see
  // paused=true.
  demoState.paused = true;
  demoState.lastTickAtSeek = 0;
  demoState.lastSeekRealMs = Date.now();

  const sessionId = process.env.DEMO_SESSION_ID;
  const sessionToken = process.env.DEMO_SESSION_TOKEN;
  const apiBase = process.env.STATUS_API_BASE ?? process.env.API_BASE;
  if (!sessionId || !sessionToken || !apiBase) {
    process.stderr.write(
      `[spec-server] reportDemoPlayingOnce: skipping api POST — env missing ` +
        `(DEMO_SESSION_ID=${sessionId ? "set" : "MISSING"} ` +
        `DEMO_SESSION_TOKEN=${sessionToken ? "set" : "MISSING"} ` +
        `STATUS_API_BASE/API_BASE=${apiBase ?? "MISSING"})\n`,
    );
    return;
  }
  const url = `${apiBase}/demo-sessions/${sessionId}/status`;
  try {
    process.stderr.write(`[spec-server] POSTing status=playing to ${url}\n`);
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        // The api validates `x-origin-auth: <id>:<token>` — same
        // format status-reporter.sh uses (see lib/status-reporter.sh).
        // Authorization: Bearer is NOT what this endpoint reads.
        "x-origin-auth": `${sessionId}:${sessionToken}`,
      },
      body: JSON.stringify({ status: "playing" }),
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      process.stderr.write(
        `[spec-server] api POST returned ${res.status}: ${body.slice(0, 200)}\n`,
      );
      return;
    }
    process.stderr.write(
      `[spec-server] reported status=playing + sent demoui+demo_pause for session ${sessionId}\n`,
    );
  } catch (err) {
    process.stderr.write(
      `[spec-server] reportDemoPlayingOnce: api POST failed: ${(err && err.message) || err}\n`,
    );
    // Don't reset demoPlayingReported — F11 already fired, retrying
    // would double-toggle the panel. The api retry is less critical:
    // /demo/state still surfaces gsi.map_phase, web can fall back.
  }
}

// Probe whether cs2 currently has the .dem file open. cs2 keeps the
// demo file open via fd for the entire playback duration, so its
// presence in /proc/<cs2_pid>/fd/ is a reliable "demo is actually
// loaded" signal — no log scraping, no timing guesses.
async function demoLoadedInProc() {
  const wid = await findCs2Window();
  if (!wid) return false;
  // findCs2Window doesn't give us the pid; pgrep does.
  const r = await run(["pgrep", "-f", "/linuxsteamrt64/cs2"]);
  if (r.code !== 0) return false;
  const pid = r.stdout.trim().split("\n")[0];
  if (!pid) return false;
  const demoFile =
    process.env.DEMO_FILE ?? "/tmp/game-streamer/demo.dem";
  // Iterate fds via readdir-equivalent. fs/promises is already in
  // node stdlib; cheaper than spawning ls.
  try {
    const fs = await import("node:fs/promises");
    const fdDir = `/proc/${pid}/fd`;
    const entries = await fs.readdir(fdDir);
    for (const e of entries) {
      try {
        const target = await fs.readlink(`${fdDir}/${e}`);
        if (target === demoFile) return true;
      } catch {
        // Race: fd closed between readdir and readlink. Skip.
      }
    }
  } catch {
    // /proc/<pid>/fd disappeared (cs2 died) or perms issue.
  }
  return false;
}
function estimateCurrentTick() {
  if (demoState.paused) return demoState.lastTickAtSeek;
  const elapsedSec = (Date.now() - demoState.lastSeekRealMs) / 1000;
  return Math.max(
    0,
    Math.round(demoState.lastTickAtSeek + elapsedSec * demoState.rate * demoState.tickRate),
  );
}

// Where run-live.sh drops the accountid -> F-key map after seeding the
// OpenHud DB. Read fresh per request so an operator can rerun the seed
// step mid-stream without restarting this daemon.
const PLAYER_BINDINGS_PATH =
  process.env.SPEC_BINDINGS_PATH ??
  path.join(process.env.LOG_DIR ?? "/tmp/game-streamer", "spec-bindings.json");

/**
 * Run a subcommand with a forced $DISPLAY, capture stdout/stderr.
 * @param {string[]} args
 * @param {{ timeoutMs?: number }} [opts]
 * @returns {Promise<{ code: number | null; stdout: string; stderr: string }>}
 */
function run(args, { timeoutMs = 5000 } = {}) {
  return new Promise((resolve) => {
    const child = spawn(args[0], args.slice(1), {
      env: { ...process.env, DISPLAY },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdoutChunks = [];
    const stderrChunks = [];
    let timer = setTimeout(() => {
      child.kill("SIGKILL");
    }, timeoutMs);
    child.stdout.on("data", (c) => stdoutChunks.push(c));
    child.stderr.on("data", (c) => stderrChunks.push(c));
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({
        code,
        stdout: Buffer.concat(stdoutChunks).toString("utf8"),
        stderr: Buffer.concat(stderrChunks).toString("utf8"),
      });
    });
    child.on("error", () => {
      clearTimeout(timer);
      resolve({ code: -1, stdout: "", stderr: "" });
    });
  });
}

/**
 * Find the cs2 window on $DISPLAY. Tries several strategies because
 * cs2's reported window name varies by game state (menu vs spectator
 * vs demo playback) and xdotool's --name is matched per-property:
 * if WM_NAME differs from _NET_WM_NAME the anchored ^...$ form misses.
 *
 * @returns {Promise<string | null>}
 */
async function findCs2Window() {
  for (const pattern of ["Counter-Strike 2", "Counter-Strike", "cs2"]) {
    const r = await run(["xdotool", "search", "--name", pattern]);
    if (r.code === 0) {
      const ids = r.stdout.trim().split("\n").filter(Boolean);
      if (ids.length) return ids[0];
    }
  }
  const byClass = await run(["xdotool", "search", "--class", "cs2"]);
  if (byClass.code === 0) {
    const ids = byClass.stdout.trim().split("\n").filter(Boolean);
    if (ids.length) return ids[0];
  }
  const tree = await run([
    "xwininfo",
    "-display",
    DISPLAY,
    "-root",
    "-tree",
  ]);
  if (tree.code === 0) {
    for (const line of tree.stdout.split("\n")) {
      if (line.includes('"Counter-Strike 2"')) {
        const id = line.trim().split(/\s+/)[0];
        if (id?.startsWith("0x")) return id;
      }
    }
  }
  process.stderr.write(
    `spec-server: findCs2Window(): no match on DISPLAY=${DISPLAY}\n`,
  );
  const diag = await run(["xdotool", "search", "--name", ".+"]);
  if (diag.code === 0) {
    const names = diag.stdout.trim().split("\n").slice(0, 20);
    process.stderr.write(
      `spec-server: visible window ids on display: ${JSON.stringify(names)}\n`,
    );
  }
  return null;
}

/**
 * Deliver a single keypress to cs2.
 *
 * cs2 holds keyboard focus continuously: the OpenHud overlay
 * BrowserWindow is built with `focusable: false` (see the sed step in
 * openhud/Dockerfile), so even though it's stacked above cs2 it can
 * never receive focus. That means `xdotool key` (XTest, no --window,
 * no focus juggling) goes straight to cs2.
 *
 * Why not XSendEvent (`--window`)? cs2 filters synthetic events, so
 * keys delivered that way are dropped on the floor. Verified against
 * a live cs2 spec session — F-keys from `xdotool key --window <wid>`
 * never fire the bound command.
 *
 * Why not windowfocus/windowactivate? Both cause Electron's
 * transparent overlay to lose its alpha channel (well-known Linux
 * Electron behavior on focus-loss), and windowactivate additionally
 * restacks cs2 on top of the overlay. With the overlay marked
 * non-focusable upstream, neither is ever needed — focus stays on
 * cs2 from launch, the overlay stays composited above.
 *
 * @param {string} key  X11 keysym name (e.g. "F1", "1", "minus")
 * @returns {Promise<boolean>}
 */
async function sendKey(key) {
  if ((await findCs2Window()) === null) return false;
  await run(["xdotool", "key", "--clearmodifiers", key]);
  return true;
}

/**
 * Open cs2's dev console, type a command, hit Return, close the console.
 *
 * Used for demo controls that take a runtime parameter (`demo_gototick
 * <tick>`, arbitrary `host_timescale <rate>`) — these can't be pre-bound
 * to a single F-key the way pause/speed-presets are.
 *
 * Why this is safe even with the OpenHud overlay raised: cs2 holds
 * keyboard focus continuously (overlay is `focusable: false`), so the
 * `xdotool key`/`xdotool type` calls — which target the focused window
 * via XTest — go straight to cs2 without needing windowactivate. The
 * windowactivate path used by lib/xorg.sh:cs2_console_command is only
 * needed when called interactively from a debug shell where cs2 may
 * have lost focus; here we never lose it.
 *
 * @param {string} cmd
 * @returns {Promise<boolean>}
 */
async function sendConsoleCommand(cmd) {
  if ((await findCs2Window()) === null) return false;
  await run(["xdotool", "key", "--clearmodifiers", "grave"]);
  await new Promise((r) => setTimeout(r, 80));
  await run(["xdotool", "type", "--delay", "20", cmd]);
  await new Promise((r) => setTimeout(r, 40));
  await run(["xdotool", "key", "--clearmodifiers", "Return"]);
  await new Promise((r) => setTimeout(r, 60));
  await run(["xdotool", "key", "--clearmodifiers", "grave"]);
  return true;
}

// Fire any console command by writing it to 5stack_exec.cfg + sending
// BACKSPACE (autoexec binds it to `exec 5stack_exec`). One cmd per
// line — `;`-joined lines were being mis-parsed across cs2 builds.
//
// Concurrent calls are serialised through `execCfgChain`. Without the
// mutex, two in-flight calls can interleave: call A renames its file
// in, call B renames its (different) file in, call A's BACKSPACE fires
// → cs2 reads B's contents. The 30ms tail delay holds the lock just
// past the xdotool return so cs2 has time to actually read the cfg
// before the next writer races in.
let execCfgChain = Promise.resolve();
async function execCfgCommand(cmd) {
  const prev = execCfgChain;
  let release;
  execCfgChain = new Promise((r) => {
    release = r;
  });
  try {
    await prev.catch(() => undefined);
    return await execCfgCommandImpl(cmd);
  } finally {
    setTimeout(release, 30);
  }
}

async function execCfgCommandImpl(cmd) {
  if (!EXEC_CFG_PATH) {
    process.stderr.write(
      `[spec-server] execCfgCommand: CS2_CFG_DIR not set — falling back to sendConsoleCommand\n`,
    );
    return sendConsoleCommand(cmd);
  }
  if ((await findCs2Window()) === null) return false;
  const lines = cmd
    .split(";")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  const body = lines.join("\n") + "\n";
  try {
    const tmp = `${EXEC_CFG_PATH}.tmp`;
    writeFileSync(tmp, body, "utf8");
    renameSync(tmp, EXEC_CFG_PATH);
  } catch (err) {
    process.stderr.write(
      `[spec-server] execCfgCommand: write failed (${(err && err.message) || err}) — falling back to typed console\n`,
    );
    return sendConsoleCommand(cmd);
  }
  process.stderr.write(
    `[spec-server] execCfgCommand wrote ${lines.length} cmd(s): ${lines.map((l) => `\`${l}\``).join(" ")}\n`,
  );
  await run(["xdotool", "key", "--clearmodifiers", EXEC_CFG_KEY]);
  return true;
}

/**
 * Read the round_ticks sidecar (written by run-demo.sh from $ROUND_TICKS).
 * @returns {Array<{round: number, start_tick: number, end_tick: number}>}
 */
function loadRoundTicks() {
  try {
    const raw = readFileSync(DEMO_ROUND_TICKS_PATH, "utf8").trim();
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/**
 * Read the accountid -> keysym map written by run-live.sh after the
 * match-metadata seed. Returns an empty map if the file is missing or
 * malformed; callers treat that as "no per-player binds available"
 * and 404 the request.
 * @returns {Record<string, string>}
 */
function loadPlayerBindings() {
  try {
    const raw = readFileSync(PLAYER_BINDINGS_PATH, "utf8");
    const parsed = JSON.parse(raw);
    return parsed?.accountid_to_key ?? {};
  } catch {
    return {};
  }
}

const CORS_HEADERS = {
  // Permissive CORS — the daemon is firewalled by the K8s Service /
  // Ingress that fronts it, not at the application layer.
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function sendJson(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, {
    "Content-Type": "application/json",
    "Content-Length": String(body.length),
    ...CORS_HEADERS,
  });
  res.end(body);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error("invalid json"));
      }
    });
    req.on("error", reject);
  });
}

const server = createServer(async (req, res) => {
  const method = req.method ?? "GET";
  const url = req.url ?? "/";
  const log = (line) => {
    process.stderr.write(`[spec-server] ${method} ${url} ${line}\n`);
  };

  try {
    if (method === "OPTIONS") {
      sendJson(res, 204, {});
      return;
    }

    if (method === "GET" && (url === "/" || url === "/health" || url === "/spec/health")) {
      const wid = await findCs2Window();
      const bindings = loadPlayerBindings();
      sendJson(res, 200, {
        ok: true,
        display: DISPLAY,
        cs2_window: wid,
        cs2_running: wid !== null,
        player_bindings: Object.keys(bindings).length,
      });
      log(`-> 200 (cs2_running=${wid !== null}, player_bindings=${Object.keys(bindings).length})`);
      return;
    }

    if (method === "GET" && url === "/demo/state") {
      // demo_loaded comes from GSI when we have a recent event;
      // /proc/<pid>/fd is the fallback for the brief window before
      // the first GSI tick lands.
      const gsiFresh =
        gsiState.lastReceivedMs > 0 &&
        Date.now() - gsiState.lastReceivedMs < 30_000;
      const demoLoaded =
        gsiFresh && gsiState.mapPhase != null
          ? true
          : await demoLoadedInProc();
      sendJson(res, 200, {
        tick: estimateCurrentTick(),
        total_ticks: demoState.totalTicks,
        tick_rate: demoState.tickRate,
        rate: demoState.rate,
        paused: demoState.paused,
        last_activity_ms_ago: Date.now() - demoState.lastActivityMs,
        demo_loaded: demoLoaded,
        gsi: gsiFresh
          ? {
              map_name: gsiState.mapName,
              map_phase: gsiState.mapPhase,
              round_phase: gsiState.roundPhase,
              round_number: gsiState.roundNumber,
              spectated_steam_id: gsiState.spectatedSteamId,
              last_received_ms_ago: Date.now() - gsiState.lastReceivedMs,
              spec_slots: gsiState.specSlots,
              spec_players_ext: specPlayersExt,
              team_ct_name: gsiState.teamCtName,
              team_t_name: gsiState.teamTName,
              team_ct_score: gsiState.teamCtScore,
              team_t_score: gsiState.teamTScore,
              phase: gsiState.phase,
              phase_ends_in_s: gsiState.phaseEndsInS,
              bomb_state: gsiState.bombState,
              bomb_countdown_s: gsiState.bombCountdownS,
              // True once the post-GSI demoui-toggle has been
              // delivered to cs2. The batch-highlights pod waits on
              // this before starting its first capture so we don't
              // record the demo panorama panel.
              demoui_hidden: demouiHidden,
            }
          : null,
      });
      return;
    }

    // F3: query in-memory highlights detected by GSI round tracking.
    if (method === "GET" && url === "/highlights") {
      sendJson(res, 200, {
        highlights: highlightState.highlights,
        last_processed_round: highlightState.lastProcessedRound,
      });
      return;
    }

    // F4: cinematic camera status — what map is the flythrough on,
    // how long has it been running, has it finished?
    if (method === "GET" && url === "/cinematic/status") {
      sendJson(res, 200, getCinematicStatus());
      return;
    }

    if (method !== "POST") {
      sendJson(res, 404, { error: "not found" });
      log("-> 404");
      return;
    }

    // Parse the request body up-front for *all* POST handlers below so
    // that no handler hits the temporal-dead-zone of a `let body` that
    // is only declared further down in the same try-block.
    let body;
    try {
      body = await readJsonBody(req);
    } catch {
      sendJson(res, 400, { error: "invalid json" });
      log("-> 400 invalid json");
      return;
    }

    // F4: kick off a live spectator-camera flythrough using a map's
    // waypoint plan. The plan is loaded by name from
    // /opt/5stack/intros/<map>.cinematic.json (hostPath override) or
    // src/cinematic-paths/<map>.json (baked-in default). Body:
    // { "map": "de_mirage" }. Returns 202 + status; the cinematic
    // runs asynchronously while ximagesrc keeps capturing the cs2
    // window into the live HLS stream.
    if (url === "/cinematic/start") {
      const mapName =
        typeof body?.map === "string" ? body.map : gsiState.mapName;
      if (!mapName) {
        sendJson(res, 400, { error: "map required (no GSI map yet)" });
        return;
      }
      sendJson(res, 202, { ok: true, map: mapName });
      // Fire-and-forget so the HTTP request returns immediately.
      void runCinematic(mapName, (line) =>
        log(`cinematic: ${line}`),
      ).catch((err) => log(`cinematic error: ${err.message ?? err}`));
      return;
    }

    if (url === "/cinematic/stop") {
      const stopped = stopCinematic();
      sendJson(res, 200, { ok: true, stopped });
      return;
    }

    // F4-related fix: Steam occasionally drops the +connect launch
    // arg when -applaunch hands off to an already-running Steam
    // process; cs2 then sits at the main menu and the live stream
    // shows the menu instead of the game. run-live.sh polls the GSI
    // freshness in /demo/state and re-issues `connect <addr>` /
    // `password <pwd>` through this endpoint when GSI stays cold for
    // too long. Body: { "addr": "1.2.3.4:27015", "password": "..." }.
    if (url === "/spec/connect") {
      const addr = typeof body?.addr === "string" ? body.addr.trim() : "";
      const password =
        typeof body?.password === "string" ? body.password : "";
      // Match cs2's `<host>:<port>` form. Reject anything else so a
      // typo doesn't leak shell-meta into execCfgCommand.
      if (!/^[A-Za-z0-9.\-]+:\d{1,5}$/.test(addr)) {
        sendJson(res, 400, { error: "addr (host:port) required" });
        log("-> 400 connect bad addr");
        return;
      }
      // Strip quotes / newlines / shell-meta from the password so it
      // can't bust out of the cfg line. UUID match passwords don't
      // contain any of these, but be defensive in case the schema
      // changes later.
      const cleanPassword = password.replace(/[\r\n";]/g, "");
      // execCfgCommand splits on `;` into separate lines in the same
      // 5stack_exec.cfg write — cs2 then `exec`s the file once and
      // both commands run on the same engine tick. Issuing them as
      // *two* execCfgCommand calls would have the second write
      // (connect) overwrite the first (password) before cs2 saw it.
      const combined = cleanPassword
        ? `password ${cleanPassword}; connect ${addr}`
        : `connect ${addr}`;
      const ok = await execCfgCommand(combined);
      sendJson(
        res,
        ok ? 200 : 503,
        ok ? { ok, addr } : { error: "cs2 not running" },
      );
      log(`-> ${ok ? 200 : 503} connect ${addr}`);
      return;
    }

    if (url === "/spec/click") {
      const key = body.button === "right" ? KEY_SPEC_PREV : KEY_SPEC_NEXT;
      const ok = await sendKey(key);
      sendJson(res, ok ? 200 : 503, ok ? { ok, key } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} click (${key})`);
      return;
    }

    if (url === "/spec/jump") {
      const ok = await sendKey(KEY_SPEC_JUMP);
      sendJson(res, ok ? 200 : 503, ok ? { ok, key: KEY_SPEC_JUMP } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} jump`);
      return;
    }

    if (url === "/spec/player") {
      const aidInt = Number.parseInt(body.accountid, 10);
      if (!Number.isFinite(aidInt)) {
        sendJson(res, 400, { error: "accountid (int) required" });
        log("-> 400 bad accountid");
        return;
      }
      const key = loadPlayerBindings()[String(aidInt)];
      if (!key) {
        sendJson(res, 404, {
          error: `no key bound for accountid ${aidInt}`,
          hint: "rerun match-metadata seed so per-player binds get written",
        });
        log(`-> 404 player ${aidInt} (not in bindings map)`);
        return;
      }
      const ok = await sendKey(key);
      sendJson(res, ok ? 200 : 503, { ok, accountid: aidInt, key });
      log(`-> ${ok ? 200 : 503} player ${aidInt} (${key})`);
      return;
    }

    if (url === "/spec/slot") {
      const slotInt = Number.parseInt(body.slot, 10);
      if (!Number.isFinite(slotInt)) {
        sendJson(res, 400, { error: "slot (int 1..12) required" });
        log("-> 400 bad slot");
        return;
      }
      if (slotInt < 1 || slotInt > 12) {
        sendJson(res, 400, { error: "slot must be 1..12" });
        log("-> 400 slot out of range");
        return;
      }
      // CS2's default spec keybinds: number row keys map directly to
      // slots. xdotool key names: digits are "1".."9","0", and the
      // bindings in resources/observer.cfg use "minus" and "equal" for
      // 11/12.
      const SLOT_KEYS = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "minus", "equal",
      ];
      const key = SLOT_KEYS[slotInt - 1];
      const ok = await sendKey(key);
      sendJson(res, ok ? 200 : 503, ok ? { ok, slot: slotInt, key } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} slot ${slotInt} (key ${key})`);
      return;
    }

    if (url === "/spec/autodirector") {
      const enabled = Boolean(body.enabled);
      const key = enabled ? KEY_AUTODIRECTOR_ON : KEY_AUTODIRECTOR_OFF;
      const ok = await sendKey(key);
      sendJson(res, ok ? 200 : 503, ok ? { ok, enabled, key } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} autodirector ${enabled} (${key})`);
      return;
    }

    // ---- /demo/* — demo-playback controls ----
    // Most run on cs2 console commands rather than F-key binds because
    // they take parameters (tick, rate). Pause/speed-presets have F-key
    // binds and use the safe sendKey path.

    if (url === "/demo/toggle") {
      const ok = await sendKey(KEY_DEMO_TOGGLE);
      if (ok) {
        demoState.paused = !demoState.paused;
        // Snapshot the current estimated tick at the moment we paused
        // so resume picks up from the right place.
        if (demoState.paused) demoState.lastTickAtSeek = estimateCurrentTick();
        demoState.lastSeekRealMs = Date.now();
        bumpActivity();
      }
      sendJson(res, ok ? 200 : 503, ok ? { ok, paused: demoState.paused } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/toggle (paused=${demoState.paused})`);
      return;
    }

    if (url === "/demo/pause") {
      let ok = true;
      if (body.force === true) {
        ok = await execCfgCommand("demo_pause");
        if (ok) {
          demoState.lastTickAtSeek = estimateCurrentTick();
          demoState.paused = true;
          demoState.lastSeekRealMs = Date.now();
        }
      } else if (!demoState.paused) {
        ok = await sendKey(KEY_DEMO_TOGGLE);
        if (ok) {
          demoState.lastTickAtSeek = estimateCurrentTick();
          demoState.paused = true;
          demoState.lastSeekRealMs = Date.now();
        }
      }
      bumpActivity();
      sendJson(res, ok ? 200 : 503, ok ? { ok, paused: true } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/pause${body.force === true ? " (force)" : ""}`);
      return;
    }

    if (url === "/demo/resume") {
      let ok = true;
      if (body.force === true) {
        ok = await execCfgCommand("demo_resume");
        if (ok) {
          demoState.paused = false;
          demoState.lastSeekRealMs = Date.now();
        }
      } else if (demoState.paused) {
        ok = await sendKey(KEY_DEMO_TOGGLE);
        if (ok) {
          demoState.paused = false;
          demoState.lastSeekRealMs = Date.now();
        }
      }
      bumpActivity();
      sendJson(res, ok ? 200 : 503, ok ? { ok, paused: false } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/resume${body.force === true ? " (force)" : ""}`);
      return;
    }

    if (url === "/demo/seek") {
      const tick = Number.parseInt(body.tick, 10);
      if (!Number.isFinite(tick) || tick < 0) {
        sendJson(res, 400, { error: "tick (non-negative int) required" });
        log("-> 400 demo/seek bad tick");
        return;
      }
      let cmd = `demo_gototick ${tick}`;
      let nextPaused = demoState.paused;
      if (body.pause_after === true) {
        cmd = `demo_gototick ${tick} 0 1`;
        nextPaused = true;
      } else if (body.pause_after === false) {
        cmd = `demo_gototick ${tick} 0 0`;
        nextPaused = false;
      }
      const ok = await execCfgCommand(cmd);
      if (ok) {
        demoState.lastTickAtSeek = tick;
        demoState.lastSeekRealMs = Date.now();
        demoState.paused = nextPaused;
        bumpActivity();
      }
      sendJson(
        res,
        ok ? 200 : 503,
        ok
          ? { ok, tick, paused: nextPaused }
          : { error: "cs2 not running" },
      );
      log(`-> ${ok ? 200 : 503} demo/seek tick=${tick} cmd="${cmd}"`);
      return;
    }

    if (url === "/demo/skip") {
      const secs = Number.parseFloat(body.secs);
      if (!Number.isFinite(secs)) {
        sendJson(res, 400, { error: "secs (number) required" });
        log("-> 400 demo/skip bad secs");
        return;
      }
      // Bound keys for ±15s, the operator-friendly defaults. Anything
      // else falls back to typed console (rare / debug).
      let ok;
      let via;
      if (secs === -15 || secs === 15) {
        const key = secs < 0 ? KEY_DEMO_SKIP_BACK : KEY_DEMO_SKIP_FWD;
        ok = await sendKey(key);
        via = `key:${key}`;
      } else {
        const target = Math.max(
          0,
          estimateCurrentTick() + Math.round(secs * demoState.tickRate),
        );
        ok = await execCfgCommand(`demo_gototick ${target}`);
        via = "exec-cfg";
      }
      if (ok) {
        // Estimator drift: bump tick by approximation. Real tick will
        // resync on next /demo/state poll.
        demoState.lastTickAtSeek = Math.max(
          0,
          estimateCurrentTick() + Math.round(secs * demoState.tickRate),
        );
        demoState.lastSeekRealMs = Date.now();
        bumpActivity();
      }
      sendJson(res, ok ? 200 : 503, ok ? { ok, secs, via } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/skip secs=${secs} (${via})`);
      return;
    }

    if (url === "/demo/speed") {
      const rate = Number.parseFloat(body.rate);
      if (!Number.isFinite(rate) || rate <= 0) {
        sendJson(res, 400, { error: "rate (positive number) required" });
        log("-> 400 demo/speed bad rate");
        return;
      }
      // Clamp aggressively — host_timescale beyond 8 destabilises cs2's
      // physics tick + audio sync, and below 0.1 is indistinguishable
      // from a near-pause for the operator.
      const clamped = Math.min(8, Math.max(0.1, rate));
      // Snapshot tick BEFORE changing rate so the estimator stays
      // continuous across the transition.
      demoState.lastTickAtSeek = estimateCurrentTick();
      demoState.lastSeekRealMs = Date.now();
      const presetKey = SPEED_KEY_BY_RATE[String(clamped)];
      const ok = presetKey
        ? await sendKey(presetKey)
        : await execCfgCommand(`host_timescale ${clamped}`);
      if (ok) {
        demoState.rate = clamped;
        bumpActivity();
      }
      sendJson(
        res,
        ok ? 200 : 503,
        ok ? { ok, rate: clamped, via: presetKey ? "key" : "console" } : { error: "cs2 not running" },
      );
      log(`-> ${ok ? 200 : 503} demo/speed rate=${clamped} (${presetKey ? "key" : "console"})`);
      return;
    }

    if (url === "/demo/reload") {
      const ok = await execCfgCommand(
        `playdemo /tmp/game-streamer/demo.dem`,
      );
      if (ok) {
        demoState.lastTickAtSeek = 0;
        demoState.lastSeekRealMs = Date.now();
        demoState.paused = false;
        // Re-arm the post-GSI demoui-hide path. cs2 re-shows the
        // panorama panel on `playdemo`, and the next GSI tick is what
        // tells us the demo is loaded again — without resetting these
        // we'd answer `demoui_hidden=true` against a panel that's now
        // back on screen, and the batch-highlights pod would record
        // the panel into its first capture.
        demoPlayingReported = false;
        demouiHidden = false;
        bumpActivity();
      }
      sendJson(res, ok ? 200 : 503, ok ? { ok } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/reload`);
      return;
    }

    if (url === "/demo/xray") {
      // Bound to F12 → `toggle spec_show_xray 0 1`. We don't need to
      // know cs2's current value — the bind cycles 0↔1 on each press.
      // The web side tracks "should xray be on" locally; we emit a
      // single keypress per intent change so the cycles stay in sync.
      const ok = await sendKey(KEY_XRAY_TOGGLE);
      if (ok) bumpActivity();
      sendJson(
        res,
        ok ? 200 : 503,
        ok ? { ok, enabled: Boolean(body.enabled) } : { error: "cs2 not running" },
      );
      log(`-> ${ok ? 200 : 503} demo/xray (key F12)`);
      return;
    }

    if (url === "/gsi") {
      // cs2 GSI POSTs land here — we parse out the bits we care about
      // (map phase, round phase, currently-spectated steamid) and
      // mirror them on demoState for the /demo/state consumer.
      // No auth check: cs2 only POSTs to localhost from inside the
      // pod, the listener binds to 0.0.0.0 but the K8s NetworkPolicy
      // blocks external traffic.
      const map = body?.map ?? {};
      const round = body?.round ?? {};
      const player = body?.player ?? {};
      const allPlayers = body?.allplayers ?? null;
      const prevMapPhase = gsiState.mapPhase;
      const prevRoundPhase = gsiState.roundPhase;
      const wasReceiving = gsiState.lastReceivedMs > 0;
      gsiState.lastReceivedMs = Date.now();
      gsiState.mapName = typeof map.name === "string" ? map.name : null;
      gsiState.mapPhase = typeof map.phase === "string" ? map.phase : null;
      gsiState.roundPhase =
        typeof round.phase === "string" ? round.phase : null;
      gsiState.roundNumber =
        typeof map.round === "number" ? map.round : null;
      gsiState.spectatedSteamId =
        typeof player.steamid === "string" ? player.steamid : null;
      // Team names + scores ride along on `map`. cs2 sets these from
      // the demo's mp_teamname_1/2 cvars, so they reflect the demo
      // file rather than whatever the api thinks the match was.
      gsiState.teamCtName =
        typeof map?.team_ct?.name === "string" ? map.team_ct.name : null;
      gsiState.teamTName =
        typeof map?.team_t?.name === "string" ? map.team_t.name : null;
      gsiState.teamCtScore = Number(map?.team_ct?.score ?? 0) || 0;
      gsiState.teamTScore = Number(map?.team_t?.score ?? 0) || 0;
      // Phase + countdown for OBS operator-view HUD.
      const pc = body?.phase_countdowns ?? null;
      gsiState.phase =
        typeof pc?.phase === "string" ? pc.phase : null;
      const phaseEndsRaw = pc?.phase_ends_in;
      gsiState.phaseEndsInS =
        typeof phaseEndsRaw === "string"
          ? Number.parseFloat(phaseEndsRaw) || 0
          : typeof phaseEndsRaw === "number"
            ? phaseEndsRaw
            : null;
      // Bomb state — string fields per cs2 GSI.
      const bomb = body?.bomb ?? null;
      gsiState.bombState =
        typeof bomb?.state === "string" ? bomb.state : null;
      const bombCountdownRaw = bomb?.countdown;
      gsiState.bombCountdownS =
        typeof bombCountdownRaw === "string"
          ? Number.parseFloat(bombCountdownRaw) || 0
          : typeof bombCountdownRaw === "number"
            ? bombCountdownRaw
            : null;
      // Build the slot snapshot. `allplayers` is keyed by steamid64 and
      // each entry has `observer_slot` — in CS2 GSI this is 0-indexed,
      // i.e. the player on key "1" reports observer_slot=0, key "2"
      // reports 1, ..., key "0" (the 10th player) reports 9. cs2's
      // built-in digit keybinds drive `spec_player <slot+1>`, so we
      // simply add 1 to land on the 1..10 numbering the buttons fire.
      if (allPlayers && typeof allPlayers === "object") {
        const slots = [];
        const ext = [];
        for (const [steamId, p] of Object.entries(allPlayers)) {
          if (!p || typeof p !== "object") continue;
          const raw = p.observer_slot;
          if (typeof raw !== "number") continue;
          const slot = raw + 1;
          if (slot < 1 || slot > 12) continue;
          const team = p.team === "T" || p.team === "CT" ? p.team : null;
          const state = p.state ?? {};
          const health = Number(state.health ?? 0);
          slots.push({
            slot,
            steam_id: steamId,
            name: typeof p.name === "string" ? p.name : null,
            team,
            alive: health > 0,
            health,
          });
          // weapons[*] = { name, paintkit, type, state, ammo_clip,... }
          // We extract just the weapon names + the "active" weapon for
          // the operator HUD; ammo and paintkit aren't useful overlay
          // data (and bloat the JSON).
          const weapons = [];
          let activeWeapon = null;
          if (p.weapons && typeof p.weapons === "object") {
            for (const wRaw of Object.values(p.weapons)) {
              if (!wRaw || typeof wRaw !== "object") continue;
              const wName =
                typeof wRaw.name === "string" ? wRaw.name : null;
              if (!wName) continue;
              const wType =
                typeof wRaw.type === "string" ? wRaw.type : null;
              weapons.push({ name: wName, type: wType });
              if (wRaw.state === "active") {
                activeWeapon = wName;
              }
            }
          }
          const matchStats = p.match_stats ?? {};
          ext.push({
            slot,
            steam_id: steamId,
            name: typeof p.name === "string" ? p.name : null,
            team,
            alive: health > 0,
            health,
            armor: Number(state.armor ?? 0),
            helmet: !!state.helmet,
            money: Number(state.money ?? 0),
            equip_value: Number(state.equip_value ?? 0),
            round_kills: Number(state.round_kills ?? 0),
            round_killhs: Number(state.round_killhs ?? 0),
            kills: Number(matchStats.kills ?? 0),
            assists: Number(matchStats.assists ?? 0),
            deaths: Number(matchStats.deaths ?? 0),
            mvps: Number(matchStats.mvps ?? 0),
            score: Number(matchStats.score ?? 0),
            weapons,
            active_weapon: activeWeapon,
            defusekit: !!state.defusekit,
          });
        }
        slots.sort((a, b) => a.slot - b.slot);
        ext.sort((a, b) => a.slot - b.slot);
        gsiState.specSlots = slots;
        specPlayersExt = ext;
      }
      // F3 highlight detection: anchor stats at the start of each round
      // and detect multi-kills when the round ends. Both transitions
      // need fresh allplayers from the current GSI tick (`body`).
      if (
        prevRoundPhase !== "live" &&
        gsiState.roundPhase === "live" &&
        allPlayers
      ) {
        snapshotRoundStartStats(allPlayers);
      }
      if (
        prevRoundPhase === "live" &&
        gsiState.roundPhase === "over" &&
        allPlayers &&
        gsiState.roundNumber !== highlightState.lastProcessedRound
      ) {
        const detected = detectRoundHighlights(
          gsiState.roundNumber ?? -1,
          allPlayers,
        );
        highlightState.lastProcessedRound = gsiState.roundNumber ?? -1;
        if (detected.length > 0) {
          highlightState.highlights = [
            ...detected,
            ...highlightState.highlights,
          ].slice(0, 200);
          log(
            `  highlights round ${gsiState.roundNumber}: ` +
              detected
                .map((h) => `${h.label}(${h.player_name}/${h.kills}k)`)
                .join(" "),
          );
          void postHighlightsToApi(detected);
          void autoSpecHighlightPlayer(detected);
        }
      }

      bumpActivity();
      sendJson(res, 200, { ok: true });
      // Only fire the "playing" beacon once we have REAL game data.
      // cs2's first GSI event sometimes lands with empty map/phase
      // (just provider + spec steamid) — firing on that one would
      // F11-toggle the demoui panel before it's actually rendered,
      // and report status=playing while the demo is still loading.
      // Wait for `map.name` AND `map.phase` to be populated; that's
      // cs2 confirming a real demo context exists.
      if (gsiState.mapName && gsiState.mapPhase) {
        void reportDemoPlayingOnce();
      }
      // Log first event verbosely so we can confirm GSI is wired up,
      // then transition-only after to keep the log readable at 10Hz.
      if (!wasReceiving) {
        log(
          `-> 200 gsi FIRST EVENT received — map=${gsiState.mapName ?? "?"} ` +
            `phase=${gsiState.mapPhase ?? "?"} round=${gsiState.roundNumber ?? "?"} ` +
            `spec=${gsiState.spectatedSteamId ?? "?"}`,
        );
      } else if (
        prevMapPhase !== gsiState.mapPhase ||
        prevRoundPhase !== gsiState.roundPhase
      ) {
        log(
          `-> 200 gsi map=${gsiState.mapName ?? "?"}/${gsiState.mapPhase ?? "?"} ` +
            `round=${gsiState.roundNumber ?? "?"}/${gsiState.roundPhase ?? "?"}`,
        );
      }
      return;
    }

    if (url === "/demo/exec") {
      const cmd = typeof body.cmd === "string" ? body.cmd : "";
      if (!cmd.trim()) {
        sendJson(res, 400, { error: "cmd (string) required" });
        log("-> 400 demo/exec missing cmd");
        return;
      }
      const ok = await execCfgCommand(cmd);
      bumpActivity();
      sendJson(res, ok ? 200 : 503, ok ? { ok } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/exec (${cmd.length} chars)`);
      return;
    }

    if (url === "/demo/render-clip") {
      const jobId = String(body.job_id ?? "");
      const token = String(body.token ?? "");
      const apiBase = String(body.api_base ?? "");
      const outputDims = String(body.output_dims ?? "1920x1080");
      const outputFps = Number.parseInt(body.output_fps, 10) || 60;
      const renderSpeedRaw = Number.parseInt(body.render_speed, 10);
      const renderSpeed =
        Number.isFinite(renderSpeedRaw) && renderSpeedRaw >= 1
          ? Math.min(renderSpeedRaw, 4)
          : 2;
      // Accept either `segments: [{start_tick,end_tick}, ...]` (the
      // multi-segment editor's payload) or the legacy
      // start_tick/end_tick pair (older callers + scripts). Normalise
      // to a clean array before serialising for the bash script.
      let segments = Array.isArray(body.segments) ? body.segments : null;
      if (!segments && body.start_tick != null && body.end_tick != null) {
        segments = [{ start_tick: body.start_tick, end_tick: body.end_tick }];
      }
      const cleaned = (segments ?? [])
        .map((s) => ({
          start_tick: Number.parseInt(s?.start_tick, 10),
          end_tick: Number.parseInt(s?.end_tick, 10),
          pov_steam_id:
            typeof s?.pov_steam_id === "string" ? s.pov_steam_id : null,
        }))
        .filter(
          (s) =>
            Number.isFinite(s.start_tick) &&
            Number.isFinite(s.end_tick) &&
            s.end_tick > s.start_tick,
        )
        // Keep declared order — the editor emits already-sorted, but
        // a preset generator might intentionally re-order (unlikely
        // for v1, but cheap to preserve).
        ;
      if (!jobId || !token || !apiBase || cleaned.length === 0) {
        sendJson(res, 400, {
          error:
            "job_id, token, api_base, and at least one valid segment required",
        });
        log("-> 400 demo/render-clip bad payload");
        return;
      }
      const cs2Wid = await findCs2Window();
      if (!cs2Wid) {
        sendJson(res, 503, { error: "cs2 not running" });
        log("-> 503 demo/render-clip cs2 down");
        return;
      }
      const scriptPath = `${process.env.SRC_DIR ?? "/opt/game-streamer/src"}/lib/inline-clip-render.sh`;
      const child = spawn(
        "bash",
        [scriptPath],
        {
          detached: true,
          stdio: ["ignore", "inherit", "inherit"],
          env: {
            ...process.env,
            CLIP_RENDER_JOB_ID: jobId,
            CLIP_RENDER_TOKEN: token,
            STATUS_API_BASE: apiBase,
            CLIP_SEGMENTS: JSON.stringify(cleaned),
            CLIP_OUTPUT_DIMS: outputDims,
            CLIP_OUTPUT_FPS: String(outputFps),
            CLIP_TICK_RATE: String(demoState.tickRate || 64),
            SPEC_SERVER_URL: `http://127.0.0.1:${PORT}`,
            CLIP_RENDER_SPEED: String(renderSpeed),
          },
        },
      );
      child.unref();
      bumpActivity();
      sendJson(res, 202, { ok: true, job_id: jobId, pid: child.pid });
      const totalTicks = cleaned.reduce(
        (acc, s) => acc + (s.end_tick - s.start_tick),
        0,
      );
      log(
        `-> 202 demo/render-clip job=${jobId} pid=${child.pid} ` +
          `segments=${cleaned.length} total_ticks=${totalTicks} speed=${renderSpeed}x`,
      );
      return;
    }

    if (url === "/demo/demoui") {
      // Manual demoui toggle — operator override for when the
      // automatic post-load / post-reload F11 doesn't catch the
      // panel render. F11 is bound to `demoui` in autoexec.
      const ok = await sendKey("F11");
      if (ok) bumpActivity();
      sendJson(res, ok ? 200 : 503, ok ? { ok } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/demoui (key F11)`);
      return;
    }

    if (url === "/spec/hud") {
      // Toggle the OpenHud BrowserWindow's visibility. Find the overlay
      // window by WM_CLASS=openhud + a 1280x720+ size floor (matches
      // openhud.sh:find_openhud_overlay_window). xdotool windowmap /
      // windowunmap is the cheapest toggle that doesn't restack cs2.
      const visible = Boolean(body.visible);
      const tree = await run([
        "xwininfo",
        "-display",
        DISPLAY,
        "-root",
        "-tree",
      ]);
      let overlayId = null;
      if (tree.code === 0) {
        for (const line of tree.stdout.split("\n")) {
          const m = line.match(/^\s*(0x[0-9a-f]+)\s.*?(\d+)x(\d+)\+/);
          if (!m) continue;
          if (!/openhud/i.test(line)) continue;
          const w = Number(m[2]);
          const h = Number(m[3]);
          if (w >= 1280 && h >= 720) {
            overlayId = m[1];
            break;
          }
        }
      }
      if (!overlayId) {
        sendJson(res, 404, { error: "no openhud overlay window" });
        log("-> 404 spec/hud (no overlay window)");
        return;
      }
      const action = visible ? "windowmap" : "windowunmap";
      await run(["xdotool", action, overlayId]);
      bumpActivity();
      sendJson(res, 200, { ok: true, visible, window: overlayId });
      log(`-> 200 spec/hud visible=${visible} (${overlayId})`);
      return;
    }

    if (url === "/demo/round") {
      const round = Number.parseInt(body.round, 10);
      if (!Number.isFinite(round) || round < 1) {
        sendJson(res, 400, { error: "round (int >= 1) required" });
        log("-> 400 demo/round bad round");
        return;
      }
      const map = loadRoundTicks();
      const entry = map.find((r) => r.round === round);
      if (!entry) {
        sendJson(res, 404, {
          error: `no tick mapping for round ${round}`,
          hint: "demo metadata not parsed yet — try again in a few seconds",
        });
        log(`-> 404 demo/round ${round} (not in ticks map; have ${map.length})`);
        return;
      }
      const ok = await execCfgCommand(`demo_gototick ${entry.start_tick}`);
      if (ok) {
        demoState.lastTickAtSeek = entry.start_tick;
        demoState.lastSeekRealMs = Date.now();
        bumpActivity();
      }
      sendJson(res, ok ? 200 : 503, ok ? { ok, round, tick: entry.start_tick } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/round ${round} -> tick ${entry.start_tick}`);
      return;
    }

    sendJson(res, 404, { error: "not found" });
    log("-> 404");
  } catch (err) {
    process.stderr.write(
      `spec-server: handler threw ${(err && err.stack) || err}\n`,
    );
    if (!res.headersSent) {
      sendJson(res, 500, { error: "internal" });
    }
  }
});

server.listen(PORT, BIND, () => {
  process.stderr.write(
    `[spec-server] listening on ${BIND}:${PORT} (display=${DISPLAY})\n`,
  );
  process.stderr.write(
    `[spec-server] player bindings file: ${PLAYER_BINDINGS_PATH}\n`,
  );
  process.stderr.write(
    `[spec-server] routes: GET /, /health, /spec/health, /demo/state | ` +
      `POST /spec/{click,jump,player,slot,autodirector,hud}, ` +
      `/demo/{toggle,pause,resume,seek,skip,speed,round,reload,xray,demoui,render-clip,exec}, /gsi\n`,
  );
});

// Watchdog: warn periodically if cs2 has been up for a while but no
// GSI events have arrived. Helps catch misconfigured cfg files /
// missing auth blocks / wrong port — instead of silently never
// firing the demo-loaded signal.
let gsiWatchdogTicks = 0;
setInterval(async () => {
  if (gsiState.lastReceivedMs > 0) return;
  const wid = await findCs2Window();
  if (!wid) return;
  gsiWatchdogTicks++;
  if (gsiWatchdogTicks === 1 || gsiWatchdogTicks % 6 === 0) {
    process.stderr.write(
      `[spec-server] WARN: cs2 has been up for ${gsiWatchdogTicks * 10}s but ` +
        `no GSI events received yet on /gsi — check ` +
        `cfg/gamestate_integration_5stack.cfg + spec-server port\n`,
    );
  }
}, 10_000);

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    server.close(() => process.exit(0));
  });
}
