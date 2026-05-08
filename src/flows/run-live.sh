#!/usr/bin/env bash
# Flow 2 — launch CS2 via running Steam (so it auto-updates) and start the
# match-capture stream.
#
# Prerequisite: Steam must already be logged in (run flow 1 first and watch
# the debug stream until you see the friends list / main window).
#
# Required env:
#   MATCH_ID
#   PLAYCAST_URL                              *or*
#   CONNECT_TV_ADDR + CONNECT_TV_PASSWORD     *or*
#   CONNECT_ADDR + CONNECT_PASSWORD

set -uo pipefail
SCRIPT_TAG=run-live

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/audio.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/steam.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/cs2-perf.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/openhud.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/match-hud.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/status-reporter.sh"

load_env
require_env MATCH_ID

# Idempotent — re-attaches to the daemon spawned by setup-steam if it's
# already running, otherwise starts one (e.g. when run-live is invoked
# standalone without a preceding setup-steam in the same pod).
start_status_reporter

# The api's GameStreamerService picks ONE of three connection modes
# and emits the corresponding env vars (see buildConnectEnv there).
# We match those three modes here, in the same priority order:
#   1. PLAYCAST_URL                              — usePlaycast setting
#   2. CONNECT_TV_ADDR + CONNECT_TV_PASSWORD     — server has a TV port
#   3. CONNECT_ADDR + CONNECT_PASSWORD           — fallback (game port)
# `CS2_CONNECT_*` are the values we hand to live_autoexec / launch args.
if [ -n "${PLAYCAST_URL:-}" ]; then
  CS2_CONNECT_MODE=playcast
elif [ -n "${CONNECT_TV_ADDR:-}" ]; then
  CS2_CONNECT_MODE=connect
  CS2_CONNECT_ADDR="$CONNECT_TV_ADDR"
  CS2_CONNECT_PASSWORD="${CONNECT_TV_PASSWORD:-}"
elif [ -n "${CONNECT_ADDR:-}" ]; then
  CS2_CONNECT_MODE=connect
  CS2_CONNECT_ADDR="$CONNECT_ADDR"
  CS2_CONNECT_PASSWORD="${CONNECT_PASSWORD:-}"
else
  die "no connect target — set PLAYCAST_URL, or CONNECT_TV_ADDR+CONNECT_TV_PASSWORD, or CONNECT_ADDR+CONNECT_PASSWORD"
fi

: "${FPS:=30}"
: "${VIDEO_KBPS:=6000}"
: "${CS2_LAUNCH_TIMEOUT:=300}"
: "${CS2_WINDOW_TIMEOUT:=300}"

: "${DEBUG_STREAM_ID:=debug}"

if [ "${DEBUG_CAPTURE:-0}" = "1" ]; then
  say "0. debug capture stream"
  start_xorg
  # debug stream is video-only — audio not useful for visual debugging
  # and avoids contending for the cs2 sink.
  start_capture "$DEBUG_STREAM_ID" 30 4000 true 0
  log "watch debug: https://${GAME_STREAM_DOMAIN}/${DEBUG_STREAM_ID}/"
fi

say "1. preflight"
steam_pipe_up || die "Steam isn't running. Run flow 1 (setup-steam) first."
log "  steam pipe up (pid $(cat "$HOME/.steam/steam.pid"))"
xorg_running || die "Xorg isn't up. Run flow 1 (setup-steam) first."
log "  xorg up on $DISPLAY"

# Real Steam needs the genuine steamclient.so for IPC; restore if gbe_fork
# is in the way from a prior session.
restore_real_steamclient

say "2. clean up stale CS2 / capture for this match"
pkill -9 -f '/linuxsteamrt64/cs2'   2>/dev/null || true
stop_capture "$MATCH_ID"
sleep 1
rm -f /tmp/source_engine_*.lock
rm -f "$CS2_DIR/game/csgo/steam_appid.txt" \
      "$CS2_DIR/game/bin/linuxsteamrt64/steam_appid.txt" 2>/dev/null || true

