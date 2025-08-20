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

# Wait for the application to start and be ready
echo "⏳ Waiting for frontend application to start ..."

# Check if frontend pod is actually ready (not just running)
echo "🔍 Checking frontend pod readiness..."
timeout 120 bash -c '
  while true; do
    pod_status=$(kubectl get pods -l io.kompose.service=frontend -o jsonpath="{.items[0].status.phase}" 2>/dev/null)
    ready_status=$(kubectl get pods -l io.kompose.service=frontend -o jsonpath="{.items[0].status.conditions[?(@.type==\"Ready\")].status}" 2>/dev/null)
    
    if [[ "$pod_status" == "Running" && "$ready_status" == "True" ]]; then
      echo "✅ Frontend pod is ready"
      break
    fi
    
    echo "⏳ Frontend pod status: $pod_status, ready: $ready_status"
    sleep 5
  done
' || {
  echo "❌ Frontend pod not ready after timeout"
  kubectl describe pod -l io.kompose.service=frontend
  exit 1
}

# Additional wait for application startup
sleep 15

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
  
  # Check if service exists and has endpoints
  if kubectl get svc "$service" >/dev/null 2>&1; then
    # For deployment-based services, ensure they have running pods
    if kubectl get deployment "$service" >/dev/null 2>&1; then
      # Wait for deployment to be ready
      kubectl wait --for=condition=available deployment/"$service" --timeout=60s || {
        echo "⚠️  Deployment $service not ready, skipping port forward"
        continue
      }
    fi
    
    echo "🔁 Port-forwarding service/$service:$port ➜ localhost:$port ..."
    kubectl port-forward "service/$service" "$port:$port" > /dev/null 2>&1 &
    pid=$!
    SERVICE_PIDS["$service"]=$pid
    SERVICE_URLS["$service"]="http://localhost:$port"
    
    # Special handling for frontend - verify it starts properly
    if [[ "$service" == "frontend" ]]; then
      sleep 5
      if ! ps -p $pid > /dev/null 2>&1; then
        echo "⚠️  Frontend port forwarding failed, retrying..."
        # Try port forwarding to pod directly instead of service
        frontend_pod=$(kubectl get pods -l io.kompose.service=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$frontend_pod" ]]; then
          echo "🔄 Trying direct pod port forwarding for $frontend_pod..."
          kubectl port-forward "pod/$frontend_pod" "$port:$port" > /dev/null 2>&1 &
          pid=$!
          SERVICE_PIDS["$service"]=$pid
        else
          echo "🔄 Retrying service port forwarding..."
          kubectl port-forward "service/$service" "$port:$port" > /dev/null 2>&1 &
          pid=$!
          SERVICE_PIDS["$service"]=$pid
        fi
      fi
    fi
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
sleep 10  # Give port forwarding more time to establish

# Verify critical port forwards are working
echo "🔍 Verifying port forwarding status..."
for critical_service in "frontend" "consul"; do
  if [[ -n "${SERVICE_PIDS[$critical_service]:-}" ]]; then
    pid="${SERVICE_PIDS[$critical_service]}"
    if ps -p $pid > /dev/null 2>&1; then
      echo "✅ $critical_service port forwarding is running (PID: $pid)"
    else
      echo "❌ $critical_service port forwarding failed, restarting..."
      port="${service_ports[$critical_service]}"
      kubectl port-forward "service/$critical_service" "$port:$port" > /dev/null 2>&1 &
      SERVICE_PIDS["$critical_service"]=$!
      sleep 3
    fi
  fi
done

# Wait for frontend to be accessible (using correct URL)
echo "🔍 Testing frontend connectivity..."

# First check if frontend port forwarding is actually running
if ! ps aux | grep -q "kubectl.*port-forward.*frontend"; then
  echo "⚠️  Frontend port forwarding not found, restarting..."
  pkill -f "kubectl.*port-forward.*frontend" || true
  sleep 2
  kubectl port-forward "service/frontend" "5000:5000" > /dev/null 2>&1 &
  SERVICE_PIDS["frontend"]=$!
  sleep 5
fi

# Check if port is actually listening
if ! netstat -tlnp | grep -q :5000; then
  echo "⚠️  Port 5000 not listening, debugging..."
  echo "🔍 Port forwarding processes:"
  ps aux | grep "kubectl.*port-forward" | grep -v grep || echo "No port-forward processes found"
  echo "🔍 Restarting frontend port forward..."
  pkill -f "kubectl.*port-forward.*frontend" || true
  sleep 2
  kubectl port-forward "service/frontend" "5000:5000" > /dev/null 2>&1 &
  SERVICE_PIDS["frontend"]=$!
  sleep 10
fi

# Test direct pod connectivity first
frontend_pod=$(kubectl get pods -l io.kompose.service=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$frontend_pod" ]]; then
  echo "🔍 Testing direct connection to pod $frontend_pod..."
  
  # Check if the application is listening on port 5000 inside the pod
  echo "🔍 Checking if frontend app is listening on port 5000..."
  kubectl exec "$frontend_pod" -- netstat -tlnp | grep :5000 || {
    echo "⚠️  Frontend app not listening on port 5000 yet, waiting..."
    sleep 10
    kubectl exec "$frontend_pod" -- netstat -tlnp | grep :5000 || {
      echo "❌ Frontend app still not listening, checking logs..."
      kubectl logs "$frontend_pod" --tail=30 || true
    }
  }
  
  # Test HTTP connectivity inside the pod
  timeout 15 kubectl exec "$frontend_pod" -- curl -f http://localhost:5000/ >/dev/null 2>&1 || {
    echo "❌ Pod doesn't respond to HTTP requests, checking logs..."
    kubectl logs "$frontend_pod" --tail=30 || true
    echo "🔍 Pod process status:"
    kubectl exec "$frontend_pod" -- ps aux || true
  }
fi

# Now test through port forwarding with extended timeout and better error handling
echo "🔍 Testing frontend through port forwarding..."

# Try multiple approaches to establish connectivity
max_attempts=3
attempt=1
frontend_ready=false

while [[ $attempt -le $max_attempts ]] && [[ "$frontend_ready" == "false" ]]; do
  echo "🔄 Frontend connectivity attempt $attempt/$max_attempts"
  
  # Test current port forwarding
  timeout 30 bash -c "until curl -fsSL http://localhost:5000/ > /dev/null 2>&1; do sleep 2; done" && {
    frontend_ready=true
    echo "✅ Frontend is accessible!"
    break
  }
  
  if [[ $attempt -lt $max_attempts ]]; then
    echo "⚠️  Attempt $attempt failed, trying recovery..."
    
    # Kill existing frontend port forward
    pkill -f "kubectl.*port-forward.*frontend" || true
    sleep 2
    
    # Try different port forwarding approaches
    if [[ $attempt -eq 1 ]]; then
      echo "🔄 Retrying service port forwarding..."
      kubectl port-forward "service/frontend" "5000:5000" > /dev/null 2>&1 &
      SERVICE_PIDS["frontend"]=$!
    elif [[ $attempt -eq 2 ]]; then
      echo "🔄 Trying direct pod port forwarding..."
      frontend_pod=$(kubectl get pods -l io.kompose.service=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
      if [[ -n "$frontend_pod" ]]; then
        kubectl port-forward "pod/$frontend_pod" "5000:5000" > /dev/null 2>&1 &
        SERVICE_PIDS["frontend"]=$!
      fi
    fi
    
    sleep 10
  fi
  
  ((attempt++))
done

if [[ "$frontend_ready" == "false" ]]; then
  echo "❌ Frontend service not reachable after $max_attempts attempts"
  echo "🔍 Final debugging info:"
  echo "Port forwarding processes:"
  ps aux | grep "kubectl.*port-forward" | grep -v grep || echo "No port-forward processes found"
  echo "Network connections:"
  netstat -tlnp | grep :5000 || echo "No connections on port 5000"
  echo "Service status:"
  kubectl get svc frontend
  echo "Endpoints:"
  kubectl get endpoints frontend
  echo "Pod status:"
  kubectl get pod -l io.kompose.service=frontend
  echo "Pod logs:"
  kubectl logs -l io.kompose.service=frontend --tail=50 || true
  echo "🔍 Testing basic connectivity:"
  curl -v http://localhost:5000/ || true
  exit 1
fi
echo "✅ Frontend service is ready!"


echo "🚀 Running workload ..."
wrk -t2 -c32 -d30s -R300 \
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