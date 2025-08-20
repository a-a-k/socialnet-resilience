#!/usr/bin/env bash
# -------------------------------------------------------------------
# hotel-chaos-simple.sh — simplified chaos-engineering for hotel-reservation
# Based on the original chaos.sh pattern but adapted for Kubernetes
# -------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/DeathStarBench/hotelReservation"

# ─── Tunables ──────────────────────────────────────────────────────────────
ROUNDS=${ROUNDS:-450}
FAIL_FRACTION=${FAIL_FRACTION:-0.20}
SEED=${SEED:-16}
RATE=${RATE:-200}
DURATION=${DURATION:-30}
THREADS=${THREADS:-2}
CONNS=${CONNS:-32}
FRONTEND_PORT=${FRONTEND_PORT:-5000}
URL="http://localhost:${FRONTEND_PORT}/"
LUA=${LUA:-wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua}
MODE="norepl"

# Replicated mode
if [[ ${1:-} == "--repl" || ${1:-} == "-r" ]]; then
  MODE="repl"
  shift
fi

OUTDIR=${OUTDIR:-results/hotel-${MODE}-chaos}
mkdir -p "$OUTDIR"

# ─── Helper: cleanup ───────────────────────────────────────────────────────
cleanup() {
  echo "🧹 Cleaning up..."
  pkill -f "kubectl.*port-forward" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Helper: wait until frontend is ready ─────────────────────────────────
wait_ready() {
  echo "⏳ Waiting for frontend to be ready..."
  
  # Wait for frontend pod to be running
  echo "⏳ Waiting for frontend pod..."
  timeout 180 bash -c 'until kubectl get pods -l io.kompose.service=frontend --no-headers 2>/dev/null | grep -q "1/1.*Running"; do sleep 3; done' || {
    echo "❌ Frontend pod not ready after timeout"
    kubectl get pods -l io.kompose.service=frontend 2>/dev/null || echo "No frontend pods found"
    return 1
  }
  
  # Give the application time to start inside the pod
  echo "⏳ Allowing application startup time..."
  sleep 20
  
  # Setup port forwarding with better error handling
  echo "🔌 Setting up port forwarding..."
  pkill -f "kubectl.*port-forward.*frontend" 2>/dev/null || true
  sleep 2
  
  # Start port forwarding in background
  kubectl port-forward service/frontend ${FRONTEND_PORT}:5000 >/dev/null 2>&1 &
  local pf_pid=$!
  sleep 5
  
  # Verify port forwarding is working
  if ! kill -0 $pf_pid 2>/dev/null; then
    echo "❌ Port forwarding process died, trying pod direct forwarding..."
    local frontend_pod=$(kubectl get pods -l io.kompose.service=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$frontend_pod" ]]; then
      kubectl port-forward pod/$frontend_pod ${FRONTEND_PORT}:5000 >/dev/null 2>&1 &
      sleep 5
    else
      echo "❌ No frontend pod found for direct forwarding"
      return 1
    fi
  fi
  
  # Wait for port to be available
  echo "⏳ Waiting for port to be available..."
  timeout 30 bash -c 'until (echo >/dev/tcp/localhost/'"$FRONTEND_PORT"') 2>/dev/null; do sleep 1; done' || {
    echo "❌ Port $FRONTEND_PORT not accessible"
    echo "🔍 Checking port forwarding status..."
    ps aux | grep "port-forward" | grep -v grep || echo "No port-forward processes running"
    return 1
  }
  
  # Test HTTP connectivity with retries
  echo "🔍 Testing HTTP connectivity..."
  local attempts=0
  local max_attempts=10
  while [[ $attempts -lt $max_attempts ]]; do
    if curl -fsS --max-time 5 "$URL" >/dev/null 2>&1; then
      echo "✅ Frontend ready and accessible"
      return 0
    fi
    ((attempts++))
    echo "⏳ Attempt $attempts/$max_attempts failed, retrying..."
    sleep 3
  done
  
  echo "❌ Frontend not accessible after $max_attempts attempts"
  return 1
}

# ─── Helper: run wrk and return total errors ──────────────────────────────
run_wrk() {
  local logfile="$1"
  local expected_total=$((RATE * DURATION))
  local total errors

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
  
  # Parse errors
  errors=0
  if grep -qE "Status 5xx:[[:space:]]+" "$logfile"; then
    errors=$(grep -E "Status 5xx:[[:space:]]+[0-9]+" "$logfile" | awk '{print $NF}')
  fi
  
  # Validate numbers
  if [[ ! "$total" =~ ^[0-9]+$ ]]; then
    total=$expected_total
  fi
  if [[ ! "$errors" =~ ^[0-9]+$ ]]; then
    errors=0
  fi

  # Add socket errors
  local sock_errors=$(grep -Eo 'Socket errors:[^ ]+[[:space:]]*[0-9]+' "$logfile" | grep -Eo '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo 0)
  errors=$((errors + sock_errors))

  echo "$total $errors"
}

# ─── Helper: kill random subset of services ───────────────────────────────
random_kill() {
  local fraction="$1" ; local round="$2"

  # Get all hotel reservation services (excluding infrastructure)
  local services=("frontend" "search" "geo" "profile" "rate" "recommendation" "reservation" "user")
  local total=${#services[@]}
  (( total == 0 )) && { echo "No services found!" >&2; return; }

  # Deterministic sample via python
  mapfile -t victims < <(python3 - "$fraction" "$SEED" "$round" "${services[@]}" <<'PY'
import sys, random, math
frac = float(sys.argv[1])
seed = int(sys.argv[2]) + int(sys.argv[3])
services = sys.argv[4:]
random.seed(seed)
kill_n = max(1, math.ceil(len(services) * frac))
print('\n'.join(random.sample(services, k=kill_n)))
PY
  )

  printf '%s\n' "${victims[@]}" >"$OUTDIR/killed_${round}.txt"

  echo "[Round $round] Killing services: ${victims[*]}"
  
  # Scale down victim services to 0 replicas
  for service in "${victims[@]}"; do
    kubectl scale deployment/"$service" --replicas=0 >/dev/null 2>&1 || true
  done
}

# ─── Helper: restart stack ─────────────────────────────────────────────────
restart_stack() {
  echo "🔄 Restarting Kubernetes stack..."
  
  # Cleanup
  cleanup
  kubectl delete -Rf kubernetes/ >/dev/null 2>&1 || true
  
  # Wait for cleanup to complete
  echo "⏳ Waiting for cleanup to complete..."
  timeout 90 bash -c 'while kubectl get pods --no-headers 2>/dev/null | grep -qE "(frontend|search|geo|profile|rate|recommendation|reservation|user)"; do sleep 2; done' || {
    echo "⚠️ Some pods still exist after cleanup timeout"
  }
  
  # Deploy fresh stack
  echo "🚀 Deploying fresh stack..."
  kubectl apply -Rf kubernetes/ >/dev/null 2>&1
  
  # Wait a bit for initial deployment
  sleep 15
  
  # Scale for replication mode
  if [[ "$MODE" == "repl" ]]; then
    echo "📈 Scaling for replication mode..."
    local services=("frontend" "search" "geo" "profile" "rate" "recommendation" "reservation" "user")
    for service in "${services[@]}"; do
      kubectl scale deployment/"$service" --replicas=3 >/dev/null 2>&1 || true
    done
    sleep 10
  fi
  
  # Wait for critical services first (backend dependencies)
  echo "⏳ Waiting for backend services..."
  local backend_services=("search" "geo" "profile" "rate" "recommendation" "reservation" "user")
  for service in "${backend_services[@]}"; do
    echo "⏳ Waiting for $service..."
    kubectl wait --for=condition=available deployment/"$service" --timeout=180s >/dev/null 2>&1 || {
      echo "⚠️ $service not ready within timeout"
    }
  done
  
  # Wait for frontend last (depends on backends)
  echo "⏳ Waiting for frontend..."
  kubectl wait --for=condition=available deployment/frontend --timeout=180s >/dev/null 2>&1 || {
    echo "⚠️ Frontend deployment not ready within timeout"
  }
  
  # Additional wait for service mesh and dependencies to stabilize
  echo "⏳ Allowing services to stabilize..."
  sleep 20
}

echo "=== Hotel Reservation Chaos Test ($ROUNDS rounds, fail=$FAIL_FRACTION, seed=$SEED, mode=$MODE) ==="

rounds=0
total_sum=0
error_sum=0

for round in $(seq 1 "$ROUNDS"); do
  echo "-- round $round/$ROUNDS --"
  
  echo "[Round $round] restarting stack..."
  restart_stack
  
  echo "[Round $round] waiting for stack to be healthy..."
  if ! wait_ready; then
    echo "[Round $round] Stack not ready, treating as system failure"
    echo "[Round $round] Debug info:"
    kubectl get pods -l io.kompose.service=frontend 2>/dev/null || echo "No frontend pods"
    kubectl get svc frontend 2>/dev/null || echo "No frontend service"
    ps aux | grep "port-forward" | grep -v grep || echo "No port-forward processes"
    total=$((RATE * DURATION))
    errors=$total
  else
    echo "[Round $round] stack is healthy."
    
    echo "[Round $round] injecting chaos..."
    random_kill "$FAIL_FRACTION" "$round"
    echo "[Round $round] chaos injected."
    
    # Wait for chaos to take effect
    sleep 15
    
    echo "[Round $round] applying workload..."
    logfile="$OUTDIR/wrk_${round}.log"
    read total errors <<< "$(run_wrk "$logfile")"
    
    if [[ "$total" =~ ^[0-9]+$ ]] && [[ "$errors" =~ ^[0-9]+$ ]]; then
      echo "[Round $round] workload applied. Total: $total, Errors: $errors"
    else
      echo "[Round $round] ERROR: Invalid wrk results"
      total=$((RATE * DURATION))
      errors=$total
    fi
  fi

  echo "counting..."
  ((rounds++)) || true
  ((total_sum+=total)) || true
  ((error_sum+=errors)) || true

  # Capture logs at round 47 like original
  if [ "$round" -eq 47 ]; then
    echo "[Round $round] Capturing logs..."
    kubectl logs -l 'io.kompose.service in (frontend,search,geo,profile,rate,recommendation,reservation,user)' \
      --all-containers=true --prefix=true --tail=500 > "$OUTDIR/k8s_logs_round_${round}.txt" 2>/dev/null || true
  fi
done

echo "done, aggregating results..."

# ─── Aggregate R_live ─────────────────────────────────────────────────────
python3 - <<'PY' "$rounds" "$error_sum" "$total_sum" "$OUTDIR/summary.json"
import json, sys
r, err, tot, path = list(map(int, sys.argv[1:4])) + [sys.argv[4]]
R = 0.0 if tot == 0 else 1.0 - err / tot
json.dump({"rounds": r, "R_live": round(R, 5)}, open(path, "w"), indent=2)
print(f"*** Mean R_live over {r} rounds: {R:.4f}")
PY

echo "done. Results written to $OUTDIR/summary.json"