say "3. write CS2 autoexec"
CS2_CFG_DIR="$CS2_DIR/game/csgo/cfg"
mkdir -p "$CS2_CFG_DIR"
apply_cs2_video_preset
# Write both autoexec.cfg (auto-loaded at engine init) and
# live_autoexec.cfg (kept for compatibility) — Source 2 silently drops
# +exec from launch args.
#
# Spectator-UI hide convars (cl_drawhud, r_drawvgui, spec_show_xray,
# cl_show_observer_crosshair, cl_obs_interp_enable) are all sv_cheats-
# gated and revert when cs2 connects to a real match server; the bottom
# Panorama timeline has no convar at all. We can only drive auto-
# director from cfg — HUD bleed-through under OpenHud is a known limit.
read -r -d '' HIDE_UI_CMDS <<'EOF' || true
// Keep audio + engine running when cs2 doesn't have keyboard focus.
// We raise the OpenHud overlay above cs2 immediately after launch, so
// cs2 is never the focused window — defaults of `snd_mute_losefocus 1`
// and `engine_no_focus_sleep > 0` would otherwise mute cs2's audio
// pipeline (silent cs2.monitor capture even though pulse is wired up
// correctly) and throttle its tick rate. Neither is sv_cheats-gated.
snd_mute_losefocus 0
engine_no_focus_sleep 0
volume 1.0
EOF

# Static spec keybinds (F1-F5). The spec-server sends these keys via
# xdotool to drive observer actions without opening the dev console.
# Per-player binds (F6-F12) are appended below from the match metadata
# after seed_openhud_db runs.
SPEC_BINDS_BLOCK="$(spec_static_binds_block)"

# Drop the curated observer.cfg (crosshair, HUD scale, safezone, radar,
# viewmodel) when OpenHud is installed; skip the exec line otherwise so
# cs2 doesn't log a "missing cfg" warning each launch.
OBSERVER_SRC="$SRC_DIR/../resources/observer.cfg"
EXEC_OBSERVER=""
if [ -x "${OPENHUD_BIN:-/opt/openhud/openhud}" ] && [ -f "$OBSERVER_SRC" ]; then
  cp -f "$OBSERVER_SRC" "$CS2_CFG_DIR/observer.cfg"
  log "  wrote $CS2_CFG_DIR/observer.cfg (from $OBSERVER_SRC)"
  EXEC_OBSERVER="exec observer.cfg"
fi

if [ "$CS2_CONNECT_MODE" = "playcast" ]; then
  cat > "$CS2_CFG_DIR/autoexec.cfg" <<EOF
// auto-generated by src/flows/run-live.sh — playcast mode
con_enable 1
$HIDE_UI_CMDS
$(cs2_perf_autoexec_block)
$EXEC_OBSERVER
$SPEC_BINDS_BLOCK
playcast "$PLAYCAST_URL"
EOF
  log "  playcast: $PLAYCAST_URL"
else
  cat > "$CS2_CFG_DIR/autoexec.cfg" <<EOF
// auto-generated by src/flows/run-live.sh — connect mode
con_enable 1
$HIDE_UI_CMDS
$(cs2_perf_autoexec_block)
$EXEC_OBSERVER
$SPEC_BINDS_BLOCK
password "$CS2_CONNECT_PASSWORD"
connect $CS2_CONNECT_ADDR
EOF
  log "  connect: $CS2_CONNECT_ADDR"
fi

# Write the OpenHud GSI cfg so cs2 starts POSTing game state to the
# already-running OpenHud server. Always written even if the server
# isn't up — cs2 will just retry on the timeout interval and the HUD
# will start updating once OpenHud catches up.
#
# setup-steam.sh kicks off this work in the background as soon as
# the Steam pipe is up, so by the time we reach this stage the
# marker file usually exists already. Wait briefly for it, then
# fall back to inline if it didn't run (e.g. setup-steam was bypassed
# or env was missing).
say "3b. OpenHud GSI cfg + DB seed"
PREP_MARKER="$LOG_DIR/match-cfgs-prepared"
PREP_FAILED="$LOG_DIR/match-cfgs-failed"
PREP_SKIPPED="$LOG_DIR/match-cfgs-skipped"
if [ -f "$PREP_MARKER" ]; then
  log "  parallel cfg-prep already finished — reusing seeded match metadata"
elif [ -f "$PREP_SKIPPED" ]; then
  # setup-steam.sh decided not to spawn the bg job (e.g. no API_BASE).
  # Fall straight through to the inline path; no point waiting.
  log "  parallel cfg-prep was skipped — running inline"
  write_openhud_gsi_cfg
  seed_openhud_db "$MATCH_ID"
