#!/usr/bin/env bash
set -e

# Optional tunables
SEED=${SEED:-16}
P_FAIL=${P_FAIL:-0.30}
FAIL_FRACTION=${FAIL_FRACTION:-0.30}

echo "🏨 Hotel Reservation Pipeline (With Replication)"
echo "================================================"
echo "SEED: $SEED"
echo "P_FAIL: $P_FAIL"
echo "FAIL_FRACTION: $FAIL_FRACTION"
echo "================================================"

# Create Python virtual environment if it doesn't exist
if [ ! -d venv ]; then
  echo "🔧  creating venv ..."
  python3 -m venv venv
  ./venv/bin/pip install -q --upgrade pip
  ./venv/bin/pip install -q networkx numpy aiohttp scipy
fi

source ./venv/bin/activate
echo "✅  venv activated ($(python -V))"

# Run environment preparation
echo "🚀  preparing hotel-reservation environment ..."
./01_prepare_env.sh

# Set up output directory for hotel reservation
OUTDIR=${OUTDIR:-DeathStarBench/hotelReservation/results/hotel-repl}
OUTDIR=$(realpath -m "$OUTDIR")
mkdir -p "$OUTDIR"

echo "📊  running steady state analysis (with replication) ..."
SEED="$SEED" P_FAIL="$P_FAIL" OUTDIR="$OUTDIR" ./04_steady_repl.sh

echo "💥  running chaos engineering tests (with replication) ..."
SEED="$SEED" P_FAIL="$P_FAIL" FAIL_FRACTION="$FAIL_FRACTION" OUTDIR="$OUTDIR" ./hotel-chaos.sh --repl

# Combine results
MODEL="$OUTDIR/R_avg_repl.json"
LIVE="$OUTDIR/summary.json"
OUT="$OUTDIR/summary_hotel_repl.json"

echo "📈  combining results ..."
jq -n \
  --arg m "$(jq .R_avg  "$MODEL")" \
  --arg l "$(jq .R_live "$LIVE")" \
  --arg app "hotel-reservation" \
  --arg mode "repl" \
  '{
    application: $app,
    mode: $mode,
    R_model_repl: ($m|tonumber), 
    R_live_repl: ($l|tonumber),
    resilience_gap: (($m|tonumber) - ($l|tonumber)),
    seed: '"$SEED"',
    p_fail: '"$P_FAIL"',
    fail_fraction: '"$FAIL_FRACTION"'
  }' \
  > "$OUT"

echo "==> Combined summary for HOTEL-RESERVATION REPL written to $OUT"
cat "$OUT"

# Validate results
if ! ls "$OUTDIR"/*.json >/dev/null 2>&1; then
  echo "❌ No JSON results found in $OUTDIR" >&2
  exit 1
fi

echo "✅  Hotel Reservation Pipeline (With Replication) completed successfully!"
echo "📁  Results directory: $OUTDIR"
echo "📊  Summary file: $OUT"
