#!/usr/bin/env bash

echo "compose ..."
set -euo pipefail; cd DeathStarBench/socialNetwork
mkdir results

docker compose down
docker compose up -d

### data
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

python3 resilience.py deps.json -o results/norepl/R_avg_base.json

echo "✅ steady_norepl done"
