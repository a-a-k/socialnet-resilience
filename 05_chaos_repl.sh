#!/usr/bin/env bash
set -euo pipefail; cd DeathStarBench/socialNetwork
bash 00_helpers/just_kill.sh 0.30 & chaos=$!

wrk2/wrk -t2 -c64 -d60s -R300 \
  -s scripts/social-network/mixed-workload.lua \
  http://localhost:8080/index.html > wrk_repl.log 2>&1
kill $chaos || true

errors=$(grep -o 'Non-2xx or 3xx responses: [0-9]\+' wrk_repl.log | awk '{print $NF}')
total=$(grep -o '[0-9]\+ requests in' wrk_repl.log | awk '{print $1}')
jq -n --argjson e "${errors:-0}" --argjson t "$total" \
     '{stage:"chaos_repl", total:t, errors:e}' \
     > results/live_repl.json
echo "✅ chaos_repl done"
