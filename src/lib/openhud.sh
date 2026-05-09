# shellcheck shell=bash
# OpenHud (CS2 spectator HUD) helpers. The HUD is an Electron app that
# runs an Express+Socket.io server on $OPENHUD_PORT (default 1349) and
# renders a transparent BrowserWindow loading http://localhost:$PORT/api/hud
# directly on the X display. We start it on the same Xorg-dummy that CS2
# is on, so ximagesrc captures CS2 + the HUD overlay together — viewers
# of hls.5stack.gg/<match-id>/ see them composited.
#
# Requires:
#   * picom running (otherwise transparent background blends as black on
#     openbox)
#   * an X display already up (start_xorg)
#   * /opt/openhud/openhud (Electron-builder unpacked binary, dropped in
#     by the Dockerfile via OPENHUD_TARBALL_URL)
#
# All ops idempotent.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${OPENHUD_BIN:=/opt/openhud/openhud}"
: "${OPENHUD_PORT:=1349}"
: "${OPENHUD_HOST:=127.0.0.1}"
: "${OPENHUD_USERDATA:=$HOME/.config/openhud}"
: "${OPENHUD_GSI_TOKEN:=5stack}"
: "${OPENHUD_OVERLAY_W:=1920}"
: "${OPENHUD_OVERLAY_H:=1080}"
# 5stack API base for seeding match metadata. API_TOKEN optional — if set
# we send it as a Bearer auth header.
: "${API_BASE:=}"
: "${API_TOKEN:=}"

export OPENHUD_BIN OPENHUD_PORT OPENHUD_HOST OPENHUD_USERDATA \
       OPENHUD_GSI_TOKEN OPENHUD_OVERLAY_W OPENHUD_OVERLAY_H

picom_running() { pgrep -x picom >/dev/null 2>&1; }

# Start picom in --daemon mode using the xrender backend. xrender works on
# Xorg-dummy without GLX shenanigans; switch to --backend glx if artifacts
# show up. Bare picom (no config file) — we only need compositing, not
# fancy effects.
start_picom() {
  if picom_running; then
    log "picom already up"
    return 0
  fi
  log "starting picom"
  spawn_logged picom picom --backend xrender --no-fading-openclose --daemon
  local i
  for i in $(seq 1 20); do
    picom_running && { log "  picom up"; return 0; }
    sleep 0.2
  done
  warn "picom didn't come up — HUD overlay will composite as opaque black (see [picom] log lines above)"
  return 1
}

stop_picom() { pkill -x picom 2>/dev/null || true; }

openhud_running() { pgrep -f "$OPENHUD_BIN" >/dev/null 2>&1; }

openhud_server_up() {
  # Probe the root URL and accept any HTTP response. We previously hit
  # /api/hud with `curl -f`, but that returns non-2xx until the HUD
  # overlay window has actually been opened — making us declare the
  # server "down" even when Express is fully up and serving. Any HTTP
  # status (including 404) means the server is listening and responding,
  # which is what we actually care about.
  local code
  code=$(curl -sS -o /dev/null --max-time 2 -w '%{http_code}' \
    "http://${OPENHUD_HOST}:${OPENHUD_PORT}/" 2>/dev/null)
  [ -n "$code" ] && [ "$code" != "000" ]
}

start_openhud() {
  if [ ! -x "$OPENHUD_BIN" ]; then
    warn "OpenHud binary not found at $OPENHUD_BIN — skipping HUD overlay"
    warn "  the openhud-builder stage in Dockerfile should have populated this;"
    warn "  rebuild the image and check the build logs for 'dist:linux' errors"
    return 1
  fi
  if openhud_running; then
    log "openhud already running"
    return 0
  fi
  mkdir -p "$OPENHUD_USERDATA"
  log "starting openhud ($OPENHUD_BIN)"
  # OPENHUD_AUTO_OVERLAY=1 (openhud/auto-overlay.patch) opens the
  # fullscreen transparent HUD on app-ready — without it only the admin
  # panel exists. --mute-audio: HUD pages emit SFX that Electron would
  # write to the cs2 null sink, leaking into the captured stream.
  PORT="$OPENHUD_PORT" \
  OPENHUD_AUTO_OVERLAY=1 \
    spawn_logged openhud "$OPENHUD_BIN" --no-sandbox --disable-gpu-sandbox --mute-audio
  log "  openhud pid=$SPAWNED_PID"
}

