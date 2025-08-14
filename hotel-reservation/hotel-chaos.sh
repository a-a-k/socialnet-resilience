#!/usr/bin/env bash
# -------------------------------------------------------------------
# hotel-chaos.sh — chaos-engineering driver for hotel-reservation
# -------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/DeathStarBench/hotelReservation"

# ─── Tunables ──────────────────────────────────────────────────────────────
ROUNDS=${ROUNDS:-450}
FAIL_FRACTION=${FAIL_FRACTION:-0.30}
SEED=${SEED:-16}
RATE=${RATE:-300}
DURATION=${DURATION:-30}
THREADS=${THREADS:-2}
CONNS=${CONNS:-32}
FRONTEND_PORT=${FRONTEND_PORT:-5000}
URL="http://localhost:${FRONTEND_PORT}/"
LUA=${LUA:-wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua}
MODE="norepl"

# Verify we have the necessary files
if [[ ! -d "kubernetes" ]]; then
  echo "❌ Error: kubernetes/ directory not found. Are you in the right location?"
  exit 1
fi

if [[ ! -f "$LUA" ]]; then
  echo "❌ Error: Lua script not found at $LUA"
  exit 1
fi

# number of replicas for the "replicated" scenario
if [[ ${1:-} == "--repl" || ${1:-} == "-r" ]]; then
  MODE="repl"
  shift
fi

OUTDIR=${OUTDIR:-results/hotel-${MODE}-chaos}
mkdir -p "$OUTDIR"

  declare -A SERVICE_PIDS
  declare -A SERVICE_URLS

# ─── Helper: cleanup port forwarding ──────────────────────────────────────
cleanup_port_forwards() {
  echo "🧹 Cleaning up port forwards ..."
  for pid in "${SERVICE_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  pkill -f "kubectl.*port-forward" || true
  # Clear the arrays
  SERVICE_PIDS=()
  SERVICE_URLS=()
}

