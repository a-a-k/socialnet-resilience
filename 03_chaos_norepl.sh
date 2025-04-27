#!/usr/bin/env bash
set -euo pipefail; cd DeathStarBench/socialNetwork
bash 00_helpers/just_kill.sh 0.30 & chaos=$!

wrk2/scripts/wrk2/wrk -t2 -c64 -d60s -R300 \
  -s scripts/social-network/mixed-workload.lua \
  http://localhost:8080/index.html > wrk.log 2>&1
kill $chaos || true

errors=$(grep -o 'Non-2xx or 3xx responses: [0-9]\+' wrk.log | awk '{print $NF}')
total=$(grep -o '[0-9]\+ requests in'             wrk.log | awk '{print $1}')
jq -n --argjson e "${errors:-0}" --argjson t "$total" \
     '{stage:"chaos_norepl", total:t, errors:e}' \
     > results/live_base.json
echo "✅ chaos_norepl done"
