#!/usr/bin/env bash
# -------------------------------------------------------------------
# hotel-chaos-simple.sh — improved chaos for hotel-reservation (Kubernetes)
# - pod-aware port-forwarding (to frontend pod)
# - deterministic, reproducible kills by scaling deployments to 0
# - restore original replica counts after workload
# -------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/DeathStarBench/hotelReservation"

# Tunables
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
WRK_BIN=${WRK_BIN:-wrk}
MODE="norepl"

if [[ ${1:-} == "--repl" || ${1:-} == "-r" ]]; then
  MODE="repl"
  shift
fi

OUTDIR=${OUTDIR:-results/hotel-${MODE}-chaos}
mkdir -p "$OUTDIR"

# Globals for port-forward
PF_PID=""
PF_POD=""

# Track commands for debugging
last_cmd=""
current_cmd=""
trap 'last_cmd=$current_cmd; current_cmd=$BASH_COMMAND' DEBUG


# Cleanup handlers
cleanup_port_forward() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    PF_PID=""
  fi
}
cleanup() {
  local rc=${?}
  echo "🧹 Cleaning up... (script exit code: $rc)"
  echo "🔎 Last command: $last_cmd"
  echo "🔎 Current command: $current_cmd"

  cleanup_port_forward
  pkill -f "kubectl.*port-forward" 2>/dev/null || true
}
trap cleanup EXIT

