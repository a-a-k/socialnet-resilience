#!/usr/bin/env bash
set -euo pipefail; cd DeathStarBench/socialNetwork
docker compose -f docker-compose.yml up -d \
  --scale compose-post-service=3 \
  --scale home-timeline-service=3 \
  --scale user-timeline-service=3 \
  --scale text-service=3 \
  --scale media-service=3

wrk -t2 -c32 -d30s -R300 \
  -s scripts/social-network/mixed-workload.lua \
  http://localhost:8080/index.html >/dev/null

ts=$(($(date +%s%N)/1000000))
curl -s "http://localhost:16686/api/dependencies?endTs=$ts&lookback=3600000" \
     -o deps.json
python3 resilience.py deps.json -o results/R_avg_repl.json
jq -n '{"stage":"steady_repl"}' > results/04_meta.json
echo "✅ steady_repl done"