else
  # bg job is still in flight (rare) OR setup-steam was bypassed. Wait
  # briefly, then fall through.
  if [ ! -f "$PREP_FAILED" ]; then
    log "  waiting up to 5s for parallel cfg-prep marker"
    for _ in $(seq 1 10); do
      [ -f "$PREP_MARKER" ] || [ -f "$PREP_FAILED" ] && break
      sleep 0.5
    done
  fi
  if [ -f "$PREP_MARKER" ]; then
    log "  parallel cfg-prep finished — reusing seeded match metadata"
  else
    [ -f "$PREP_FAILED" ] && warn "  parallel cfg-prep failed — retrying inline"
    write_openhud_gsi_cfg
    seed_openhud_db "$MATCH_ID"
  fi
fi

# Per-player spec binds. Appends `bind "F<n>" "spec_player_by_accountid <id>"`
# lines to the autoexec from the just-cached seed JSON (written by
# seed_openhud_db to $LOG_DIR/openhud-seed-match.json) and drops the
# accountid -> keysym map at $LOG_DIR/spec-bindings.json for the
# spec-server to read at request time. Falls through silently if the
# seed file is missing — the static binds still drive cycling.
say "3c. CS2 spec per-player binds"
write_spec_player_binds \
  "$LOG_DIR/openhud-seed-match.json" \
  "$CS2_CFG_DIR/autoexec.cfg" \
  "$LOG_DIR/spec-bindings.json"

# Mirror the (now fully assembled) autoexec into live_autoexec.cfg so
# +exec live_autoexec from the launch args picks up the same binds.
# 3d. Pull per-match HUD pack + write spec-server GSI cfg (5stack prod fork)
say "3d. seed match HUD + spec-server GSI cfg"
seed_match_hud || warn "  match-hud: non-fatal failure (see lines above)"
write_spec_gsi_cfg

cp "$CS2_CFG_DIR/autoexec.cfg" "$CS2_CFG_DIR/live_autoexec.cfg"
log "  wrote $CS2_CFG_DIR/autoexec.cfg + live_autoexec.cfg"

# CS2 dlopen()s libpangoft2-1.0.so without the .0 suffix; pre-link.
for base in libpangoft2-1.0 libpango-1.0; do
  if [ ! -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" ] \
     && [ -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so.0" ]; then
    ln -sf "${base}.so.0" "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" || true
  fi
done

# Match the original working invocation: cd into the cs2 binary dir
# before launching. Original observed: cwd matters for some of cs2's
# rpath-relative resolutions during Steam's launch handoff.
CS2_BIN="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
[ -x "$CS2_BIN" ] || die "CS2 binary missing at $CS2_BIN"
cd "$(dirname "$CS2_BIN")"

say "4. launch CS2"
report_status status=launching_cs2
# Force cs2's audio to the null sink we capture from. Without this,
# cs2 may pick a cached different sink (or no sink at all in headless)
# and we'd capture silence from cs2.monitor. PULSE_SINK is honored by
# the PulseAudio client lib at startup of the app.
export PULSE_SINK="${PULSE_SINK_NAME:-cs2}"
# Steam's -applaunch wrapper scrubs XDG_RUNTIME_DIR before exec'ing
# cs2 — without this, cs2's libpulse can't find the unix socket and
# logs `pa_context_connect() failed: Connection refused`, falls back
# to ALSA (which has no devices in the container), and produces no
# audio. PULSE_SERVER=tcp:host:port is an absolute coordinate the
# wrapper can't drop. Set in audio.sh once the tcp listener loads.
: "${PULSE_SERVER:=tcp:${PULSE_TCP_HOST:-127.0.0.1}:${PULSE_TCP_PORT:-4713}}"
export PULSE_SERVER
log "  PULSE_SINK=$PULSE_SINK PULSE_SERVER=$PULSE_SERVER (cs2 audio routes here)"

