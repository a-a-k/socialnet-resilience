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
URL="http://localhost:${FRONTEND_PORT}/index.html"
LUA=${LUA:-wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua}
MODE="norepl"

# number of replicas for the "replicated" scenario
if [[ ${1:-} == "--repl" || ${1:-} == "-r" ]]; then
  MODE="repl"
  shift
fi

OUTDIR=${OUTDIR:-results/hotel-${MODE}-chaos}
mkdir -p "$OUTDIR"

# Declare associative arrays to track port forwarding
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

# ─── Helper: setup port forwarding for all services ───────────────────────
setup_port_forwarding() {
  echo "🔌 Setting up port forwarding for all services ..."
  
  # Kill any lingering kubectl port-forwards
  pkill -f "kubectl.*port-forward" || true
  sleep 2

  # Get all non-system services and their ports
  local services=$(kubectl get svc -o json | jq -r '
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
    local pid=$!
    
    SERVICE_PIDS["$svc"]=$pid
    SERVICE_URLS["$svc"]="http://localhost:${port}"
  done <<< "$services"

  # Show access URLs
  echo "🎯 Port-forwarded services:"
  for svc in "${!SERVICE_URLS[@]}"; do
    echo "✅ $svc: ${SERVICE_URLS[$svc]}"
  done
}

# ─── Helper: wait until the frontend is reachable ─────────────────────────
wait_ready() {
  echo "Waiting for frontend to be ready at $URL..."
  timeout 60 bash -c \
    'until curl -fsS '"$URL"' >/dev/null 2>&1; do sleep 1; done' || {
    echo "WARNING: Frontend not reachable at $URL after 60s timeout"
    return 1
  }
  echo "Frontend is ready!"
}

# ─── Helper: run wrk and return total errors ──────────────────────────────
run_wrk() {
  local logfile="$1"
  local expected_total=$((RATE * DURATION))
  local total errors

  # Set TARGET_URL environment variable for the Lua script
  TARGET_URL="$URL" wrk2 -t"$THREADS" -c"$CONNS" -d"${DURATION}s" -R"$RATE" \
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

# ─── Helper: kill a random subset of application pods ─────────────────────
random_kill() {
  local fraction="$1" ; local round="$2"

  # Get all hotel-reservation application pods (exclude system/monitoring pods)
  mapfile -t pods < <(
      kubectl get pods --no-headers -o custom-columns=":metadata.name" \
      | grep -vE '(jaeger|consul|mongodb|memcached)' \
      | grep -E '(frontend|search|geo|profile|rate|recommendation|reservation|user)'
  )

  local total=${#pods[@]}
  (( total == 0 )) && { echo "No running application pods!" >&2; return; }

  # Deterministic sample via python (respects SEED)
  mapfile -t victims < <(python3 - "$fraction" "$SEED" "$round" \
      "${pods[@]}" <<'PY'
import sys, random, math
frac   = float(sys.argv[1])
seed   = int(sys.argv[2]) + int(sys.argv[3])      # base-seed + round
pods = sys.argv[4:]                               # remaining argv[]
random.seed(seed)
kill_n = max(1, math.ceil(len(pods) * frac))
kill_n = min(kill_n, len(pods))  # don't exceed available pods
if pods:
    print('\n'.join(random.sample(pods, k=kill_n)))
PY
  )

  local target_kill_count=${#victims[@]}
  if [ $target_kill_count -gt 0 ]; then
    printf '%s\n' "${victims[@]}" >"$OUTDIR/killed_${round}.txt"
    echo "[Round $round] Killing $target_kill_count out of $total application pods"
    kubectl delete pod "${victims[@]}" --force --grace-period=0 || true
  else
    echo "[Round $round] No pods to kill"
  fi
}

# ─── Helper: deploy with appropriate scaling ───────────────────────────────
deploy_stack() {
  echo "Deploying Kubernetes stack..."
  kubectl apply -Rf kubernetes/ > /dev/null 2>&1

  if [[ "$MODE" == "repl" ]]; then
    echo "Scaling services for replication..."
    kubectl scale deployment/frontend --replicas=3 || true
    kubectl scale deployment/search --replicas=3 || true
    kubectl scale deployment/geo --replicas=3 || true
    kubectl scale deployment/profile --replicas=3 || true
    kubectl scale deployment/rate --replicas=3 || true
    kubectl scale deployment/recommendation --replicas=3 || true
    kubectl scale deployment/reservation --replicas=3 || true
    kubectl scale deployment/user --replicas=3 || true
  fi

  echo "Waiting for pods to be ready..."
  kubectl wait --for=condition=ready pod --all --timeout=300s || true
  
  # Setup port forwarding after pods are ready
  setup_port_forwarding
}

# ─── Helper: cleanup and restart stack ─────────────────────────────────────
restart_stack() {
  echo "Restarting Kubernetes stack..."
  cleanup_port_forwards
  kubectl delete -Rf kubernetes/ > /dev/null 2>&1 || true
  sleep 5
  deploy_stack
}

# ─── Cleanup on exit ───────────────────────────────────────────────────────
trap cleanup_port_forwards EXIT

echo "=== Hotel Reservation Chaos Test ($ROUNDS rounds, fail=$FAIL_FRACTION, seed=$SEED, mode=$MODE) ==="

# Initial deployment
deploy_stack

rounds=0
total_sum=0
error_sum=0

for round in $(seq 1 "$ROUNDS"); do
  echo "-- round $round/$ROUNDS --"
  
  echo "[Round $round] waiting for stack to be healthy..."
  if ! wait_ready; then
    echo "[Round $round] Frontend not ready, skipping this round"
    continue
  fi
  echo "[Round $round] stack is healthy."

  echo "[Round $round] injecting chaos..."
  random_kill "$FAIL_FRACTION" "$round"
  echo "[Round $round] chaos injected."

  # Wait a bit for the chaos to take effect
  sleep 5

  echo "[Round $round] applying workload..."
  logfile="$OUTDIR/wrk_${round}.log"
  read total errors <<< "$(run_wrk "$logfile")"
  if [[ $? -eq 0 ]]; then
      if [[ "$total" =~ ^[0-9]+$ ]] && [[ "$errors" =~ ^[0-9]+$ ]]; then
          echo "[Round $round] workload applied. Total: $total, Errors: $errors"
          echo "[Round $round] Status code summary:"
          grep '^Status ' "$logfile" | sort || true
          echo "[Round $round] Socket errors:"
          grep 'Socket errors:' "$logfile" || echo "None"
      else
          echo "[Round $round] ERROR: run_wrk did not return valid numbers: total='$total', errors='$errors'"
          echo "[Round $round] --- wrk log tail ---"
          tail -40 "$logfile"
          echo "[Round $round] --- end wrk log ---"
      fi
  else
      echo "[Round $round] ERROR: run_wrk failed"
      echo "[Round $round] --- wrk log tail ---"
      tail -40 "$logfile"
      echo "[Round $round] --- end wrk log ---"
  fi

  echo "[Round $round] restarting stack..."
  restart_stack
  echo "[Round $round] stack restarted."

  echo "counting..."
  ((rounds++))  || true
  ((total_sum+=total))  || true
  ((error_sum+=errors))  || true

  if [ "$round" -eq 47 ]; then
      echo "[Round $round] Capturing logs from all pods..."
      kubectl logs --all-containers=true --prefix=true --tail=1000 \
        -l 'app in (frontend,search,geo,profile,rate,recommendation,reservation,user)' \
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