# Poll the local HUD endpoint until it answers. Waits indefinitely —
# the only abort condition is the openhud process actually exiting
# (a real failure that retrying won't fix). The "timeout" arg is
# still accepted for callsite compatibility but treated as no-op.
wait_for_openhud_server() {
  log "waiting for OpenHud server on :${OPENHUD_PORT}"
  local i=0
  while :; do
    if openhud_server_up; then
      log "  openhud server up after ${i}s"
      return 0
    fi
    if ! openhud_running; then
      warn "openhud process exited early (see [openhud] log lines above)"
      return 1
    fi
    i=$(( i + 1 ))
    if [ $(( i % 30 )) -eq 0 ]; then
      log "  still waiting (${i}s)"
    fi
    sleep 1
  done
}

stop_openhud() {
  pkill -f "$OPENHUD_BIN" 2>/dev/null || true
}

# OpenHud opens two BrowserWindows: the admin panel (WM_NAME exactly
# "OpenHud") and the spectator HUD overlay (WM_NAME varies per HUD).
# We match both by WM_CLASS=openhud + exact WM_NAME, since several
# Electron utility windows also share the class.

# windowunmap alone is sometimes ignored by Electron windows that
# re-show on focus; the offscreen move is a fallback.
hide_openhud_admin_window() {
  local id name target=""
  for id in $(xdotool search --classname '^openhud' 2>/dev/null); do
    name=$(xdotool getwindowname "$id" 2>/dev/null || true)
    if [ "$name" = "OpenHud" ]; then
      target="$id"; break
    fi
  done
  if [ -z "$target" ]; then
    log "no OpenHud admin window to hide (yet)"
    return 0
  fi
  log "hiding OpenHud admin window: $target"
  xdotool windowminimize "$target"            2>/dev/null || true
  wmctrl -ir "$target" -b add,hidden          2>/dev/null || true
  xdotool windowunmap "$target"               2>/dev/null || true
  xdotool windowmove "$target" -3000 -3000    2>/dev/null || true
}

# Heuristic: largest WM_CLASS=openhud window at least 1280x720. Size is
# the only reliable discriminator since HUD page titles can collide with
# "OpenHud", and the admin window defaults to 1200x700. Without the size
# floor, Electron's invisible utility windows (16x16, etc.) match too.
find_openhud_overlay_window() {
  local min_w="${OPENHUD_MIN_W:-1280}"
  local min_h="${OPENHUD_MIN_H:-720}"
  local id w h area best=0 best_id=""
  for id in $(xdotool search --classname '^openhud' 2>/dev/null); do
    # Unset before eval — if the window vanished mid-loop, eval of empty
    # string is a no-op and would keep the prior iteration's size.
    unset WIDTH HEIGHT X Y SCREEN
    eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null)"
    w="${WIDTH:-0}"; h="${HEIGHT:-0}"
    [ "$w" -ge "$min_w" ] && [ "$h" -ge "$min_h" ] || continue
    area=$((w * h))
    if [ "$area" -gt "$best" ]; then
      best="$area"; best_id="$id"
    fi
  done
  [ -n "$best_id" ] && echo "$best_id"
}

