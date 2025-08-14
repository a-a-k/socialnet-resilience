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

# Specifically wait for frontend pod
echo "⏳ Waiting for frontend pod to be ready ..."
kubectl wait --for=condition=available deployment/frontend --timeout=120s || {
  echo "❌ Frontend deployment not available"
  kubectl get deployment frontend
  kubectl get pods -l io.kompose.service=frontend
  exit 1
}

# Wait a bit for the application to start
echo "⏳ Waiting for frontend application to start ..."
sleep 10

### 🔄 Dynamically set up port forwarding for all deployed services
echo "🔌 Setting up port forwarding for all services ..."

# Declare associative arrays to track process IDs and local URLs
declare -A SERVICE_PIDS
declare -A SERVICE_URLS

# Kill any lingering kubectl port-forwards from previous runs
pkill -f "kubectl.*port-forward" || true
sleep 2

# Define service port mappings to avoid conflicts
declare -A service_ports=(
  # Main application services
  ["frontend"]="5000"
  ["search"]="8082" 
  ["geo"]="8083"
  ["profile"]="8081"
  ["rate"]="8084"
  ["recommendation"]="8085"
  ["reservation"]="8087"
  ["user"]="8086"
  # Supporting services
  ["consul"]="8500"
  ["jaeger"]="16686"
  # Database services (using different ports to avoid conflicts)
  ["mongodb-geo"]="27017"
  ["mongodb-profile"]="27018"
  ["mongodb-rate"]="27019"
  ["mongodb-recommendation"]="27020"
  ["mongodb-reservation"]="27021"
  ["mongodb-user"]="27022"
  # Cache services
  ["memcached-profile"]="11211"
  ["memcached-rate"]="11212"
  ["memcached-reserve"]="11213"
)

# Start port forwarding for each service
for service in "${!service_ports[@]}"; do
  port="${service_ports[$service]}"
  
  # Check if service exists
  if kubectl get svc "$service" >/dev/null 2>&1; then
    echo "🔁 Port-forwarding service/$service:$port ➜ localhost:$port ..."
    kubectl port-forward "service/$service" "$port:$port" > /dev/null 2>&1 &
    pid=$!
    SERVICE_PIDS["$service"]=$pid
    SERVICE_URLS["$service"]="http://localhost:$port"
  else
    echo "⚠️  Service $service not found, skipping"
  fi
done

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

echo "⏳ Waiting for port forwarding to be ready ..."
sleep 5  # Give port forwarding time to establish

# Wait for frontend to be accessible (using correct URL)
timeout 60 bash -c "until curl -fsSL http://localhost:5000/ > /dev/null 2>&1; do sleep 2; done" || {
  echo "❌ Frontend service not reachable after 60 seconds"
  echo "🔍 Debugging info:"
  echo "Port forwarding processes:"
  ps aux | grep "kubectl.*port-forward" || echo "No port-forward processes found"
  echo "Network connections:"
  netstat -tlnp | grep :5000 || echo "No connections on port 5000"
  echo "Service status:"
  kubectl get svc frontend
  echo "Pod status:"
  kubectl get pod -l io.kompose.service=frontend || kubectl get pod | grep frontend
  exit 1
}
echo "✅ Frontend service is ready!"


echo "🚀 Running workload ..."
wrk2 -t2 -c32 -d30s -R300 \
  -s wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua \
  http://localhost:5000/


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