#!/usr/bin/env bash

# configurable output directory, RNG seed and failure probability
OUTDIR=${OUTDIR:-results/norepl}
SEED=${SEED:-16}
P_FAIL=${P_FAIL:-0.30}


set -euo pipefail; cd DeathStarBench/hotelReservation
mkdir -p "$OUTDIR"

# Apply all Kubernetes manifests
echo "📦 Deploying Kubernetes manifests ..."
kubectl apply -Rf kubernetes/

# Wait for all pods to become ready
echo "⏳ Waiting for all pods to become ready ..."
kubectl wait --for=condition=ready pod --all --timeout=300s

### 🔄 Dynamically set up port forwarding for all deployed services
echo "🔌 Setting up port forwarding for all services ..."

# Declare associative arrays to track process IDs and local URLs
declare -A SERVICE_PIDS
declare -A SERVICE_URLS

# Kill any lingering kubectl port-forwards from previous runs
pkill -f "kubectl.*port-forward" || true
sleep 2

# Get all non-system services and their ports
services=$(kubectl get svc -o json | jq -r '
  .items[]
  | select(.metadata.namespace != "kube-system")
  | . as $svc
  | $svc.spec.ports[]
  | [$svc.metadata.name, .port] | @tsv
')

# Start port forwarding each service
while IFS=$'\t' read -r svc port; do
  echo "🔁 Port-forwarding service/$svc:$port ➜ localhost:$port ..."
  
  # Run kubectl port-forward in background
  kubectl port-forward "service/$svc" "${port}:${port}" > /dev/null 2>&1 &
  pid=$!
  
  SERVICE_PIDS["$svc"]=$pid
  SERVICE_URLS["$svc"]="http://localhost:${port}"
done <<< "$services"

# Cleanup on exit
cleanup_port_forward() {
  echo "🧹 Cleaning up port forwards ..."
  for pid in "${SERVICE_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  pkill -f "kubectl.*port-forward" || true
}
# trap cleanup_port_forward EXIT

# Show access URLs
echo ""
echo "🎯 Port-forwarded services:"
for svc in "${!SERVICE_URLS[@]}"; do
  echo "✅ $svc: ${SERVICE_URLS[$svc]}"
done
echo ""

echo "workload ..."
wrk -t2 -c32 -d30s -R300 \
  -s wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua \
  http://localhost:5000/index.html


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

echo "✅ steady_norepl done"