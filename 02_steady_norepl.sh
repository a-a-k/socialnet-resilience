#!/usr/bin/env bash

echo "compose ..."
set -euo pipefail; cd DeathStarBench/socialNetwork
docker compose down
docker compose -f docker-compose.yml up -d       # 1 copy each

# warm-up traffic (30 s, 300 RPS)
echo "wrk ..."

### data
python3 scripts/init_social_graph.py --graph socfb-Reed98
python3 scripts/init_social_graph.py --graph socfb-Reed98 --compose --ip 127.0.0.1 --port 8080
echo "✅ data primed"

echo "workload ..."
wrk -t2 -c32 -d30s -R300 \
  -s wrk2/scripts/social-network/mixed-workload.lua \
  http://localhost:8080/index.html

sleep 60
echo "graph ..."

# Jaeger deps & theoretical R_avg
ts=$(($(date +%s%N)/1000000))
curl -s "http://localhost:16686/api/dependencies?endTs=$ts&lookback=3600000" \
     -o deps.json
python3 resilience.py deps.json -o results/R_avg_base.json
jq -n '{"stage":"steady_norepl"}' > results/02_meta.json
echo "✅ steady_norepl done"