do_applaunch() {
  # Three independent paths trigger the connect — whichever cs2 honors
  # first wins:
  #   1) autoexec.cfg in cfg/ — cs2 auto-loads this at engine init
  #   2) +exec live_autoexec  — explicit cfg execution via launch arg
  #   3) +connect / +password — direct launch args, run after engine init
  #
  # Windowed-borderless (`-windowed -noborder`) — required so the
  # OpenHud Electron overlay (alwaysOnTop) actually composites on top.
  # Exclusive `-fullscreen` grabs the X display in a way that prevents
  # other X clients from stacking above cs2; OpenHud's instructions
  # also explicitly call for "WindowedFullscreen mode".
  local cs2_args=(
    -windowed -noborder -width 1920 -height 1080 -novid -nojoy -console
    +exec live_autoexec)
  if [ "$CS2_CONNECT_MODE" = "playcast" ]; then
    cs2_args+=(+playcast "$PLAYCAST_URL")
  else
    cs2_args+=(+password "$CS2_CONNECT_PASSWORD" +connect "$CS2_CONNECT_ADDR")
  fi

  if [ "${LAUNCH_CS2_DIRECT:-0}" = "1" ]; then
    # Bypass Steam's -applaunch handoff. cs2 reads steamclient.so
    # via $HOME/.steam/sdk64/ and talks to the running Steam
    # directly; -applaunch was dropping our +connect args silently.
    local cs2_bin="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
    log "  exec (DIRECT): $cs2_bin ${cs2_args[*]}"
    cd "$CS2_DIR/game/bin/linuxsteamrt64"
    spawn_logged cs2-launch "$cs2_bin" "${cs2_args[@]}"
    log "  cs2 direct launch (pid=$SPAWNED_PID)"
  else
    local cmd=("$STEAM_HOME/ubuntu12_32/steam" -applaunch 730 "${cs2_args[@]}")
    log "  exec: ${cmd[*]}"
    spawn_logged cs2-launch "${cmd[@]}"
    log "  applaunch sent (launcher pid=$SPAWNED_PID)"
  fi
}
do_applaunch
RELAUNCH_DONE=0

# Wait for cs2 process. Two side-effects on each iteration:
#  - poke the Steam window with Return: dismisses the focused button on
#    any modal CEF dialog (cloud-out-of-date, "Launching ... shaders", etc).
#  - every 15s, dump the open X windows + cs2/launcher state so the
#    operator can see what Steam is actually showing right now.
CS2_PID=""
for i in $(seq 1 "$CS2_LAUNCH_TIMEOUT"); do
  CS2_PID=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
  [ -n "$CS2_PID" ] && break

  # Auto-poke: Space dismisses Steam's CEF dialogs (cloud-out-of-date,
  # shader pre-cache) by activating the default-focused button. Bounded
  # to the first 90s of the wait — covers a late-appearing dialog while
  # cs2 is downloading cloud files. cs2 spawn breaks the loop so this
  # never fires once the game is up.
  if [ "$i" -ge 3 ] && [ "$i" -le 90 ] && [ $(( i % 5 )) -eq 0 ]; then
    poke_steam_dialog
  fi

  [ $(( i % 15 )) -eq 0 ] && log "  ${i}s elapsed waiting on cs2..."

  # Fallback: if cs2 still hasn't spawned after 30s, re-issue applaunch
  # once. Steam sometimes ignores the very first applaunch on a fresh
  # login (logs "Steam is already running, command line was forwarded"
  # but never spawns cs2). A second applaunch reliably kicks it.
  if [ "$i" = 30 ] && [ "$RELAUNCH_DONE" = 0 ]; then
    log "  30s without cs2 — re-issuing -applaunch (one-shot fallback)"
    do_applaunch
    RELAUNCH_DONE=1
  fi
  sleep 1
done
[ -n "$CS2_PID" ] || {
  # Steam-side console log isn't piped to stderr (it's a file Steam
  # owns) so dump its tail inline. Other diagnostics live in the k8s
  # log under [cs2-launch] / [steam].
  log "--- $STEAM_LIBRARY/steam/logs/console-linux.txt (last 20) ---"
  tail -20 "$STEAM_LIBRARY/steam/logs/console-linux.txt" 2>/dev/null || true
  die "Steam never spawned cs2 in ${CS2_LAUNCH_TIMEOUT}s"
}
log "  cs2 pid=$CS2_PID"