# ─── Helper: setup port forwarding for running services ───────────────────
setup_port_forwarding() {
  local killed_services_file="$1"
  local killed_services=()
  
  # Read killed services from file if it exists
  if [[ -f "$killed_services_file" ]]; then
    mapfile -t killed_services < "$killed_services_file"
  fi
  
  echo "🔌 Setting up port forwarding for running services ..."
  
  # Kill any lingering kubectl port-forwards
  pkill -f "kubectl.*port-forward" || true
  sleep 2

  # Service port mappings - including all services that might be needed
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

  # Forward ports for running services only
  for service in "${!service_ports[@]}"; do
    local port="${service_ports[$service]}"
    
    # Skip if service is killed (only applies to main application services)
    if [[ " ${killed_services[*]} " =~ " ${service} " ]]; then
      echo "💀 Skipping port forward for killed service: $service"
      continue
    fi
    
    # Check if service exists and has pods running
    if kubectl get svc "$service" >/dev/null 2>&1; then
      # For deployment-based services, check replicas
      if kubectl get deployment "$service" >/dev/null 2>&1; then
        local replicas=$(kubectl get deployment "$service" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        if [[ "$replicas" -gt 0 ]]; then
          echo "🔁 Port-forwarding service/$service:$port ➜ localhost:$port ..."
          kubectl port-forward "service/$service" "$port:$port" > /dev/null 2>&1 &
          local pid=$!
          SERVICE_PIDS["$service"]=$pid
          SERVICE_URLS["$service"]="http://localhost:$port"
        else
          echo "💀 Service $service has 0 replicas, skipping port forward"
        fi
      else
        # For non-deployment services (like some system services), just try to forward
        echo "🔁 Port-forwarding service/$service:$port ➜ localhost:$port ..."
        kubectl port-forward "service/$service" "$port:$port" > /dev/null 2>&1 &
        local pid=$!
        SERVICE_PIDS["$service"]=$pid
        SERVICE_URLS["$service"]="http://localhost:$port"
      fi
    else
      echo "⚠️  Service $service not found, skipping port forward"
    fi
  done

  echo "🎯 Port-forwarded services (${#SERVICE_URLS[@]} total):"
  for service in "${!SERVICE_URLS[@]}"; do
    echo "✅ $service: ${SERVICE_URLS[$service]}"
  done
  
  if [[ ${#SERVICE_URLS[@]} -eq 0 ]]; then
    echo "⚠️  No services are being port-forwarded!"
  fi
}

# ─── Helper: wait until the frontend is reachable ─────────────────────────
wait_ready() {
  echo "⏳ Waiting for frontend to be ready at $URL..."
  timeout 30 bash -c \
    'until curl -fsSL '"$URL"' >/dev/null 2>&1; do sleep 1; done' || {
    echo "⚠️  WARNING: Frontend not reachable at $URL after 30s timeout"
    return 1
  }
  echo "✅ Frontend is ready!"
}

# ─── Helper: run wrk and return total errors ──────────────────────────────
run_wrk() {
  local logfile="$1"
  local expected_total=$((RATE * DURATION))
  local total errors

  # Use wrk2 for rate-limited load testing
  wrk2 -t"$THREADS" -c"$CONNS" -d"${DURATION}s" -R"$RATE" \
      -s "$LUA" "$URL" >"$logfile" 2>&1 || true

  if grep -q 'requests in' "$logfile"; then
    total=$(grep -Eo '[0-9]+ requests in' "$logfile" | awk '{print $1}')
  else
    total=$expected_total
    errors=$total
    echo "$total $errors"
    return
  fi
  
  # Parse errors from Status Code Summary section
  errors=0
  
  # Try to get the Status 5xx line
  if grep -qE "Status 5xx:[[:space:]]+" "$logfile"; then
    errors=$(grep -E "Status 5xx:[[:space:]]+[0-9]+" "$logfile" | awk '{print $NF}')
  fi
  
  # Make sure both values are numeric
  if [[ ! "$total" =~ ^[0-9]+$ ]]; then
    echo "[run_wrk] WARNING: Invalid total value '$total', using expected: $expected_total" >&2
    total=$expected_total
  fi
  
  if [[ ! "$errors" =~ ^[0-9]+$ ]]; then
    echo "[run_wrk] WARNING: Invalid errors value '$errors', using 0" >&2
    errors=0
  fi

  # Add socket errors if any
  local sock_errors=$(grep -Eo 'Socket errors:[^ ]+[[:space:]]*[0-9]+' "$logfile" | grep -Eo '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo 0)
  errors=$((errors + sock_errors))

  echo "$total $errors"
}

# ─── Helper: determine which services to kill and return list ─────────────
determine_victims() {
  local fraction="$1" ; local round="$2"
  
  # All available services
  local all_services=("frontend" "search" "geo" "profile" "rate" "recommendation" "reservation" "user")
  local total=${#all_services[@]}

  # Deterministic sample via python (respects SEED)
  python3 - "$fraction" "$SEED" "$round" "${all_services[@]}" <<'PY'
import sys, random, math
frac = float(sys.argv[1])
seed = int(sys.argv[2]) + int(sys.argv[3])      # base-seed + round
services = sys.argv[4:]                         # remaining argv[]
random.seed(seed)
kill_n = max(1, math.ceil(len(services) * frac))
kill_n = min(kill_n, len(services))  # don't exceed available services
if services:
    print('\n'.join(random.sample(services, k=kill_n)))
PY
}

# ─── Helper: deploy only healthy services (excluding killed ones) ─────────
deploy_healthy_services() {
  local killed_services_file="$1"
  local killed_services=()
  
  # Read killed services from file if it exists
  if [[ -f "$killed_services_file" ]]; then
    mapfile -t killed_services < "$killed_services_file"
  fi
  
  echo "🚀 Deploying Kubernetes stack (excluding killed services)..."
  
  # Deploy all services first
  kubectl apply -Rf kubernetes/ > /dev/null 2>&1
  
  # Scale down killed services to 0 replicas
  for service in "${killed_services[@]}"; do
    if [[ -n "$service" ]]; then
      echo "💀 Scaling down killed service: $service"
      kubectl scale deployment/"$service" --replicas=0 > /dev/null 2>&1 || true
    fi
  done

  if [[ "$MODE" == "repl" ]]; then
    echo "📈 Scaling healthy services for replication..."
    local all_services=("frontend" "search" "geo" "profile" "rate" "recommendation" "reservation" "user")
    for service in "${all_services[@]}"; do
      # Only scale up if not in killed list
      if [[ ! " ${killed_services[*]} " =~ " ${service} " ]]; then
        kubectl scale deployment/"$service" --replicas=3 > /dev/null 2>&1 || true
      fi
    done
  fi

  echo "⏳ Waiting for healthy pods to be ready..."
  # Wait for all healthy deployments to have ready pods
  local all_services=("frontend" "search" "geo" "profile" "rate" "recommendation" "reservation" "user")
  for service in "${all_services[@]}"; do
    # Skip if service is killed
    if [[ " ${killed_services[*]} " =~ " ${service} " ]]; then
      continue
    fi
    
    echo "⏳ Waiting for $service pods to be ready..."
    kubectl wait --for=condition=available deployment/"$service" --timeout=120s || {
      echo "⚠️  Deployment $service not ready within timeout"
      kubectl get deployment "$service"
      kubectl get pods -l io.kompose.service="$service"
    }
  done
}

# ─── Helper: cleanup and restart stack with new chaos ─────────────────────
restart_stack_with_chaos() {
  local round="$1"
  
  echo "🔄 Restarting Kubernetes stack for round $round..."
  cleanup_port_forwards
  kubectl delete -Rf kubernetes/ > /dev/null 2>&1 || true
  
  # Wait for pods to be fully terminated
  echo "⏳ Waiting for pods to terminate..."
  timeout 120 bash -c 'while kubectl get pods --no-headers 2>/dev/null | grep -qE "(frontend|search|geo|profile|rate|recommendation|reservation|user)"; do sleep 2; done' || {
    echo "⚠️  Some pods still exist after timeout, continuing anyway..."
    kubectl get pods | grep -E "(frontend|search|geo|profile|rate|recommendation|reservation|user)" || echo "No application pods found"
  }
  
  sleep 5
  
  # Determine which services to kill for this round
  echo "[Round $round] Determining services to kill..."
  killed_services_file="$OUTDIR/killed_services_${round}.txt"
  determine_victims "$FAIL_FRACTION" "$round" > "$killed_services_file"
  
  killed_count=$(wc -l < "$killed_services_file" 2>/dev/null || echo 0)
  if [[ $killed_count -gt 0 ]]; then
    echo "[Round $round] Services to be killed:"
    cat "$killed_services_file" | sed 's/^/  💀 /'
  else
    echo "[Round $round] No services to kill"
  fi
  
  # Deploy only healthy services
  deploy_healthy_services "$killed_services_file"
  
  # Additional check for frontend specifically (if not killed)
  if ! grep -q "frontend" "$killed_services_file" 2>/dev/null; then
    echo "⏳ Double-checking frontend is ready..."
    kubectl wait --for=condition=available deployment/frontend --timeout=60s || {
      echo "❌ Frontend deployment not available"
      kubectl get deployment frontend
      kubectl get pods -l io.kompose.service=frontend
      return 1
    }
    
    # Wait a bit more for the application inside the pod to start
    echo "⏳ Waiting for frontend application to start..."
    sleep 10
  fi
  
  # Setup port forwarding for running services
  setup_port_forwarding "$killed_services_file"
  
  echo "⏳ Waiting for port forwarding to be ready ..."
  sleep 5
  
  # Test frontend connectivity (if not killed)
  if ! grep -q "frontend" "$killed_services_file" 2>/dev/null; then
    echo "🔍 Testing frontend connectivity..."
    echo "🔍 Port forwarding processes:"
    ps aux | grep "kubectl.*port-forward" | grep -v grep || echo "No port-forward processes found"
    echo "🔍 Network connections on port 5000:"
    netstat -tlnp | grep :5000 || echo "No connections on port 5000"
    
    # First check if the pod is actually ready
    echo "🔍 Checking frontend pod readiness..."
    kubectl get pods -l io.kompose.service=frontend -o wide
    
    # Check frontend pod logs for any startup issues
    echo "🔍 Frontend pod logs (last 20 lines):"
    kubectl logs -l io.kompose.service=frontend --tail=20 || echo "Could not get logs"
    
    # Test direct connection to the pod first
    local frontend_pod=$(kubectl get pods -l io.kompose.service=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$frontend_pod" ]]; then
      echo "🔍 Testing direct connection to pod $frontend_pod..."
      kubectl exec "$frontend_pod" -- curl -f http://localhost:5000 > /dev/null 2>&1 && {
        echo "✅ Pod responds directly, issue might be with port forwarding"
      } || {
        echo "❌ Pod doesn't respond directly, application might not be ready"
      }
    fi
    
    # Test the actual URL with redirect following
    echo "🔍 Testing frontend URL with redirects..."
    timeout 30 bash -c "until curl -fsSL http://localhost:5000/ >/dev/null 2>&1; do sleep 2; done" || {
      echo "❌ Frontend service not reachable after extended testing"
      echo "🔍 Final debugging info:"
      echo "Service status:"
      kubectl get svc frontend -o wide
      echo "Endpoints:"
      kubectl get endpoints frontend
      return 1
    }
    echo "✅ Frontend service is ready!"
  else
    echo "💀 Frontend service is killed for this round"
  fi
}

# ─── Cleanup on exit ───────────────────────────────────────────────────────
trap cleanup_port_forwards EXIT

echo "=== Hotel Reservation Chaos Test ($ROUNDS rounds, fail=$FAIL_FRACTION, seed=$SEED, mode=$MODE) ==="

rounds=0
total_sum=0
error_sum=0

for round in $(seq 1 "$ROUNDS"); do
  echo "-- round $round/$ROUNDS --"
  
  # Deploy stack with chaos for this round
  if ! restart_stack_with_chaos "$round"; then
    echo "[Round $round] ERROR: Failed to deploy stack with chaos"
    exit 1
  fi
  
  # Check if frontend is available for testing
  killed_services_file="$OUTDIR/killed_services_${round}.txt"
  if grep -q "frontend" "$killed_services_file" 2>/dev/null; then
    echo "[Round $round] Frontend is killed - all requests will fail"
    # Still run the test to measure the failure
    total=$((RATE * DURATION))
    errors=$total
  else
    echo "[Round $round] waiting for stack to be healthy..."
    if ! wait_ready; then
      echo "[Round $round] Frontend not ready, treating as all errors"
      total=$((RATE * DURATION))
      errors=$total
    else
      echo "[Round $round] stack is healthy."
      
      echo "[Round $round] applying workload..."
      logfile="$OUTDIR/wrk_${round}.log"
      read total errors <<< "$(run_wrk "$logfile")"
      if [[ $? -eq 0 ]]; then
          if [[ "$total" =~ ^[0-9]+$ ]] && [[ "$errors" =~ ^[0-9]+$ ]]; then
              echo "[Round $round] workload applied. Total: $total, Errors: $errors"
              echo "[Round $round] Status code summary:"
              grep '^Status ' "$logfile" | sort || true
              echo "[Round $round] Socket errors:"
              if grep -q 'Socket errors:' "$logfile"; then
                grep 'Socket errors:' "$logfile"
              else
                echo "  None (good!)"
              fi
          else
              echo "[Round $round] ERROR: run_wrk did not return valid numbers: total='$total', errors='$errors'"
              echo "[Round $round] --- wrk log tail ---"
              tail -40 "$logfile"
              echo "[Round $round] --- end wrk log ---"
              total=$((RATE * DURATION))
              errors=$total
          fi
      else
          echo "[Round $round] ERROR: run_wrk failed"
          echo "[Round $round] --- wrk log tail ---"
          tail -40 "$logfile"
          echo "[Round $round] --- end wrk log ---"
          total=$((RATE * DURATION))
          errors=$total
      fi
    fi
  fi

  echo "counting..."
  ((rounds++))  || true
  ((total_sum+=total))  || true
  ((error_sum+=errors))  || true

  if [ "$round" -eq 47 ]; then
      echo "[Round $round] Capturing logs from all pods..."
      kubectl logs --all-containers=true --prefix=true --tail=1000 \
        -l 'io.kompose.service in (frontend,search,geo,profile,rate,recommendation,reservation,user)' \
        > "$OUTDIR/k8s_logs_round_${round}.txt" 2>/dev/null || true
  fi
done

echo "done, aggregating results..."

# ─── Aggregate R_live ─────────────────────────────────────────────────────
python3 - <<'PY' "$rounds" "$error_sum" "$total_sum" "$OUTDIR/summary.json" "$MODE"
import json, sys
r, err, tot, path, mode = list(map(int, sys.argv[1:4])) + sys.argv[4:6]
R = 0.0 if tot == 0 else 1.0 - err / tot
result = {
    "rounds": r, 
    "R_live": round(R, 5),
    "total_requests": tot,
    "total_errors": err,
    "application": "hotel-reservation",
    "mode": mode
}
json.dump(result, open(path, "w"), indent=2)
print(f"*** Mean R_live over {r} rounds: {R:.4f}")
PY

echo "done. Results written to $OUTDIR/summary.json"
exit 0