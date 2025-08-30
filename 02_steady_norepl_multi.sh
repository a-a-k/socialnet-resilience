#!/usr/bin/env bash
set -euo pipefail

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
DEPS="results/${APP}/${MODE_DIR}/deps.json"
./00_helpers/export_deps.sh --out "$DEPS"
T="$(jq -r '.wrk2.threads' "$CFG")"
C="$(jq -r '.wrk2.connections' "$CFG")"
D="$(jq -r '.wrk2.duration' "$CFG")"
R="$(jq -r '.wrk2.rate' "$CFG")"
COMPOSE_PROJECT="$(jq -r '.compose_project' "$CFG")"

# Compose helpers and app directory
source 00_helpers/app_paths.sh
APP_DIR="$(app_dir_for "$APP")"
DC="$(compose_cmd)"

# Use one shared Jaeger override for all apps (if present)
OVERRIDE="${OVERRIDE:-$(pwd)/overrides/jaeger.override.yml}"

# Bring the stack up (as in the original steady scripts)
(
  cd "third_party/DeathStarBench/${APP_DIR}"
  if [[ -f "$OVERRIDE" ]]; then
    $DC -p "${COMPOSE_PROJECT}" -f docker-compose.yml -f "$OVERRIDE" up -d
  else
    $DC -p "${COMPOSE_PROJECT}" up -d
  fi
)

# Priming (same behavior as the original pipelines)
case "$APP" in
  social-network)
    (
      cd third_party/DeathStarBench/socialNetwork
      python3 scripts/init_social_graph.py --graph socfb-Reed98 --compose --ip 127.0.0.1 --port 8080
    )
    ;;
  media-service)
    (
      cd third_party/DeathStarBench/mediaMicroservices
      if [[ -f datasets/tmdb/casts.json && -f datasets/tmdb/movies.json ]]; then
        python3 scripts/write_movie_info.py -c datasets/tmdb/casts.json -m datasets/tmdb/movies.json --server_address "http://127.0.0.1:8080"
        bash scripts/register_users.sh
      fi
    )
    ;;
  hotel-reservation)
    :
    ;;
esac

# Small readiness wait for the frontend
echo "[steady-norepl] waiting for frontend: ${URL}"
timeout 60 bash -c "until curl -fsS '$URL' >/dev/null; do sleep 0.5; done" || true

# Steady workload
echo "[steady-norepl] ${APP} -> ${URL}"
$WRK -t"$T" -c"$C" -d"$D" -L -s "$SCRIPT" "$URL" -R "$R" \
  | tee "results/${APP}/${MODE_DIR}/wrk.txt"

# Pass --app so resilience.py picks replicas.json for this app in repl runs
python3 resilience.py --deps "$DEPS" --repl 0 \
  --app "$APP" \
  --p_fail "$P_FAIL" --seed "$SEED" --samples "$SAMPLES" \
  -o "results/${APP}/${MODE_DIR}/R_avg_base.json"
