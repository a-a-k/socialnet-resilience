#!/usr/bin/env bash
set -e

if [ ! -d venv ]; then
  echo "🔧  creating venv ..."
  python3 -m venv venv
  ./venv/bin/pip install -q --upgrade pip
  ./venv/bin/pip install -q networkx numpy aiohttp scipy
fi

source ./venv/bin/activate
echo "✅  venv activated ($(python -V))"

MODEL=DeathStarBench/socialNetwork/results/norepl/R_avg_base.json
LIVE=DeathStarBench/socialNetwork/results/norepl/summary.json
OUT=DeathStarBench/socialNetwork/results/norepl/summary_norepl.json

jq -n \
  --arg m "$(jq .R_avg  "$MODEL")" \
  --arg l "$(jq .R_live "$LIVE")" \
  '{R_model_norepl: ($m|tonumber), R_live_norepl: ($l|tonumber)}' \
  > "$OUT"

echo "==> Combined summary for NOREPL written to $OUT"
cat "$OUT"