# Polls up to OPENHUD_OVERLAY_TIMEOUT for the overlay window, respawning
# openhud if its process died, then moves+sizes+raises it above cs2 so
# ximagesrc captures CS2 + HUD composited. On giveup, dumps the openhud
# pid + every openhud-class window so the operator can tell whether the
# HUD window was destroyed vs. the whole Electron app crashed.
position_openhud_overlay() {
  local timeout="${OPENHUD_OVERLAY_TIMEOUT:-30}"
  local id="" i wid wname
  for i in $(seq 1 "$timeout"); do
    id=$(find_openhud_overlay_window)
    [ -n "$id" ] && break
    if ! openhud_running; then
      warn "openhud process died — restarting"
      stop_openhud; sleep 1
      start_openhud
      wait_for_openhud_server 30 || warn "respawned openhud not responding"
    fi
    sleep 1
  done
  if [ -z "$id" ]; then
    warn "no OpenHud overlay window after ${timeout}s — HUD won't be visible"
    log "  openhud pid: $(pgrep -f "$OPENHUD_BIN" | head -1 || echo NONE)"
    log "  openhud-class windows currently mapped:"
    while IFS= read -r wid; do
      [ -n "$wid" ] || continue
      wname=$(xdotool getwindowname "$wid" 2>/dev/null || true)
      unset WIDTH HEIGHT X Y SCREEN
      eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)"
      log "    $wid \"$wname\" ${WIDTH:-?}x${HEIGHT:-?}+${X:-?}+${Y:-?}"
    done < <(xdotool search --classname '^openhud' 2>/dev/null)
    return 1
  fi
  log "positioning OpenHud overlay window $id ($OPENHUD_OVERLAY_W x $OPENHUD_OVERLAY_H @ 0,0)"
  xdotool windowmove "$id" 0 0                                    2>/dev/null || true
  xdotool windowsize "$id" "$OPENHUD_OVERLAY_W" "$OPENHUD_OVERLAY_H" 2>/dev/null || true
  wmctrl -ir "$id" -b add,above                                   2>/dev/null || true
  xdotool windowraise "$id"                                       2>/dev/null || true
}

# Write the gamestate_integration_openhud.cfg into CS2's cfg dir so cs2
# POSTs game state to OpenHud at engine start. We prefer the cfg from the
# OpenHud tarball (so it stays in lockstep with the server) but fall back
# to writing a minimal one ourselves if the tarball cfg isn't found.
write_openhud_gsi_cfg() {
  local cfg_dir="$CS2_DIR/game/csgo/cfg"
  mkdir -p "$cfg_dir"
  local dst="$cfg_dir/gamestate_integration_openhud.cfg"

  local src
  src=$(find /opt/openhud -name 'gamestate_integration_openhud.cfg' \
          -type f 2>/dev/null | head -1 || true)
  if [ -n "$src" ]; then
    log "writing GSI cfg from $src to $dst"
    cp -f "$src" "$dst"
  else
    log "writing fallback GSI cfg to $dst (tarball cfg not found)"
    cat >"$dst" <<EOF
"OpenHud Game State Integration"
{
  "uri" "http://${OPENHUD_HOST}:${OPENHUD_PORT}/api/gsi"
  "timeout" "5.0"
  "buffer" "0.0"
  "throttle" "0.1"
  "heartbeat" "10.0"
  "auth" { "token" "${OPENHUD_GSI_TOKEN}" }
  "data"
  {
    "provider"        "1"
    "map"             "1"
    "round"           "1"
    "player_id"       "1"
    "player_state"    "1"
    "player_weapons"  "1"
    "player_match_stats" "1"
    "allplayers_id"   "1"
    "allplayers_state" "1"
    "allplayers_match_stats" "1"
    "allplayers_weapons" "1"
    "allplayers_position" "1"
    "phase_countdowns" "1"
    "allgrenades"     "1"
    "bomb"            "1"
  }
}
EOF
  fi
}