# Find a running frontend pod name (returns empty if none)
find_frontend_pod() {
  kubectl get pods -l io.kompose.service=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# Ensure a port-forward to a running frontend pod exists and frontend is reachable
ensure_frontend_accessible() {
  local timeout_s=${1:-60}
  local start=$(date +%s)
  local attempt=0

  # If an existing PF PID exists, verify it's alive and the pod still exists
  if [[ -n "$PF_PID" ]]; then
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      echo "ℹ️ previous port-forward (PID $PF_PID) died, cleaning up..."
      cleanup_port_forward
    fi
  fi

  while true; do
    ((attempt++))
    # Pick a running frontend pod
    PF_POD=$(find_frontend_pod)
    if [[ -z "$PF_POD" ]]; then
      echo "⚠️ No frontend pod found (attempt $attempt). Waiting..."
      sleep 2
    else
      # If port-forward not running, start it to the pod
      if [[ -z "$PF_PID" ]]; then
        echo "🔌 Starting port-forward to pod/$PF_POD -> localhost:${FRONTEND_PORT} (attempt $attempt)"
        kubectl port-forward "pod/$PF_POD" "${FRONTEND_PORT}:5000" >/dev/null 2>&1 &
        PF_PID=$!
        # give it a short time to start
        sleep 2
      fi

      # check local TCP port
      if timeout 2 bash -c "echo >/dev/tcp/localhost/${FRONTEND_PORT}" 2>/dev/null; then
        # check HTTP
        if curl -fsS --max-time 5 "$URL" >/dev/null 2>&1; then
          echo "✅ Frontend reachable at $URL (pod: $PF_POD pid: $PF_PID)"
          return 0
        fi
      fi

      # If port-forward process died, cleanup to retry
      if ! kill -0 "$PF_PID" 2>/dev/null; then
        echo "⚠️ Port-forward process $PF_PID died; will retry"
        cleanup_port_forward
      else
        echo "ℹ️ Port-forward running but frontend not responding yet (attempt $attempt)"
      fi

      sleep 2
    fi

    if (( $(date +%s) - start >= timeout_s )); then
      echo "❌ Timed out waiting for frontend (timeout ${timeout_s}s)"
      ps aux | grep "kubectl.*port-forward" | grep -v grep || true
      kubectl get pods -l io.kompose.service=frontend --no-headers || true
      return 1
    fi
  done
}

# Run wrk (uses WRK_BIN) and return 'total errors' on stdout
run_wrk() {
  local logfile="$1"
  local expected_total=$((RATE * DURATION))
  local total errors

  if ! command -v "$WRK_BIN" >/dev/null 2>&1; then
    echo "❌ $WRK_BIN not found; please install wrk (or set WRK_BIN)."
    echo "$expected_total $expected_total"
    return
  fi

  "$WRK_BIN" -t"$THREADS" -c"$CONNS" -d"${DURATION}s" -R"$RATE" \
      -s "$LUA" "$URL" >"$logfile" 2>&1 || true

  if grep -q 'requests in' "$logfile"; then
    total=$(grep -Eo '[0-9]+ requests in' "$logfile" | awk '{print $1}')
  else
    total=$expected_total
    errors=$total
    echo "$total $errors"
    return
  fi

  errors=0
  if grep -qE "Status 5xx:[[:space:]]+[0-9]+" "$logfile"; then
    errors=$(grep -E "Status 5xx:[[:space:]]+[0-9]+" "$logfile" | awk '{print $NF}')
  fi

  # Add socket errors (if any)
  local sock_errors
  sock_errors=$(grep -Eo 'Socket errors:[^0-9]*[0-9]+' "$logfile" | grep -Eo '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo 0)
  errors=$((errors + sock_errors))

  # Fallback validation
  if [[ ! "$total" =~ ^[0-9]+$ ]]; then total=$expected_total; fi
  if [[ ! "$errors" =~ ^[0-9]+$ ]]; then errors=0; fi

  echo "$total $errors"
}

# Choose victims deterministically and scale to 0, save original replicas to JSON-like file
random_kill() {
  local fraction="$1" ; local round="$2"
  local services=("frontend" "search" "geo" "profile" "rate" "recommendation" "reservation" "user")
  local total=${#services[@]}

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

  # Save original replica counts and scale to 0
  local meta="$OUTDIR/killed_${round}_meta.txt"
  : > "$meta"
  for svc in "${victims[@]}"; do
    local orig
    orig=$(kubectl get deployment "$svc" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    echo "$svc:$orig" >> "$meta"
    kubectl scale deployment/"$svc" --replicas=0 >/dev/null 2>&1 || true
  done
}

# Restore victims from meta file
restore_killed() {
  local round="$1"
  local meta="$OUTDIR/killed_${round}_meta.txt"
  if [[ ! -f "$meta" ]]; then
    return
  fi
  echo "[Round $round] Restoring killed services from $meta"
  while IFS=: read -r svc orig; do
    if [[ -n "$svc" ]]; then
      local want=${orig:-1}
      # default to 1 if original was 0 or invalid
      if ! [[ "$want" =~ ^[0-9]+$ ]] || [[ "$want" -lt 1 ]]; then
        want=1
      fi
      kubectl scale deployment/"$svc" --replicas="$want" >/dev/null 2>&1 || true
    fi
  done < "$meta"
  # wait a short time for pods to come up
  sleep 8
}

# Restart full stack (delete & apply)
restart_stack() {
  echo "🔄 Restarting Kubernetes stack..."
  cleanup_port_forward
  kubectl delete -Rf kubernetes/ >/dev/null 2>&1 || true

  echo "⏳ Waiting for pods to terminate..."
  timeout 90 bash -c 'while kubectl get pods --no-headers 2>/dev/null | grep -qE "(frontend|search|geo|profile|rate|recommendation|reservation|user)"; do sleep 2; done' || {
    echo "⚠️ Some pods still exist after cleanup timeout"
  }

  echo "🚀 Deploying stack..."
  kubectl apply -Rf kubernetes/ >/dev/null 2>&1 || true
  sleep 10

  if [[ "$MODE" == "repl" ]]; then
    echo "📈 Scaling services for replication mode..."
    local svcs=("frontend" "search" "geo" "profile" "rate" "recommendation" "reservation" "user")
    for s in "${svcs[@]}"; do
      kubectl scale deployment/"$s" --replicas=3 >/dev/null 2>&1 || true
    done
    sleep 8
  fi

  # wait for backends, then frontend
  local backend_services=("search" "geo" "profile" "rate" "recommendation" "reservation" "user")
  for s in "${backend_services[@]}"; do
    echo "⏳ Waiting for $s..."
    kubectl wait --for=condition=available deployment/"$s" --timeout=120s >/dev/null 2>&1 || {
      echo "⚠️ $s not ready within timeout"
    }
  done

  echo "⏳ Waiting for frontend deployment..."
  kubectl wait --for=condition=available deployment/frontend --timeout=180s >/dev/null 2>&1 || {
    echo "⚠️ Frontend deployment not ready within timeout"
  }

  # establish port-forward and confirm frontend is reachable
  ensure_frontend_accessible 60 || {
    echo "❌ Frontend did not become reachable after deploy"
    return 1
  }

  # allow some stabilization
  sleep 5
}

# Main loop
echo "=== Hotel Reservation Chaos Test ($ROUNDS rounds, fail=$FAIL_FRACTION, seed=$SEED, mode=$MODE) ==="

rounds=0
total_sum=0
error_sum=0

for round in $(seq 1 "$ROUNDS"); do
  echo "-- round $round/$ROUNDS --"

  echo "[Round $round] restarting stack..."
  if ! restart_stack; then
    echo "[Round $round] Restart failed; marking round as failed"
    total=$((RATE * DURATION)); errors=$total
    rounds=$((rounds + 1))
    total_sum=$((total_sum + total))
    error_sum=$((error_sum + errors))
    continue
  fi

  echo "[Round $round] ensuring frontend is healthy..."
  if ! ensure_frontend_accessible 30; then
    echo "[Round $round] Frontend not ready; treating as system failure"
    total=$((RATE * DURATION)); errors=$total
  else
    echo "[Round $round] injecting chaos..."
    random_kill "$FAIL_FRACTION" "$round"
    echo "[Round $round] chaos injected."

    # small settle time after scaling victims to 0
    sleep 5

    echo "[Round $round] applying workload..."
    logfile="$OUTDIR/wrk_${round}.log"

    # temporarily disable exit-on-error while running wrk to avoid aborting the whole script
    set +e
    read total errors <<< "$(run_wrk "$logfile")"
    wrk_rc=$?
    set -e

    if [[ $wrk_rc -ne 0 ]]; then
      echo "[Round $round] run_wrk returned non-zero ($wrk_rc); treating as full error round"
      total=$((RATE * DURATION)); errors=$total
    fi

    # restore killed services (so subsequent rounds start from same base)
    restore_killed "$round"

    if [[ "$total" =~ ^[0-9]+$ ]] && [[ "$errors" =~ ^[0-9]+$ ]]; then
      echo "[Round $round] workload applied. Total: $total, Errors: $errors"
    else
      echo "[Round $round] ERROR: Invalid wrk results"
      total=$((RATE * DURATION)); errors=$total
    fi
  fi

  rounds=$((rounds + 1))
  total_sum=$((total_sum + total))
  error_sum=$((error_sum + errors))

  if [ "$round" -eq 47 ]; then
    echo "[Round $round] Capturing logs..."
    kubectl logs -l 'io.kompose.service in (frontend,search,geo,profile,rate,recommendation,reservation,user)' \
      --all-containers=true --prefix=true --tail=500 > "$OUTDIR/k8s_logs_round_${round}.txt" 2>/dev/null || true
  fi
done

# Aggregate R_live
python3 - <<'PY' "$rounds" "$error_sum" "$total_sum" "$OUTDIR/summary.json"
import json, sys
r, err, tot, path = list(map(int, sys.argv[1:4])) + [sys.argv[4]]
R = 0.0 if tot == 0 else 1.0 - err / tot
json.dump({"rounds": r, "R_live": round(R, 5)}, open(path, "w"), indent=2)
print(f"*** Mean R_live over {r} rounds: {R:.4f}")
PY

echo "done. Results written to $OUTDIR/summary.json"