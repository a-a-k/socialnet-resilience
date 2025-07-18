#!/usr/bin/env bash

# configurable output directory, RNG seed and failure probability
OUTDIR=${OUTDIR:-results/hotel-norepl}
SEED=${SEED:-16}
P_FAIL=${P_FAIL:-0.30}

echo "hotel-reservation steady state (no replication) ..."
set -euo pipefail; cd DeathStarBench/hotelReservation
mkdir -p "$OUTDIR"

### Deploy to Kubernetes
echo "deploying to kubernetes ..."
kubectl apply -Rf kubernetes/ > /dev/null 2>&1

### Wait for pods to be ready
echo "waiting for pods to be ready ..."
kubectl wait --for=condition=ready pod --all --timeout=300s

### Get frontend service URL
FRONTEND_URL=$(minikube service frontend --url)
echo "Frontend available at: $FRONTEND_URL"

### Initialize hotel data
echo "initializing hotel data ..."
python3 scripts/init_hotel_db.py

echo "✅ data primed"

echo "workload ..."
# Run workload against hotel reservation service
wrk -t2 -c32 -d30s -R300 \
  -s wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua \
  $FRONTEND_URL

sleep 15
echo "graph ..."

# Jaeger deps & theoretical R_avg
ts=$(($(date +%s%N)/1000000))
curl -s "http://localhost:16686/api/dependencies?endTs=$ts&lookback=3600000" \
     -o deps.json

python3 hotel-resilience.py deps.json \
  -o "$OUTDIR/R_avg_base.json" \
  --seed "$SEED" \
  --p_fail "$P_FAIL"

echo "✅ hotel-reservation steady_norepl done"
