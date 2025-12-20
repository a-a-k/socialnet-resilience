#!/usr/bin/env bash
set -e

# Optional tunables
SEED=${SEED:-16}
P_FAIL=${P_FAIL:-0.30}
FAIL_FRACTION=${FAIL_FRACTION:-0.30}

if [ ! -d venv ]; then
  echo "🔧  creating venv ..."
  python3 -m venv venv
  ./venv/bin/pip install -q --upgrade pip
  ./venv/bin/pip install -q networkx numpy aiohttp scipy
fi

source ./venv/bin/activate
echo "✅  venv activated ($(python -V))"

./prepare_env.sh
OUTDIR=${OUTDIR:-DeathStarBench/socialNetwork/results/repl}
OUTDIR=$(realpath -m "$OUTDIR")
mkdir -p "$OUTDIR"
SEED="$SEED" P_FAIL="$P_FAIL" FAIL_FRACTION="$FAIL_FRACTION" OUTDIR="$OUTDIR" ./steady_repl.sh
SEED="$SEED" P_FAIL="$P_FAIL" FAIL_FRACTION="$FAIL_FRACTION" OUTDIR="$OUTDIR" ./chaos.sh --repl

MODEL="$OUTDIR/R_avg_repl.json"
LIVE="$OUTDIR/summary.json"
OUT="$OUTDIR/summary_repl.json"

jq -n \
  --arg m "$(jq .R_avg  "$MODEL")" \
  --arg l "$(jq .R_live "$LIVE")" \
  '{R_model_repl: ($m|tonumber), R_live_repl: ($l|tonumber)}' \
  > "$OUT"

echo "==> Combined summary for REPL written to $OUT"
cat "$OUT"

if ! ls "$OUTDIR"/*.json >/dev/null 2>&1; then
  echo "❌ No JSON results found in $OUTDIR" >&2
  exit 1
fi
