# shellcheck shell=bash
# Per-match spectator HUD seeding + spec-server GSI cfg.
#
# DangerousANEN production-features fork:
#   - seed_match_hud   : pulls the active HUD pack for $MATCH_ID from the
#                        api and unpacks it into /root/OpenHud-Huds/<slug>
#                        so OpenHud picks it up at overlay start. The pack
#                        is a zip with a `build/` root (see api/src/huds).
#                        Falls through silently if the api can't reach
#                        us, the match has no override and there is no
#                        global default, or the response isn't a zip.
#                        Always non-fatal — OpenHud's bundled HUD remains
#                        the fallback.
#
#   - write_spec_gsi_cfg : drops the second GSI cfg pointing at the
#                        spec-server's /gsi endpoint (default port 1350).
#                        cs2's GSI plugin loader silently honours
#                        multiple gamestate_integration_*.cfg files in
#                        cfg/, so this lives alongside the openhud cfg
#                        without conflict. Required for round-end
#                        highlight detection (F3 auto-director).

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${HUDS_ROOT:=/root/OpenHud-Huds}"
: "${SPEC_SERVER_HOST:=127.0.0.1}"
: "${SPEC_SERVER_PORT:=1350}"
: "${SPEC_GSI_TOKEN:=5stack-spec}"
: "${SPEC_GSI_NAME:=5stack}"

slugify_hud() {
  local s="$1"
  printf '%s' "$s" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
    | cut -c1-64
}

# Resolve + download the per-match HUD into $HUDS_ROOT/<slug>/build/.
# Reads the slug from the api's `GET /huds/active/:matchId` and pulls
# the zip from `GET /huds/<id>/download`. Both endpoints accept the
# same auth bearer the streamer pod already uses for other api calls.
seed_match_hud() {
  if [ -z "${API_BASE:-}" ] || [ -z "${MATCH_ID:-}" ]; then
    log "  match-hud: API_BASE / MATCH_ID missing — using bundled OpenHud"
    return 0
  fi

  mkdir -p "$HUDS_ROOT"

  local headers=(-H "accept: application/json")
  if [ -n "${API_TOKEN:-}" ]; then
    headers+=(-H "authorization: Bearer ${API_TOKEN}")
  fi

  local active_url="${API_BASE%/}/huds/active/${MATCH_ID}"
  local active_json
  active_json=$(curl -fsS -m 5 "${headers[@]}" "$active_url" 2>/dev/null) || {
    log "  match-hud: no active HUD for $MATCH_ID (using bundled OpenHud)"
    return 0
  }

  local hud_id hud_slug
  hud_id=$(printf '%s' "$active_json" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id",""))' \
    2>/dev/null) || hud_id=""
  hud_slug=$(printf '%s' "$active_json" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("slug",""))' \
    2>/dev/null) || hud_slug=""
  if [ -z "$hud_id" ] || [ -z "$hud_slug" ]; then
    log "  match-hud: api returned no usable HUD descriptor"
    return 0
  fi

  local target="$HUDS_ROOT/$hud_slug"
  if [ -f "$target/.hud-id" ] && [ "$(cat "$target/.hud-id")" = "$hud_id" ] \
     && [ -f "$target/build/index.html" ]; then
    log "  match-hud: $hud_slug already up-to-date — skipping download"
    return 0
  fi

  rm -rf "$target"
  mkdir -p "$target/build"

  # Walk the manifest the api wrote at upload time. The streamer fetches
  # each file individually from /huds/<slug>/files/<rel> — no archiver
  # dep on the api side, no zip-on-the-fly, just a plain http mirror.
  local manifest_url="${API_BASE%/}/huds/${hud_slug}/manifest"
  local manifest_json
  manifest_json=$(curl -fsS -m 10 "${headers[@]}" "$manifest_url" 2>/dev/null) || {
    warn "  match-hud: manifest fetch failed from $manifest_url"
    rm -rf "$target"
    return 0
  }

  local files
  files=$(printf '%s' "$manifest_json" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(f["path"] for f in d.get("files",[])))' \
    2>/dev/null) || files=""
  if [ -z "$files" ]; then
    warn "  match-hud: empty manifest"
    rm -rf "$target"
    return 0
  fi

  local count=0 fail=0
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    case "$rel" in *..*) continue ;; esac
    local out="$target/build/$rel"
    mkdir -p "$(dirname "$out")"
    if curl -fsS -m 30 "${headers[@]}" -o "$out" \
       "${API_BASE%/}/huds/${hud_slug}/files/${rel}"; then
      count=$((count + 1))
    else
      fail=$((fail + 1))
    fi
  done <<< "$files"

  if [ ! -f "$target/build/index.html" ]; then
    warn "  match-hud: $hud_slug mirror failed (no build/index.html, fail=$fail/count=$count)"
    rm -rf "$target"
    return 0
  fi

  printf '%s\n' "$hud_id" > "$target/.hud-id"
  log "  match-hud: seeded $hud_slug ($hud_id) -> $target ($count files, $fail failed)"
}

# Write the spec-server GSI cfg next to OpenHud's. cs2 picks up every
# gamestate_integration_*.cfg in cfg/ at engine init.
write_spec_gsi_cfg() {
  local cfg_dir="${CS2_DIR:-/opt/instance/game}/csgo/cfg"
  if [ ! -d "$cfg_dir" ]; then
    warn "  spec-gsi: $cfg_dir doesn't exist yet — skipping (cs2 install pending)"
    return 0
  fi

  local cfg_path="$cfg_dir/gamestate_integration_${SPEC_GSI_NAME}.cfg"
  cat > "$cfg_path" <<EOF
"5stack Spec GSI"
{
  "uri"         "http://${SPEC_SERVER_HOST}:${SPEC_SERVER_PORT}/gsi"
  "timeout"     "5.0"
  "buffer"      "0.0"
  "throttle"    "0.05"
  "heartbeat"   "5.0"
  "auth" {
    "token" "${SPEC_GSI_TOKEN}"
  }
  "data" {
    "provider"             "1"
    "map"                  "1"
    "round"                "1"
    "player_id"            "1"
    "player_state"         "1"
    "player_weapons"       "1"
    "player_match_stats"   "1"
    "allplayers_id"        "1"
    "allplayers_state"     "1"
    "allplayers_match_stats" "1"
    "allplayers_weapons"   "1"
    "allplayers_position"  "1"
    "allgrenades"          "1"
    "phase_countdowns"     "1"
    "round_damage"         "1"
    "bomb"                 "1"
  }
}
EOF
  log "  spec-gsi: wrote $cfg_path -> http://${SPEC_SERVER_HOST}:${SPEC_SERVER_PORT}/gsi"
}
