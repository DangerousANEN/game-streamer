#!/usr/bin/env bash
# Flow 1 — bring up Steam in a state where CS2 can be launched/updated.
# Idempotent. Required env: STEAM_USER, STEAM_PASSWORD.

set -uo pipefail
SCRIPT_TAG=setup-steam

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
. "$LIB_DIR/openhud.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/spec-server.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/status-reporter.sh"

load_env
require_env STEAM_USER STEAM_PASSWORD

: "${DEBUG_STREAM_ID:=debug}"
: "${STEAM_PIPE_TIMEOUT:=300}"

start_status_reporter
# Pod is up; X/pulse/openhud spin up next. We don't emit a "preparing"
# status — the UI doesn't surface it. The next reportable status is
# launching_steam (or downloading_cs2 on cold-start), emitted below.

say "1. Xorg + openbox + X access"
start_xorg

say "1b. PulseAudio + cs2 null sink"
start_pulseaudio

# Spectator control daemon — exposes POST /spec/{click,jump,player,
# autodirector} on $SPEC_SERVER_PORT (default 1350). Lets the 5stack
# web app (or any HTTP client) drive cs2's spectator slot without a
# full remote-desktop session. Started before cs2 launches so the
# operator's first click after match start hits a ready endpoint.
say "1bb. spec-server (cs2 control HTTP daemon)"
start_spec_server

# OpenHud overlay stack. Spawned now but the wait-for-server +
# hide-admin + position-overlay work runs LATER (just before cs2
# launches) so the 3-5s OpenHud bootstrap overlaps the Steam launch +
# pipe wait + UI render — net ~3-5s shaved off the critical path.
# The overlay isn't needed until cs2 actually spawns, so deferring is
# safe; run-live re-raises it after cs2's window appears anyway.
say "1c. picom (compositor) + OpenHud server (background)"
OPENHUD_DEFERRED=0
# Auto-highlight batch renders skip OpenHud entirely. The batch pod's
# job is to record per-player frag clips with a clean cs2 view —
# OpenHud's spectator overlay was making the rendered mp4s carry the
# scoreboard / killfeed widgets we don't want baked into the clip
# (operators do their own overlays in post). This is the ONLY pod mode
# we want stripped: live spec sessions, demo viewers, and one-off clip
# renders all still want the HUD.
if [ "${CLIP_BATCH_MODE:-0}" = "1" ]; then
  log "CLIP_BATCH_MODE=1 — skipping OpenHud (auto-highlights render without overlay)"
elif [ "${OPENHUD_DISABLED:-0}" = "1" ]; then
  log "OPENHUD_DISABLED=1 — raw stream (HUD will be rendered by OBS Browser Source instead)"
elif [ -x "$OPENHUD_BIN" ]; then
  start_picom || warn "continuing without picom (HUD background won't be transparent)"
  start_openhud
  OPENHUD_DEFERRED=1
  log "  openhud spawned — wait/positioning deferred to overlap Steam boot"
else
  log "OpenHud not installed at $OPENHUD_BIN — skipping HUD setup"
  log "  rebuild image with --build-arg OPENHUD_VERSION=vX.Y.Z to enable"
fi

if [ "${DEBUG_CAPTURE:-0}" = "1" ]; then
  say "2. debug capture stream"
  start_capture "$DEBUG_STREAM_ID" 30 4000 true 0
  log "watch login: https://${GAME_STREAM_DOMAIN}/${DEBUG_STREAM_ID}/"
fi

say "3. clean up any prior Steam/cs2 processes"
kill_steam

# Symlink $STEAM_HOME into the persisted cache mount BEFORE we touch
# any Steam state. This avoids the dual-bind-mount EXDEV bug where
# /root/.local/share/Steam was its own bind mount of the same hostPath
# as /mnt/game-streamer — Steam's self-update rename across the two
# would fail with error 18.
say "3a. persist Steam home via symlink into cache mount"
ensure_steam_home_persist

# Fix lingering ownership/perms + nuke stale package cache. Must run
# AFTER kill_steam (so we're not racing Steam) and AFTER the persist
# symlink (so we operate on the right path).
say "3b. fix Steam-home permissions + nuke stale package cache"
fix_steam_perms

say "4. register steam library at $STEAM_LIBRARY"
mkdir -p "$STEAM_LIBRARY/steamapps/common"
register_library "$STEAM_LIBRARY"

# Install/update CS2 via steamcmd directly. Steam is OFF here (we
# killed it at step 3), so steamcmd and Steam won't fight over
# appmanifest. After this Steam picks up the install on launch and
# the Install dialog never appears.
#
# install_cs2_via_steamcmd emits its own status=downloading_cs2 only
# when an install actually runs — pre-cached pods skip that stage so
# the UI doesn't light up a misleading download bar.
say "5. install/update CS2 via steamcmd"
install_cs2_via_steamcmd

# Must run while Steam is OFF — Steam clobbers localconfig.vdf on shutdown.
# Without this CS2 pops a "Cloud Out of Date" CEF dialog we can't auto-dismiss.
# On first boot there's no userdata/ yet, so this is a no-op; we cycle Steam
# below once Steam has written its initial localconfig.vdf.
#
# HAD_USERDATA also gates the warm-boot fast-path: with userdata/ present
# AND loginusers.vdf present, Steam reuses the cached refresh token instead
# of re-auth'ing the password on -login, which trims a few more seconds
# off the logging_in phase. Both files live under the persistent cache
# mount via ensure_steam_home_persist, so they survive pod restarts.
HAD_USERDATA=0
HAS_LOGIN_TOKEN=0
[ -d "$STEAM_HOME/userdata" ] && HAD_USERDATA=1
[ -s "$STEAM_HOME/config/loginusers.vdf" ] && HAS_LOGIN_TOKEN=1
if [ "$HAD_USERDATA" = 1 ] && [ "$HAS_LOGIN_TOKEN" = 1 ]; then
  log "boot mode: WARM (userdata + loginusers.vdf cached → fast login expected)"
