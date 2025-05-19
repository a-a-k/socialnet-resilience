#!/usr/bin/env bash
# -------------------------------------------------------------------
# chaos.sh      — generic chaos-engineering driver
#
# Per round we:
#   1) randomly kill ≈30 % of running containers;
#   2) apply a 300 RPS load for 30 s with wrk2 (mixed-workload);
#   3) record both *total* and *error* request counts — even when the
#      frontend (`nginx-thrift`) is completely down;
#   4) bring the whole compose stack back up before the next round.
#
#  * Works for both single-replica and replicated stacks.
#  * Always kills ≈FAIL_FRACTION of *application* containers
#    (Jaeger / Prometheus / Grafana are excluded).
#  * Deterministic when SEED is fixed, yet still random within a run.
# -------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/DeathStarBench/socialNetwork"

# ─── Tunables (can be overridden via env-vars) ────────────────────────────
ROUNDS=${ROUNDS:-500}
FAIL_FRACTION=${FAIL_FRACTION:-0.30}     # share of containers to kill
SEED=${SEED:-25}                         # diff: new – deterministic RNG
RATE=${RATE:-300}
DURATION=${DURATION:-30}
THREADS=${THREADS:-2}
CONNS=${CONNS:-32}
URL=${URL:-http://localhost:8080/index.html}
LUA=${LUA:-wrk2/scripts/social-network/mixed-workload-5xx.lua}
SCALE_ARGS=""
MODE="norepl"
# number of replicas for the "replicated" scenario
if [[ ${1:-} == "--repl" || ${1:-} == "-r" ]]; then
  SCALE_ARGS="--scale compose-post-service=3 \
                            --scale home-timeline-service=3 \
                            --scale user-timeline-service=3 \
                            --scale text-service=3 \
                            --scale media-service=3"
  MODE="repl"
  shift
fi

OUTDIR=${OUTDIR:-results/${MODE}}   # diff: generic folder
mkdir -p "$OUTDIR"

# ─── Helper: wait until the frontend is reachable (or give up after 60 s) ─
wait_ready() {
  timeout 60 bash -c \
    'until curl -fsS '"$URL"' >/dev/null 2>&1; do sleep 2; done' || true
}

# ─── Helper: run wrk and ALWAYS return two numbers: total errors ───────────
run_wrk() {
  local logfile="$1"
  local expected_total=$((RATE * DURATION))
  local total errors

  wrk -t"$THREADS" -c"$CONNS" -d"${DURATION}s" -R"$RATE" \
      -s "$LUA" "$URL" >"$logfile" 2>&1 || true

  echo "[run_wrk] --- Full contents of $logfile ---" >&2
  cat "$logfile" >&2
  echo "[run_wrk] --- End of $logfile ---" >&2

  
  if grep -q 'requests in' "$logfile"; then
    total=$(grep -Eo '[0-9]+ requests in' "$logfile" | awk '{print $1}')
  else
    total=$expected_total
    errors=$total
    echo "$total $errors"
    return
  fi
  
  # Parse errors from our new Status Code Summary section
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

  sock_errors=$(grep -Eo 'Socket errors:[^ ]+[[:space:]]*[0-9]+' "$logfile" | grep -Eo '[0-9]+' | paste -sd+ - | bc || echo 0)
  errors=$((errors + sock_errors))

  echo "$total $errors"
}

# ─── Helper: kill a random subset of *business* containers ────────────────
random_kill() {
  local fraction="$1" ; local round="$2"

  # Exclude monitoring/helper containers by name
  mapfile -t containers < <(
      docker compose ps --format '{{.ID}} {{.Name}}' \
      | grep -vE '(jaeger|prometheus|grafana|wrkbench)' \
      | awk '{print $1}'
  )

  local total=${#containers[@]}
  (( total == 0 )) && { echo "No running containers!" >&2; return; }

  # diff: deterministic sample via python (respects SEED)
  mapfile -t victims < <(python - "$FAIL_FRACTION" "$SEED" "$round" \
      "${containers[@]}" <<'PY'
import sys, random, math
frac   = float(sys.argv[1])
seed   = int(sys.argv[2]) + int(sys.argv[3])      # base-seed + round
containers = sys.argv[4:]                         # remaining argv[]
random.seed(seed)
kill_n = max(1, math.ceil(len(containers) * frac))
print('\n'.join(random.sample(containers, k=kill_n)))
PY
  )

  local killed_count=0
  local target_kill_count=${#victims[@]}

  printf '%s\n' "${victims[@]}" >"$OUTDIR/killed_${round}.txt"

  # Print human-friendly names for killed containers
  echo "[Round $round] Killed containers (ID : Name):"
  for id in "${victims[@]}"; do
    name=$(docker ps -a --filter "id=$id" --format "{{.Names}}")
    echo "$id : $name"
  done

  # diff: disable auto-restart so that victims stay down for the whole round
  docker update --restart=no "${victims[@]}" || true
  docker kill "${victims[@]}" || true
}

echo "=== Chaos test ($ROUNDS rounds, fail=$FAIL_FRACTION, seed=$SEED) ==="

rounds=0
total_sum=0
error_sum=0

for round in $(seq 1 "$ROUNDS"); do
  echo "-- round $round/$ROUNDS --"
  
  echo "[Round $round] waiting for stack to be healthy..."
  wait_ready
  echo "[Round $round] stack is healthy."

  echo "[Round $round] Running containers:"
  docker ps
  #echo "[Round $round] Disk usage:"
  #df -h
  #echo "[Round $round] Memory usage:"
  #free -m

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
          # Optionally: exit 1
      fi
  else
      echo "[Round $round] ERROR: run_wrk failed (read/process substitution error)"
      echo "[Round $round] --- wrk log tail ---"
      tail -40 "$logfile"
      echo "[Round $round] --- end wrk log ---"
      # Optionally: exit 1
  fi

  echo "[Round $round] restarting stack..."
  if ! docker compose down -v > /dev/null 2>&1; then
      echo "[Round $round] ERROR: docker compose down failed"
      exit 1
  fi
  if ! docker compose up -d ${SCALE_ARGS}; then
      echo "[Round $round] ERROR: docker compose up failed"
      exit 1
  fi
  echo "[Round $round] stack restarted."

  echo "[Round $round] Exited containers:"
  docker ps -a --filter "status=exited"

  echo "counting..."
  ((rounds++))  || true
  ((total_sum+=total))  || true
  ((error_sum+=errors))  || true

  if [ "$round" -eq 47 ]; then
      echo "[Round $round] Capturing logs from all containers..."
      docker compose logs > "$OUTDIR/docker_logs_round_${round}.txt"
  fi
done

echo "done, aggregating results..."

# ─── Aggregate R_live ─────────────────────────────────────────────────────
python - <<'PY' "$rounds" "$error_sum" "$total_sum" "$OUTDIR/summary.json"
import json, sys
r, err, tot, path = list(map(int, sys.argv[1:4])) + [sys.argv[4]]
R = 0.0 if tot == 0 else 1.0 - err / tot
json.dump({"rounds": r, "R_live": R}, open(path, "w"), indent=2)
print(f"*** Mean R_live over {r} rounds: {R:.4f}")
PY

echo "done. Results written to $OUTDIR/summary.json"
exit 0
