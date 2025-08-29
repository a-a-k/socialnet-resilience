#!/usr/bin/env bash
set -euo pipefail
APP="${APP:-${1:-social-network}}"
mkdir -p "results/${APP}/repl"

CFG="apps/${APP}/config.json"
WRK="third_party/DeathStarBench/wrk2/wrk"
URL="$(jq -r '.front_url' "$CFG")"
SCRIPT="$(jq -r '.wrk2.script' "$CFG")"
T="$(jq -r '.wrk2.threads' "$CFG")"
C="$(jq -r '.wrk2.connections' "$CFG")"
D="$(jq -r '.wrk2.duration' "$CFG")"
R="$(jq -r '.wrk2.rate' "$CFG")"
COMPOSE_PROJECT="$(jq -r '.compose_project' "$CFG")"
REPLICAS_FILE="$(jq -r '.replicas_file' "$CFG")"

# Scale services for the replicated scenario (SN prefilled; others default=1)
if [[ -f "$REPLICAS_FILE" ]]; then
  SCALE_ARGS=$(jq -r 'to_entries | map(select(.key!="default") | "--scale \(.key)=\(.value)") | join(" ")' "$REPLICAS_FILE")
  if [[ -n "$SCALE_ARGS" ]]; then
    source 00_helpers/app_paths.sh
    APP_DIR="$(app_dir_for "$APP")"
    DC="$(compose_cmd)"
    echo "[steady-repl] scaling ${APP}: ${SCALE_ARGS}"
    (
      cd "third_party/DeathStarBench/${APP_DIR}"
      $DC -p "${COMPOSE_PROJECT}" up -d ${SCALE_ARGS}
    )
  fi
fi

echo "[steady-repl] ${APP} -> ${URL}"
$WRK -D exp -t"$T" -c"$C" -d"$D" -L -s "$SCRIPT" "$URL" -R "$R" \
  | tee "results/${APP}/repl/wrk.txt"

DEPS="results/${APP}/repl/deps.json"
./00_helpers/export_deps.sh --out "$DEPS"
python3 resilience.py "$DEPS" --repl 1 \
  -o "results/${APP}/repl/R_avg_repl.json"
