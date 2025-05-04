#!/usr/bin/env bash
set -euo pipefail

cd DeathStarBench/socialNetwork || exit

# Create results directory if it doesn't exist
mkdir -p results

# Start chaos in background and capture PID
bash 00_helpers/just_kill.sh 0.30 & 
chaos_pid=$!

# Run wrk and save to log file
wrk_log="results/wrk_repl.log"
wrk -t2 -c64 -d60s -R300 \
  -s scripts/social-network/mixed-workload.lua \
  http://localhost:8080/index.html > "$wrk_log" 2>&1 || true

# Kill chaos process if still running
kill "$chaos_pid" 2>/dev/null || true

# Extract metrics from log (with defaults if not found)
errors=$(grep -o 'Non-2xx or 3xx responses: [0-9]\+' "$wrk_log" | awk '{print $NF}' || echo "0")
total=$(grep -o '[0-9]\+ requests in' "$wrk_log" | awk '{print $1}' || echo "0")

# Create JSON result
jq -n --arg e "$errors" --arg t "$total" \
  '{stage:"chaos_repl", total:($t | tonumber), errors:($e | tonumber)}' \
  > results/live_repl.json

echo "✅ chaos_repl done"
