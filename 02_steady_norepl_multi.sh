#!/usr/bin/env bash
set -euo pipefail
APP="${APP:-${1:-social-network}}"
mkdir -p "results/${APP}/norepl"

CFG="apps/${APP}/config.json"
WRK=wrk
URL="$(jq -r '.front_url' "$CFG")"
SCRIPT="$(jq -r '.wrk2.script' "$CFG")"
T="$(jq -r '.wrk2.threads' "$CFG")"
C="$(jq -r '.wrk2.connections' "$CFG")"
D="$(jq -r '.wrk2.duration' "$CFG")"
R="$(jq -r '.wrk2.rate' "$CFG")"

echo "[steady-norepl] ${APP} -> ${URL}"
$WRK -t"$T" -c"$C" -d"$D" -L -s "$SCRIPT" "$URL" -R "$R" \
  | tee "results/${APP}/norepl/wrk.txt"

# Export live deps from Jaeger, then model (no static deps committed)
DEPS="results/${APP}/norepl/deps.json"
./00_helpers/export_deps.sh --out "$DEPS"
python3 resilience.py "$DEPS" --repl 0 \
  -o "results/${APP}/norepl/R_avg_base.json"
