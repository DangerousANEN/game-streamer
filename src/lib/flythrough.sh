# shellcheck shell=bash
# flythrough.sh — pre-match map flythrough (5stack prod fork F4).
#
# Plays a *live* spectator-camera flythrough on cs2: the in-engine
# camera is driven through a sequence of map-specific waypoints by the
# spec-server `/cinematic/start` endpoint, which renders the world
# live (warmup players running, bomb plant, smokes mid-round). The
# already-running gst capture (stage 6 of run-live.sh) picks up the
# cs2 window output on $DISPLAY, so viewers see the flythrough inline
# in the live HLS stream before cs2 reaches its first round.
#
# Why not pre-recorded mp4: the user asked specifically for the live
# state of the map to be visible during the flythrough, not a stale
# yesterday-recorded clip. setpos / setang in spec_mode 6 gives us
# free-cam control while the underlying world keeps simulating live.
#
# Lookup priority for the waypoint plan (spec-server handles this):
#   1. /opt/5stack/intros/<map_name>.cinematic.json   (hostPath; admin
#                                                      can edit per map)
#   2. /opt/5stack/intros/<map_name>.json
#   3. baked-in src/cinematic-paths/<map_name>.json   (fallback for
#                                                      active duty)
#
# Failure modes are non-fatal: if no plan is available or cs2 isn't
# focused, the spec-server bails quietly and run-live.sh continues
# straight into the live game.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${FLYTHROUGH_SPEC_BASE:=http://127.0.0.1:1350}"
export FLYTHROUGH_SPEC_BASE

# Resolve the map name for the current match. Hits the prod fork's
# `GET /game-streamer/<matchId>/current-map` (no auth, in-cluster).
flythrough_resolve_map() {
  local match_id="${MATCH_ID:-}"
  if [ -z "$match_id" ]; then
    echo ""
    return 0
  fi
  local api_base="${STATUS_API_BASE:-${API_BASE:-}}"
  if [ -z "$api_base" ]; then
    echo ""
    return 0
  fi
  local resp
  resp=$(curl -fsS -m 5 \
       "${api_base%/}/game-streamer/${match_id}/current-map" \
       2>/dev/null) || resp=""
  if [ -z "$resp" ]; then
    echo ""
    return 0
  fi
  # Accept either a bare string or {"map":"de_inferno"} JSON.
  local trimmed
  trimmed=$(printf '%s' "$resp" | tr -d '"{}\r\n ' | tr -d "'")
  case "$trimmed" in
    map:*) printf '%s' "${trimmed#map:}" ;;
    *)     printf '%s' "$trimmed" ;;
  esac
}

# play_flythrough — top-level entry. Idempotent / safe to call when
# nothing's available; just logs and returns.
play_flythrough() {
  if [ "${FLYTHROUGH_SKIP:-0}" = "1" ]; then
    log "  flythrough: skipped (FLYTHROUGH_SKIP=1)"
    return 0
  fi

  local map_name
  map_name=$(flythrough_resolve_map)
  if [ -z "$map_name" ]; then
    log "  flythrough: no current map resolved for ${MATCH_ID:-?} — skipping"
    return 0
  fi
  log "  flythrough: requesting cinematic camera for map=$map_name"

  # Kick off the live cinematic via spec-server. Body is short JSON;
  # spec-server returns 202 + {ok,map} on accept, then runs
  # asynchronously. We DON'T block on the cinematic itself — cs2's
  # warmup is parallel work; the viewer sees the camera fly during
  # warmup AND any subsequent gameplay state until the waypoint plan's
  # `duration_seconds` budget is spent.
  local resp
  resp=$(curl -fsS -m 6 \
       -H 'content-type: application/json' \
       -d "{\"map\":\"${map_name}\"}" \
       "${FLYTHROUGH_SPEC_BASE%/}/cinematic/start" \
       2>/dev/null) || resp=""
  if [ -z "$resp" ]; then
    warn "  flythrough: spec-server /cinematic/start did not respond — skipping"
    return 0
  fi
  log "  flythrough: spec-server -> $resp"
}
