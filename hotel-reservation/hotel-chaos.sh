#!/usr/bin/env bash
# -------------------------------------------------------------------
# hotel-chaos.sh — chaos-engineering driver for hotel-reservation
#
# Per round we:
#   1) randomly kill ≈30% of running pods in Kubernetes;
#   2) apply a 300 RPS load for 30s with wrk2 (hotel-reservation workload);
#   3) record both *total* and *error* request counts — even when the
#      frontend is completely down;
#   4) bring the whole Kubernetes deployment back up before the next round.
#
#  * Works for both single-replica and replicated stacks.
#  * Always kills ≈FAIL_FRACTION of *application* pods
#    (Jaeger / monitoring pods are excluded).
#  * Deterministic when SEED is fixed, yet still random within a run.
# -------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/DeathStarBench/hotelReservation"

# ─── Tunables (can be overridden via env-vars) ────────────────────────────
ROUNDS=${ROUNDS:-450}
FAIL_FRACTION=${FAIL_FRACTION:-0.30}     # share of containers to kill
SEED=${SEED:-16}
RATE=${RATE:-300}
DURATION=${DURATION:-30}
THREADS=${THREADS:-2}
CONNS=${CONNS:-32}
LUA=${LUA:-wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua}
MODE="norepl"

# number of replicas for the "replicated" scenario
if [[ ${1:-} == "--repl" || ${1:-} == "-r" ]]; then
  MODE="repl"
  shift
fi

OUTDIR=${OUTDIR:-results/hotel-${MODE}-chaos}
mkdir -p "$OUTDIR"

# Get frontend service URL
get_frontend_url() {
  minikube service frontend --url 2>/dev/null || echo "http://localhost:5000"
}

URL=$(get_frontend_url)

# ─── Helper: wait until the frontend is reachable (or give up after 60s) ─
wait_ready() {
  timeout 60 bash -c \
    'until curl -fsS '"$URL"' >/dev/null 2>&1; do sleep 1; done' || true
}

# ─── Helper: run wrk and ALWAYS return two numbers: total errors ───────────
run_wrk() {
  local logfile="$1"
  local expected_total=$((RATE * DURATION))
  local total errors

  # Set TARGET_URL environment variable for the Lua script
  TARGET_URL="$URL" wrk -t"$THREADS" -c"$CONNS" -d"${DURATION}s" -R"$RATE" \
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
  sock_errors=$(grep -Eo 'Socket errors:[^ ]+[[:space:]]*[0-9]+' "$logfile" | grep -Eo '[0-9]+' | paste -sd+ - | bc || echo 0)
  errors=$((errors + sock_errors))

  echo "$total $errors"
}

# ─── Helper: kill a random subset of *business* pods ────────────────
random_kill() {
  local fraction="$1" ; local round="$2"

  # Get all hotel-reservation application pods (exclude system/monitoring pods)
  mapfile -t pods < <(
      kubectl get pods -o jsonpath='{.items[*].metadata.name}' \
      | tr ' ' '\n' \
      | grep -vE '(jaeger|consul|mongodb|memcached)' \
      | grep -E '(frontend|search|geo|profile|rate|recommendation|reservation|user)' \
      | head -50
  )

  local total=${#pods[@]}
  (( total == 0 )) && { echo "No running application pods!" >&2; return; }

  # Deterministic sample via python (respects SEED)
  mapfile -t victims < <(python3 - "$FAIL_FRACTION" "$SEED" "$round" \
      "${pods[@]}" <<'PY'
import sys, random, math
frac   = float(sys.argv[1])
seed   = int(sys.argv[2]) + int(sys.argv[3])      # base-seed + round
pods = sys.argv[4:]                               # remaining argv[]
random.seed(seed)
kill_n = max(1, math.ceil(len(pods) * frac))
kill_n = min(kill_n, len(pods))  # don't exceed available pods
print('\n'.join(random.sample(pods, k=kill_n)))
PY
  )

  local target_kill_count=${#victims[@]}
  printf '%s\n' "${victims[@]}" >"$OUTDIR/killed_${round}.txt"

  echo "[Round $round] Killing $target_kill_count out of $total application pods"

  # Delete the selected pods
  if [ ${#victims[@]} -gt 0 ]; then
    kubectl delete pod "${victims[@]}" --force --grace-period=0 || true
  fi
}

# ─── Helper: deploy with appropriate scaling ───────────────────────────────
deploy_stack() {
  echo "Deploying Kubernetes stack..."
  kubectl apply -Rf kubernetes/ > /dev/null 2>&1

  if [[ "$MODE" == "repl" ]]; then
    echo "Scaling services for replication..."
    kubectl scale deployment/frontend --replicas=3
    kubectl scale deployment/search --replicas=3
    kubectl scale deployment/geo --replicas=3
    kubectl scale deployment/profile --replicas=3
    kubectl scale deployment/rate --replicas=3
    kubectl scale deployment/recommendation --replicas=3
    kubectl scale deployment/reservation --replicas=3
    kubectl scale deployment/user --replicas=3
  fi

  echo "Waiting for pods to be ready..."
  kubectl wait --for=condition=ready pod --all --timeout=300s || true
}

# ─── Helper: cleanup and restart stack ─────────────────────────────────────
restart_stack() {
  echo "Restarting Kubernetes stack..."
  kubectl delete -Rf kubernetes/ > /dev/null 2>&1 || true
  sleep 5
  deploy_stack
}

echo "=== Hotel Reservation Chaos Test ($ROUNDS rounds, fail=$FAIL_FRACTION, seed=$SEED, mode=$MODE) ==="

# Initial deployment
deploy_stack

# Initialize hotel data
echo "Initializing hotel data..."
python3 scripts/init_hotel_db.py || true

rounds=0
total_sum=0
error_sum=0

for round in $(seq 1 "$ROUNDS"); do
  echo "-- round $round/$ROUNDS --"
  
  # Update frontend URL in case it changed
  URL=$(get_frontend_url)
  echo "[Round $round] Frontend URL: $URL"
  
  echo "[Round $round] waiting for stack to be healthy..."
  wait_ready
  echo "[Round $round] stack is healthy."

  echo "[Round $round] injecting chaos..."
  random_kill "$FAIL_FRACTION" "$round"
  echo "[Round $round] chaos injected."

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
        -l app.kubernetes.io/part-of=hotel-reservation \
        > "$OUTDIR/k8s_logs_round_${round}.txt" 2>/dev/null || true
  fi
done

echo "done, aggregating results..."

# ─── Aggregate R_live ─────────────────────────────────────────────────────
python3 - <<'PY' "$rounds" "$error_sum" "$total_sum" "$OUTDIR/summary.json"
import json, sys
r, err, tot, path = list(map(int, sys.argv[1:4])) + [sys.argv[4]]
R = 0.0 if tot == 0 else 1.0 - err / tot
result = {
    "rounds": r, 
    "R_live": round(R, 5),
    "total_requests": tot,
    "total_errors": err,
    "application": "hotel-reservation",
    "mode": sys.argv[0] if len(sys.argv) > 5 else "unknown"
}
json.dump(result, open(path, "w"), indent=2)
print(f"*** Mean R_live over {r} rounds: {R:.4f}")
PY

echo "done. Results written to $OUTDIR/summary.json"
exit 0