elif [ "$HAD_USERDATA" = 1 ]; then
  log "boot mode: PARTIAL (userdata cached but no loginusers.vdf → password re-auth)"
else
  log "boot mode: COLD (no cached state → first-time login + cloud-disable cycle)"
fi

say "6. disable Steam Cloud sync (global + per-app)"
disable_cloud_globally
disable_cloud_in_config_vdf
disable_cs2_cloud
print_cloud_state

say "6b. disable Steam in-game overlay (global + per-app)"
disable_overlay_globally
disable_cs2_overlay
print_overlay_state

say "7. launch Steam"
report_status status=launching_steam
start_steam

say "8. wait for steam pipe"
wait_for_steam_pipe "$STEAM_PIPE_TIMEOUT" \
  || die "pipe never came up — check [steam] log lines and the debug stream"

# Finish the OpenHud bringup we deferred from stage 1c. By now openhud
# has had at least the Xorg/pulse/spec-server setup time + Steam
# launch + Steam pipe wait (~5-10s) to come up, so wait_for_server
# usually returns immediately. Falling back gracefully if it didn't
# come up at all — the overlay is ornamental for boot purposes.
if [ "$OPENHUD_DEFERRED" = "1" ]; then
  say "8b. finish OpenHud bringup (was started in 1c)"
  if wait_for_openhud_server 60; then
    hide_openhud_admin_window
    # Pre-position the overlay even though run-live re-raises it
    # after cs2 spawns — the early position prevents a frame of
    # mis-placed HUD in the captured stream.
    position_openhud_overlay \
      || warn "early overlay positioning failed — will retry after cs2"
  else
    warn "OpenHud server didn't come up — continuing without HUD overlay"
  fi
fi

# Background match-cfg prep (OpenHud GSI cfg + api DB seed) overlaps
# the 30-50s Steam UI wait. Marker files signal run-live: -prepared
# (full run), -failed (retry inline), -skipped (no MATCH_ID/API_BASE —
# critical so run-live doesn't wait for a marker that never comes).
rm -f "$LOG_DIR/match-cfgs-prepared" \
      "$LOG_DIR/match-cfgs-failed" \
      "$LOG_DIR/match-cfgs-skipped"
if [ -n "${MATCH_ID:-}" ] && [ -n "${API_BASE:-}" ]; then
  (
    # set -e: a write_openhud_gsi_cfg failure must flip the marker to
    # `match-cfgs-failed` rather than silently proceeding to seed_openhud_db
    # and writing `match-cfgs-prepared` while the GSI cfg is missing.
    set -euo pipefail
    SCRIPT_TAG=cfg-prep
    if write_openhud_gsi_cfg && seed_openhud_db "$MATCH_ID"; then
      : > "$LOG_DIR/match-cfgs-prepared"
    else
      : > "$LOG_DIR/match-cfgs-failed"
    fi
  ) &
  log "match-cfgs prep spawned (pid $!) — will overlap Steam wait"
else
  : > "$LOG_DIR/match-cfgs-skipped"
  log "match-cfgs prep skipped (no MATCH_ID or API_BASE) — run-live will skip the wait"
fi

# Steam pipe → Steam UI window is the strict "Steam is fully up"
# gate. We require BOTH the IPC pipe AND a rendered main window
# before allowing cs2 to launch — Web Helper has to be bootstrapped
# end-to-end, otherwise +applaunch silently drops AND direct-exec
# starts cs2 against a half-initialised Steam where the demo never
# loads. Demo and live both take this proven path.
say "9. wait for main Steam window (login + UI render)"
report_status status=logging_in
wait_for_main_steam_window "${STEAM_WINDOW_TIMEOUT:-300}" \
  || die "main Steam window not visible — Steam may still be downloading runtimes"

# First-boot auto-cycle: Steam has now logged in and written a fresh
# localconfig.vdf + sharedconfig.vdf with cloud sync ENABLED.
# SIGKILL avoids a graceful shutdown (which would rewrite both files
# from in-memory state and undo our edits), then we edit + relaunch.
if [ "$HAD_USERDATA" = 0 ]; then
  say "10. first-boot: cycle Steam to apply cloud-sync disable"
  # Belt-and-suspenders: even though main window appeared, give the
  # roaming-config sync a moment to land sharedconfig.vdf on disk
  # before we SIGKILL.
  for _ in $(seq 1 20); do
    [ -d "$STEAM_HOME/userdata" ] && break
    sleep 0.5
  done
  kill_steam
  disable_cloud_globally
  disable_cloud_in_config_vdf
  disable_cs2_cloud
  print_cloud_state
  disable_overlay_globally
  disable_cs2_overlay
  print_overlay_state
  start_steam
  wait_for_steam_pipe "$STEAM_PIPE_TIMEOUT" \
    || die "pipe never came up after cycle — check [steam] log lines"
  wait_for_main_steam_window "${STEAM_WINDOW_TIMEOUT:-300}" \
    || die "main Steam window not visible after cycle"
fi

say "done"
log "Steam is fully up. next: src/game-streamer.sh run-live"
