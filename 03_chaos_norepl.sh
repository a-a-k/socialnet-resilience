#!/usr/bin/env bash
set -euo pipefail; cd DeathStarBench/socialNetwork
bash 00_helpers/just_kill.sh 0.30 & chaos=$!

wrk -t2 -c64 -d60s -R300 \
  -s wrk2/scripts/social-network/mixed-workload.lua \
  http://localhost:8080/index.html > wrk1.log 2>&1
  
kill $chaos || true

errors=$(grep -Eo 'Non-2xx or 3xx responses:[[:space:]]*[0-9]+' wrk1.log \
         | awk '{print $NF}' || echo 0)
total=$(grep -Eo '[0-9]+ requests in' wrk1.log \
        | awk '{print $1}' || echo 0)

mkdir -p results
jq -n --argjson t "$total" --argjson e "$errors" \
      '{stage:"chaos_norepl", total:$t, errors:$e}' \
      > results/live_base.json
      
echo "✅ chaos_norepl done"
