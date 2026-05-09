# shellcheck shell=bash
# flythrough.sh — pre-match map flythrough playback (5stack prod fork F4).
#
# When the streamer pod boots a `live` mode for a match, look up an
# operator-provided flythrough mp4 for the match's current map and
# play it fullscreen via mpv on $DISPLAY for the warmup window. The
# already-running gst capture (stage 6 of run-live.sh) picks up the
# mpv output as part of the X display, so viewers see the flythrough
# inline in the live HLS stream before cs2 reaches its first round.
#
# Lookup priority (first hit wins, the rest are skipped):
#   1. /opt/5stack/intros/<map_name>.mp4   (hostPath mount; fastest path,
#                                           no api round-trip)
#   2. ${API_BASE%/}/intros/match/${MATCH_ID}/file
#                                          (api streams the per-match
#                                           binding from S3; honors
#                                           map override + uploader auth)
#
# Failure modes are non-fatal: if no flythrough is available, log and
# return 0 so run-live.sh continues straight into the live game.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${FLYTHROUGH_HOSTPATH:=/opt/5stack/intros}"
: "${FLYTHROUGH_MAX_SECONDS:=45}"
: "${FLYTHROUGH_CACHE_DIR:=${LOG_DIR:-/tmp}/flythroughs}"
export FLYTHROUGH_HOSTPATH FLYTHROUGH_MAX_SECONDS FLYTHROUGH_CACHE_DIR

# Resolve the map name for the current match. We rely on the api's
# /game-streamer/<matchId>/current-map which the prod fork exposes
# alongside STATUS_API_BASE for status reporting. If the api isn't
# reachable or the response is empty (match metadata not yet
# populated, no current map picked), return empty and let the caller
# bail.
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

# Locate a flythrough source file on disk for the given map name.
# Always operates on a local file — if we have to fetch from the api,
# we cache into FLYTHROUGH_CACHE_DIR first so mpv reads from a stable
# path (avoids tee'ing a streaming download into mpv).
flythrough_locate_source() {
  local map_name="$1"
  if [ -z "$map_name" ]; then
    return 1
  fi
  local hp="$FLYTHROUGH_HOSTPATH/${map_name}.mp4"
  if [ -f "$hp" ] && [ -s "$hp" ]; then
    printf '%s' "$hp"
    return 0
  fi

  local api_base="${STATUS_API_BASE:-${API_BASE:-}}"
  if [ -z "$api_base" ]; then
    return 1
  fi
  mkdir -p "$FLYTHROUGH_CACHE_DIR"
  local cached="$FLYTHROUGH_CACHE_DIR/${map_name}.mp4"
  # Always re-fetch on pod boot (cache only survives the pod). The
  # api 302s to a presigned S3 URL when the binding exists; -L
  # follows it. 404 means no binding for this map → bail.
  local code
  code=$(curl -L -fsS -m 60 \
       -o "$cached" \
       -w '%{http_code}' \
       "${api_base%/}/intros/map/${map_name}/file" \
       2>/dev/null) || code=""
  if [ "$code" != "200" ] || [ ! -s "$cached" ]; then
    rm -f "$cached" 2>/dev/null
    return 1
  fi
  printf '%s' "$cached"
}

# play_flythrough — top-level entry. Idempotent / safe to call when
# nothing's available; just logs and returns.
play_flythrough() {
  if [ "${FLYTHROUGH_SKIP:-0}" = "1" ]; then
    log "  flythrough: skipped (FLYTHROUGH_SKIP=1)"
    return 0
  fi
  if ! command -v mpv >/dev/null 2>&1; then
    warn "  flythrough: mpv not installed — skipping (image needs mpv to play intros)"
    return 0
  fi

  local map_name
  map_name=$(flythrough_resolve_map)
  if [ -z "$map_name" ]; then
    log "  flythrough: no current map resolved for ${MATCH_ID:-?} — skipping"
    return 0
  fi
  log "  flythrough: resolved map=$map_name"

  local src
  if ! src=$(flythrough_locate_source "$map_name"); then
    log "  flythrough: no flythrough binding for $map_name (hostPath miss + api 404) — skipping"
    return 0
  fi
  log "  flythrough: playing $src (max ${FLYTHROUGH_MAX_SECONDS}s)"

  # Hide cs2/openhud briefly under mpv. mpv with --ontop --fs --no-osc
  # owns the entire X display while it plays; ximagesrc captures the
  # composite, so viewers see the flythrough — not cs2's main menu /
  # warmup state.
  #
  # --really-quiet  : keep mpv's stdout out of the pod log (gst log is
  #                   already noisy enough)
  # --no-input-default-bindings + --no-input-terminal :
  #                   no keypress on the pod's tty can pause/seek the
  #                   intro mid-stream (we don't have one anyway, but
  #                   defensive — XTest events targeting cs2 must not
  #                   accidentally hit mpv first)
  # --end=<sec>     : hard cap on duration so a 5-min "flythrough"
  #                   can't stall the warmup forever
  # --loop=no       : intros play once, never loop
  # --vo=gpu        : NVDEC path — same GPU we use for nvenc capture,
  #                   so no contention
  local end_arg=""
  if [ "$FLYTHROUGH_MAX_SECONDS" -gt 0 ] 2>/dev/null; then
    end_arg="--end=${FLYTHROUGH_MAX_SECONDS}"
  fi

  DISPLAY="$DISPLAY" mpv \
    --really-quiet \
    --no-input-default-bindings \
    --no-input-terminal \
    --no-osc \
    --no-osd-bar \
    --osd-level=0 \
    --fs \
    --ontop \
    --no-border \
    --loop=no \
    $end_arg \
    --vo=gpu \
    "$src" \
    >/proc/1/fd/1 2>/proc/1/fd/2 \
    || warn "  flythrough: mpv exited with non-zero (continuing — match still proceeds)"

  log "  flythrough: done"
}
