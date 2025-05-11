#!/usr/bin/env bash
set -e

BASE_SEED="${BASE_SEED:-16}"

if [ ! -d venv ]; then
  echo "🔧  creating venv ..."
  python3 -m venv venv
  ./venv/bin/pip install -q --upgrade pip
  ./venv/bin/pip install -q networkx numpy aiohttp scipy
fi

source ./venv/bin/activate
echo "✅  venv activated ($(python -V))"

./01_prepare_env.sh
./04_steady_repl.sh
./chaos.sh --seed "$BASE_SEED" --repl

MODEL=DeathStarBench/socialNetwork/results/repl/R_avg_repl.json
LIVE=DeathStarBench/socialNetwork/results/repl/summary.json
OUT=DeathStarBench/socialNetwork/results/repl/summary_repl.json

jq -n \
  --arg m "$(jq .R_avg  "$MODEL")" \
  --arg l "$(jq .R_live "$LIVE")" \
  '{R_model_repl: ($m|tonumber), R_live_repl: ($l|tonumber)}' \
  > "$OUT"

echo "==> Combined summary for REPL written to $OUT"
cat "$OUT"