# Drop a second GSI cfg alongside the OpenHud one so cs2 fires game
# state to spec-server too. cs2 enumerates every
# gamestate_integration_*.cfg in its cfg dir at engine init — adding
# a second file forks GSI to both consumers without touching OpenHud.
# spec-server uses the events to know exactly when the demo is
# playing (round.phase / map.phase), so the web UI can start its
# timeline at the right moment instead of guessing.
write_spec_gsi_cfg() {
  local cfg_dir="$CS2_DIR/game/csgo/cfg"
  mkdir -p "$cfg_dir"
  local dst="$cfg_dir/gamestate_integration_5stack.cfg"
  local port="${SPEC_SERVER_PORT:-1350}"
  log "writing GSI cfg to $dst (-> spec-server :$port/gsi)"
  # `auth` block is required by some cs2 builds — without it cs2
  # silently skips the cfg. Token value isn't checked server-side
  # (it's included in the POST body so listeners CAN validate; we
  # don't bother since the listener only binds to localhost).
  cat >"$dst" <<EOF
"5Stack Spec-Server GSI"
{
  "uri" "http://127.0.0.1:${port}/gsi"
  "timeout" "5.0"
  "buffer" "0.0"
  "throttle" "0.1"
  "heartbeat" "10.0"
  "auth" { "token" "5stack-spec" }
  "data"
  {
    "provider" "1"
    "map"      "1"
    "round"    "1"
    "player_id" "1"
    "player_state" "1"
    "allplayers_id"    "1"
    "allplayers_state" "1"
  }
}
EOF
}

# Pre-bind spec actions to F-keys so spec-server only sends a keystroke
# via xdotool — activating cs2 restacks it above the OpenHud overlay
# (and on this Openbox+picom setup can destroy the overlay window).
# Per-player slots (F6-F11) appended later by write_spec_player_binds.
# Mirrored in spec-server.mjs — change both together.
spec_static_binds_block() {
  cat <<'EOF'
// === spec-server keybinds (auto-generated; mirror in src/spec-server.mjs) ===
bind "F1" "spec_next"
bind "F2" "spec_prev"
bind "F3" "+jump"
bind "F4" "spec_autodirector 1; spec_mode 5"
bind "F5" "spec_autodirector 0"
// BACKSPACE → exec 5stack_exec is spec-server's exec-cfg path for
// arbitrary console commands (cinematic setpos/setang, post-applaunch
// reconnect, etc.). Hard-coded in spec-server.mjs::EXEC_CFG_KEY — keep
// the binding identical in live and demo mode so spec-server has a
// single keypress vehicle in both flows.
bind "BACKSPACE" "exec 5stack_exec"
EOF
}

# Demo-playback keybinds. Mirrored in spec-server.mjs's KEY_DEMO_*
# constants — change both together. Tick offsets assume 64-tick demos
# (±15s = ±960 ticks); needs parameterising for 128-tick.
demo_static_binds_block() {
  cat <<'EOF'
// demo-playback keybinds (auto-generated; mirror in src/spec-server.mjs).
// BACKSPACE → exec 5stack_exec is the exec-cfg path spec-server uses for
// arbitrary commands; spec-server's execCfgCommand hard-codes that key.
bind "PAUSE" "demo_togglepause"
bind "HOME" "demo_gototick -960"
bind "END" "demo_gototick +960"
bind "INS" "host_timescale 1"
bind "SEMICOLON" "host_timescale 0.5"
bind "APOSTROPHE" "host_timescale 2"
bind "PGUP" "host_timescale 4"
bind "PGDN" "host_timescale 0.25"
bind "F11" "demoui"
bind "BACKSPACE" "exec 5stack_exec"
EOF
}

