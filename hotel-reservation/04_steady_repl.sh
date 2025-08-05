#!/usr/bin/env bash

# configurable output directory, RNG seed and failure probability
OUTDIR=${OUTDIR:-results/hotel-repl}
SEED=${SEED:-16}
P_FAIL=${P_FAIL:-0.30}

echo "hotel-reservation steady state (with replication) ..."
set -euo pipefail; cd DeathStarBench/hotelReservation
mkdir -p "$OUTDIR"

### Deploy to Kubernetes with replication
echo "deploying to kubernetes with replication ..."
kubectl apply -Rf kubernetes/ > /dev/null 2>&1

# Scale up critical services for replication
kubectl scale deployment/frontend --replicas=3
kubectl scale deployment/search --replicas=3
kubectl scale deployment/geo --replicas=3
kubectl scale deployment/profile --replicas=3
kubectl scale deployment/rate --replicas=3
kubectl scale deployment/recommendation --replicas=3
kubectl scale deployment/reservation --replicas=3
kubectl scale deployment/user --replicas=3

### Wait for pods to be ready
echo "waiting for pods to be ready ..."
kubectl wait --for=condition=ready pod --all --timeout=300s

### Get frontend service URL
echo "getting frontend service URL ..."
FRONTEND_URL=$(minikube service frontend --url 2>/dev/null)
if [[ -z "$FRONTEND_URL" || "$FRONTEND_URL" == *"😿"* ]]; then
  echo "⚠️  Failed to get frontend URL from minikube service, trying alternative..."
  MINIKUBE_IP=$(minikube ip)
  FRONTEND_URL="http://${MINIKUBE_IP}:30000"
fi
echo "Frontend available at: $FRONTEND_URL"

# Wait a bit for services to be fully ready
echo "waiting for services to be ready ..."
sleep 10

# Test if frontend is reachable
echo "testing frontend connectivity ..."
if ! curl -f "$FRONTEND_URL" >/dev/null 2>&1; then
  echo "⚠️  Frontend not reachable at $FRONTEND_URL, continuing anyway..."
else
  echo "✅ Frontend is reachable"
fi

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
  -o "$OUTDIR/R_avg_repl.json" \
  --repl 1 \
  --seed "$SEED" \
  --p_fail "$P_FAIL"

echo "✅ hotel-reservation steady_repl done"
