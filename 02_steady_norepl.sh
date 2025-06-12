#!/usr/bin/env bash

# configurable output directory, RNG seed and failure probability
OUTDIR=${OUTDIR:-results/norepl}
SEED=${SEED:-16}
P_FAIL=${P_FAIL:-0.30}

echo "compose ..."
set -euo pipefail; cd DeathStarBench/socialNetwork
mkdir -p "$OUTDIR"

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

python3 resilience.py deps.json \
  -o "$OUTDIR/R_avg_base.json" \
  --seed "$SEED" \
  --p_fail "$P_FAIL"

echo "✅ steady_norepl done"
