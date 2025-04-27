#!/usr/bin/env bash

echo "compose ..."
set -euo pipefail; cd DeathStarBench/socialNetwork
docker compose down
docker compose -f docker-compose.yml up -d       # 1 copy each

# warm-up traffic (30 s, 300 RPS)
echo "wrk ..."

### data
wrk -t2 -c32 -d30s -R400  -s scripts/social-network/setup.lua        http://localhost:8080/index.html
wrk -t2 -c32 -d30s -R1000 -s scripts/social-network/compose-post.lua http://localhost:8080/index.html
echo "✅ data primed"

echo "workload ..."
wrk -t2 -c32 -d30s -R300 \
  -s wrk2/scripts/social-network/mixed-workload.lua \
  http://localhost:8080/index.html

echo "graph ..."
# Jaeger deps & theoretical R_avg
ts=$(($(date +%s%N)/1000000))
curl -s "http://localhost:16686/api/dependencies?endTs=$ts&lookback=3600000" \
     -o deps.json
python3 resilience.py deps.json -o results/R_avg_base.json
jq -n '{"stage":"steady_norepl"}' > results/02_meta.json
echo "✅ steady_norepl done"