# Append per-player `bind "F<n>" "spec_player_by_accountid <id>"` lines
# to the autoexec from the seeded match JSON, and write the
# accountid -> keysym map the spec-server reads at request time.
#
# Args:
#   $1 — path to the seeded match JSON (from seed_openhud_db)
#   $2 — autoexec.cfg to append to
#   $3 — JSON map output path (PLAYER_BINDINGS_PATH in spec-server.mjs)
#
# No-ops gracefully if the seed JSON is missing or empty — spec-server
# will then 404 /spec/player requests with a hint to reseed. Spec
# operators can still drive cycling via /spec/click and /spec/jump.
write_spec_player_binds() {
  local match_json="$1" autoexec="$2" map_out="$3"
  if [ ! -s "$match_json" ]; then
    log "no seeded match metadata at $match_json — skipping per-player binds"
    log "  /spec/player will 404 until run-live re-seeds; cycling (F1/F2) still works"
    : > "$map_out" 2>/dev/null || true
    return 0
  fi

  python3 - "$match_json" "$autoexec" "$map_out" <<'PY' 2>&1 | sed 's/^/    /'
import json, sys

match_json_path, autoexec_path, map_path = sys.argv[1], sys.argv[2], sys.argv[3]

# F6..F11 — 6 slots. Enough for 5v5 plus one sub. F12 is intentionally
# excluded: Steam captures it as the global screenshot hotkey even
# with the overlay disabled, so binding cs2 actions to it triggers a
# Steam screenshot instead. If the operator needs direct-switch keys
# beyond 6 slots, pick non-F12 keysyms (e.g. KP_*, BRACKETLEFT) here
# AND in spec-server.mjs's KEY_* constants.
KEYS = [f"F{n}" for n in range(6, 12)]

STEAMID64_BASE = 76561197960265728
def to_accountid(s):
    try:
        n = int(s)
    except (TypeError, ValueError):
        return None
    return n - STEAMID64_BASE if n > STEAMID64_BASE else n

with open(match_json_path) as f:
    raw = json.load(f)
match = raw.get('match', raw) if isinstance(raw, dict) else {}

binds = []
mapping = {}  # str(accountid) -> keysym
seen = set()
slot = 0
for lu in (match.get('lineups') or []):
    if slot >= len(KEYS):
        break
    for p in (lu.get('players') or lu.get('lineup_players') or []):
        if slot >= len(KEYS):
            break
        steam = (p.get('steam_id') or p.get('steamId') or
                 p.get('steamid64') or p.get('steamid'))
        aid = to_accountid(steam)
        if aid is None or aid in seen:
            continue
        seen.add(aid)
        key = KEYS[slot]
        binds.append(f'bind "{key}" "spec_player_by_accountid {aid}"')
        mapping[str(aid)] = key
        slot += 1

# Append to autoexec under a marker so a re-run is easy to spot in the
# file; cs2 takes the last bind for any given key, so re-runs just
# stack and the most recent map wins.
with open(autoexec_path, 'a') as f:
    f.write('\n// === per-player spec binds (auto-generated from match metadata) ===\n')
    f.write('\n'.join(binds))
    f.write('\n')

with open(map_path, 'w') as f:
    json.dump({
        'accountid_to_key': mapping,
        'keys': KEYS[:slot],
    }, f, indent=2)

print(f"wrote {slot} per-player binds (slots {KEYS[:slot]})")
PY
}