# cs2 is up — hide Steam's main UI + Friends List so any missed
# clicks (e.g. from the shader-skip auto-handler) don't fall through
# to Steam buttons behind the dialog. Modal dialogs Steam pops on top
# (shader pre-cache, etc.) remain visible since they're separate
# X windows; only the persistent Steam UI gets hidden.
minimize_steam_windows

say "5. wait for CS2 window"
report_status status=connecting_to_game
WIN=""
for i in $(seq 1 "$CS2_WINDOW_TIMEOUT"); do
  WIN=$(xwininfo -display "$DISPLAY" -root -tree 2>/dev/null \
    | awk '/"Counter-Strike 2"/{print $1; exit}')
  [ -n "$WIN" ] && { log "  window after ${i}s: $WIN"; break; }
  if ! kill -0 "$CS2_PID" 2>/dev/null; then
    log "--- cs2 console-linux.txt (last 60) ---"
    tail -60 "$STEAM_LIBRARY/steam/logs/console-linux.txt" 2>/dev/null
    die "cs2 EXITED early."
  fi
  [ $(( i % 15 )) -eq 0 ] && log "  still waiting for cs2 window (${i}s, pid=$CS2_PID alive)"
  sleep 1
done
[ -n "$WIN" ] || {
  log "--- cs2 console-linux.txt (last 60) ---"
  tail -60 "$STEAM_LIBRARY/steam/logs/console-linux.txt" 2>/dev/null
  die "no CS2 window after ${CS2_WINDOW_TIMEOUT}s"
}

# /api/overlay/start (auto-overlay.patch) closes the stale HUD window
# from openhud-startup (loaded before GSI/match metadata existed) and
# opens a fresh one against populated state. position_openhud_overlay
# then raises it above cs2 in the X stack for compositing.
say "5b. (re-)open + raise OpenHud overlay above cs2"
if openhud_running; then
  log "  triggering /api/overlay/start so HUD reloads with fresh game state"
  if curl -fsS -m 5 -X POST -o /dev/null \
       "http://${OPENHUD_HOST:-127.0.0.1}:${OPENHUD_PORT:-1349}/api/overlay/start"; then
    log "    overlay start ok"
    # Brief pause: createHudWindow returns immediately but the
    # BrowserWindow's first paint takes a moment to land in X.
    sleep 1
  else
    warn "    overlay start request failed — falling back to repositioning existing window"
  fi
  position_openhud_overlay || warn "overlay positioning failed — HUD may not be visible in stream"
else
  log "OpenHud not running — skipping overlay positioning"
fi

# Do NOT windowactivate/windowfocus cs2 here. The patched overlay is
# `focusable: false`, so cs2 holds focus naturally and `xdotool key`
# (XTest) reaches it. windowactivate forces XRaiseWindow which ignores
# Openbox's layer model — verified live to push cs2 above the overlay
# even with _NET_WM_STATE_ABOVE set, breaking compositing in capture.

say "6. start match capture stream"
# 5th arg = 1 → include PulseAudio leg (cs2.monitor → AAC → mpegts mux)
start_capture "$MATCH_ID" "$FPS" "$VIDEO_KBPS" false 1 \
  || die "capture failed to publish — see [gst-${MATCH_ID:0:8}] log lines above"

# Stream is publishing to mediamtx — surface the SRT publish URL on the
# match_streams row and flip is_live=true via the API. The viewer-facing
# HLS URL is set by the API at row-insert time on `link`.
report_status status=live \
  "stream_url=${MEDIAMTX_SRT_BASE}?streamid=publish:${MATCH_ID}"

say "done"
log "watch:    https://${GAME_STREAM_DOMAIN}/${MATCH_ID}/"
log "logs:     kubectl logs (cs2-launch / gst-${MATCH_ID} / spec-server tags)"
log "stop:     src/game-streamer.sh stop-live"

# Keep the K8s Job in a running state — the api decides when the stream
# is over by deleting the Job (stopLive). If we exit 0 here the Job
# would mark Succeeded and the pod would be torn down mid-match.
# We don't `wait` on cs2 or gst-launch because both are run via nohup
# from helper scripts and aren't direct children of this shell — and
# even if cs2 crashes mid-match we'd rather stay up so the operator
# can see the last frames / logs until they explicitly stopLive.
say "holding job alive — waiting for external stop"
while :; do
  sleep 3600 &
  wait $!
done
