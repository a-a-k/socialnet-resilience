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
ROUNDS=${ROUNDS:-30}
FAIL_FRACTION=${FAIL_FRACTION:-0.30}     # share of containers to kill
SEED=${SEED:-16}                         # diff: new – deterministic RNG
RATE=${RATE:-300}
DURATION=${DURATION:-30}
THREADS=${THREADS:-2}
CONNS=${CONNS:-32}
URL=${URL:-http://localhost:8080/index.html}
LUA=${LUA:-wrk2/scripts/social-network/mixed-workload.lua}
SCALE_ARGS=""
MODE="norepl"
# number of replicas for the “replicated” scenario
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

  wrk -t"$THREADS" -c"$CONNS" -d"${DURATION}s" -R"$RATE" \
      -s "$LUA" "$URL" >"$logfile" 2>&1 || true     # ignore RC

  local total errors
  if grep -q 'requests in' "$logfile"; then
      total=$(grep -Eo '[0-9]+ requests in' "$logfile" | awk '{print $1}')
      # diff: count every non-2xx/3xx response that wrk prints natively
      local bad
      bad=$(grep -Eo 'Non-2xx or 3xx responses:[[:space:]]*[0-9]+' "$logfile" \
              | awk '{print $NF}')
      bad=${bad:-0}
      # 2) sum of all socket-level errors (connect/read/write/timeout)
      local sock
      sock=$(grep -Eo 'Socket errors:[^ ]+[[:space:]]*[0-9]+' "$logfile" \
               | grep -Eo '[0-9]+' | paste -sd+ - | bc || echo 0)

      errors=$(( bad + sock ))
  else
      # wrk failed before producing stats (e.g., nginx-thrift was dead)
      total=$expected_total
      errors=$total
  fi
  echo "$total $errors"
}

# ─── Helper: kill a random subset of *business* containers ────────────────
random_kill() {
  local fraction="$1" ; local round="$2"

  # diff: exclude monitoring/helper containers
  mapfile -t containers < <(
      docker compose ps -q \
      | grep -vE '(jaeger|prometheus|grafana|wrkbench)'
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

  printf '%s\n' "${victims[@]}" >"$OUTDIR/killed_${round}.txt"

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
  
  # 1) make sure the stack is healthy after the last restart
  echo "waiting..."
  wait_ready
  
  # 2) inject chaos
  echo "injecting..."
  random_kill "$FAIL_FRACTION" "$round"

  # 3) apply load
  echo "applying workload..."
  logfile="$OUTDIR/wrk_${round}.log"
  read total errors < <(run_wrk "$logfile")

  echo "counting..."
  ((rounds++))  || true
  ((total_sum+=total))  || true
  ((error_sum+=errors))  || true

  # 4) full restart of the stack before the next round
  echo "restarting..."
  docker compose down -v
  docker compose up -d ${SCALE_ARGS}
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