# Best-effort seed of OpenHud's SQLite DB from the 5stack API. Two-step:
#   1. GET ${API_BASE}/matches/${MATCH_ID}        (5stack — exact path TBD)
#   2. POST translated objects to OpenHud REST    (/api/v2/matches etc.)
#
# Always non-fatal — if the API is unreachable or the schemas drift the
# HUD still runs (it'll just show fallback names from CS2 GSI provider
# data instead of curated player/team metadata).
seed_openhud_db() {
  local match_id="${1:?match id required}"
  if [ -z "$API_BASE" ]; then
    log "API_BASE not set — skipping OpenHud DB seed (HUD will fall back to GSI data)"
    return 0
  fi
  log "seeding OpenHud DB for match $match_id from $API_BASE"

  local hdr=()
  [ -n "$API_TOKEN" ] && hdr=(-H "Authorization: Bearer $API_TOKEN")

  local match_json
  # curl stderr streams through the script's stderr so failures show up
  # tagged in the k8s log without a temp file.
  if ! match_json=$(curl -fsS --max-time 10 "${hdr[@]}" \
        "${API_BASE%/}/matches/${match_id}" 2>&1 1>&3); then
    warn "match fetch failed (see [openhud-seed] log lines above)"
    return 0
  fi 3>&1

  printf '%s\n' "$match_json" >"$LOG_DIR/openhud-seed-match.json"
  log "  match metadata cached at $LOG_DIR/openhud-seed-match.json"

  # Translate + POST to OpenHud's REST. Exact upstream shape lives in
  # src/electron/api/v2/{teams,players,matches}/ in the OpenHud source —
  # we go through python3 (already in the image) for safe JSON handling
  # rather than jq (not installed) and shell out to curl per record.
  # Python writes to its own stderr → script stderr → k8s log.
  python3 - <<'PY' "$match_json" "http://${OPENHUD_HOST}:${OPENHUD_PORT}/api/v2"
import json, sys, urllib.request, urllib.error

raw, base = sys.argv[1], sys.argv[2]

def log(msg):
    sys.stderr.write(f"[openhud-seed] {msg}\n"); sys.stderr.flush()

def post(path, body):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            log(f"POST {path} -> {r.status}")
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        log(f"POST {path} -> HTTP {e.code}: {e.read().decode(errors='replace')}")
    except Exception as e:
        log(f"POST {path} -> {type(e).__name__}: {e}")
    return None

try:
    m = json.loads(raw)
except Exception as e:
    log(f"match json parse failed: {e}")
    sys.exit(0)

# Best-effort field probing — accept either a raw match record or a
# wrapper like {"match": {...}}. Adapt as the 5stack response shape
# settles.
match = m.get('match', m) if isinstance(m, dict) else {}
lineups = match.get('lineups') or []

team_ids = []
for lu in lineups:
    name = (lu.get('name') or lu.get('team_name')
            or (lu.get('team') or {}).get('name')
            or 'Team')
    short = (lu.get('short_name') or (lu.get('team') or {}).get('short_name')
             or name[:3].upper())
    resp = post('/teams', {'name': name, 'shortName': short, 'country': 'us'})
    tid = (resp or {}).get('id') or (resp or {}).get('_id')
    team_ids.append(tid)
    for p in lu.get('players') or lu.get('lineup_players') or []:
        steam = p.get('steam_id') or p.get('steamId') or p.get('steamid64') or ''
        first = p.get('name') or p.get('username') or 'Player'
        post('/players', {
            'firstName': first, 'lastName': '',
            'username': p.get('name') or first,
            'steamid': steam,
            'team': tid,
            'country': p.get('country') or 'us',
        })

if len(team_ids) >= 2:
    post('/matches', {
        'left':  {'id': team_ids[0], 'wins': 0},
        'right': {'id': team_ids[1], 'wins': 0},
        'matchType': 'Bo1',
        'current': True,
    })

PY
  return 0
}

openhud_status() {
  log "openhud status:"
  if openhud_running; then
    log "  process: running (pid $(pgrep -f "$OPENHUD_BIN" | head -1))"
  else
    log "  process: NOT running"
  fi
  if openhud_server_up; then
    log "  server:  http://${OPENHUD_HOST}:${OPENHUD_PORT}/api/hud OK"
  else
    log "  server:  unreachable on :${OPENHUD_PORT}"
  fi
  if picom_running; then
    log "  picom:   running"
  else
    log "  picom:   NOT running (transparent overlay won't composite)"
  fi
  local admin overlay
  admin=$(xdotool search --name '^OpenHud' 2>/dev/null | head -1 || true)
  overlay=$(find_openhud_overlay_window || true)
  log "  admin window:   ${admin:-(none)}"
  log "  overlay window: ${overlay:-(none)}"
}
