#!/usr/bin/env bash
set -euo pipefail; cd DeathStarBench/socialNetwork
docker compose up -d \
  --scale compose-post-service=3 \
  --scale home-timeline-service=3 \
  --scale user-timeline-service=3 \
  --scale text-service=3 \
  --scale media-service=3

# warm-up traffic (30 s, 300 RPS)
echo "wrk ..."

### data
python3 scripts/init_social_graph.py --graph socfb-Reed98 --compose --ip 127.0.0.1 --port 8080
echo "✅ data primed"

echo "workload ..."
wrk -t2 -c32 -d30s -R300 \
  -s wrk2/scripts/social-network/mixed-workload.lua \
  http://localhost:8080/index.html

sleep 60
echo "graph ..."

ts=$(($(date +%s%N)/1000000))
curl -s "http://localhost:16686/api/dependencies?endTs=$ts&lookback=3600000" \
     -o deps.json
python3 resilience.py deps.json -o results/R_avg_repl.json
jq -n '{"stage":"steady_repl"}' > results/04_meta.json
echo "✅ steady_repl done"
