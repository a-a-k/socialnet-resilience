#!/usr/bin/env bash
set -euo pipefail

echo "steady_norepl_multi is starting..."

APP="${APP:-${1:-social-network}}"
MODE_DIR="norepl"
mkdir -p "results/${APP}/${MODE_DIR}"

# Resolve wrk2 from PATH (allow override via env)
WRK=wrk

# Load per-app config
SAMPLES="${SAMPLES:-500000}"
P_FAIL="${P_FAIL:-0.30}"
SEED="${SEED:-16}"
CFG="apps/${APP}/config.json"
URL="$(jq -r '.front_url' "$CFG")"
SCRIPT="$(jq -r '.wrk2.script' "$CFG")"
T="$(jq -r '.wrk2.threads' "$CFG")"
C="$(jq -r '.wrk2.connections' "$CFG")"
D="$(jq -r '.wrk2.duration' "$CFG")"
R="$(jq -r '.wrk2.rate' "$CFG")"
COMPOSE_PROJECT="$(jq -r '.compose_project' "$CFG")"

# Compose helpers and app directory
source 00_helpers/app_paths.sh
APP_DIR="$(app_dir_for "$APP")"
DC="$(compose_cmd)"
TARGET="$URL"
OVERRIDE="overrides/docker-compose.override.yml"
#case "$APP" in
#  social-network)
#    OVERRIDE="overrides/sn-jaeger.override.yml"
#    ;;
#  media-service)
#    OVERRIDE="overrides/ms-jaeger.override.yml"
#    ;;
#  hotel-reservation)
#    OVERRIDE="overrides/hr-jaeger.override.yml"
#    ;;
#esac

echo "configured..."

# Bring the stack up (as in the original steady scripts)
(
  cd "third_party/DeathStarBench/${APP_DIR}"
  if [[ -f "$OVERRIDE" ]]; then
    echo "overriding docker compose with OVERRIDE=$OVERRIDE ..."
    $DC -p "${COMPOSE_PROJECT}" -f docker-compose.yml -f "$OVERRIDE" up -d
  else
    echo "not overriding docker compose."
    $DC -p "${COMPOSE_PROJECT}" up -d
  fi
)

echo "composed..."

# Priming (same behavior as the original pipelines)
# --- Resolve target endpoint per app (do NOT depend on lua 'url' global) ---
# Some DSB lua scripts expect a full endpoint path to be provided to wrk
# (e.g., media-service requires /wrk2-api/review/compose). Others work with base URL.
case "$APP" in
  social-network)
    (
      cd third_party/DeathStarBench/socialNetwork
      python3 scripts/init_social_graph.py --graph socfb-Reed98 --compose --ip 127.0.0.1 --port 8080
    )
    TARGET="${URL%/}/index.html"
    ;;
  media-service)
    (
      cd third_party/DeathStarBench/mediaMicroservices
      if [[ -f datasets/tmdb/casts.json && -f datasets/tmdb/movies.json ]]; then
        python3 scripts/write_movie_info.py -c datasets/tmdb/casts.json -m datasets/tmdb/movies.json --server_address "http://127.0.0.1:8080"
        bash scripts/register_users.sh
      fi
    )
    TARGET="${URL%/}"
    SCRIPT="00_helpers/ms-compose-review.lua"
    ;;
  hotel-reservation)
    TARGET="${URL%/}/tcp"
    ;;
  *)
    TARGET="$URL"
    ;;
esac

echo "primed..."

# Small readiness wait for the frontend
echo "[steady-norepl] waiting for frontend: ${URL}"
timeout 60 bash -c "until curl -fsS '$URL' >/dev/null; do sleep 0.5; done" || true

# Steady workload
export LUA_INIT="url = \"$URL\""
export LUA_INIT_5_1="$LUA_INIT"

echo "[steady-norepl] workload ${APP} -> ${URL}"
# NOTE: we do NOT rely on lua args for base URL (scripts differ across DSB variants).
# We pass the final TARGET to wrk so that scripts don't need a global 'url'.
$WRK -t"$T" -c"$C" -d"$D" -s "$SCRIPT" -R "$R" "$TARGET"

sleep 15

DEPS="results/${APP}/${MODE_DIR}/deps.json"
ts=$(($(date +%s%N)/1000000))
curl -s "http://localhost:16686/api/dependencies?endTs=$ts&lookback=3600000" -o "$DEPS"

# Pass --app so resilience.py picks replicas.json for this app in repl runs
python3 resilience.py "$DEPS" --repl 0 \
  --app "$APP" \
  --p_fail "$P_FAIL" --seed "$SEED" --samples "$SAMPLES" \
  -o "results/${APP}/${MODE_DIR}/R_avg_base.json"

echo "steady_norepl_multi finished."
