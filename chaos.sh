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
ROUNDS=${ROUNDS:-1}
FAIL_FRACTION=${FAIL_FRACTION:-0.30}     # share of containers to kill
SEED=${SEED:-16}                         # diff: new – deterministic RNG

RATE=${RATE:-300}
DURATION=${DURATION:-30}
THREADS=${THREADS:-2}
CONNS=${CONNS:-32}
URL=${URL:-http://localhost:8080/index.html}
LUA=${LUA:-wrk2/scripts/social-network/mixed-workload-5xx.lua}

OUTDIR=${OUTDIR:-results/run_$(date +%Y%m%d-%H%M%S)}   # diff: generic folder
mkdir -p "$OUTDIR"
echo "round,total,errors" >"$OUTDIR/metrics.csv"

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
      # ---- count only real availability failures -------------------------
      # 1) number of HTTP 5xx responses the Lua script printed
      local fivexx
      fivexx=$(grep -Eo '5xx_responses:[[:space:]]*[0-9]+' "$logfile" \
                 | awk '{print $NF}')
      fivexx=${fivexx:-0}
      # 2) sum of all socket-level errors (connect/read/write/timeout)
      local sock
      sock=$(grep -Eo 'Socket errors:[^ ]+[[:space:]]*[0-9]+' "$logfile" \
               | grep -Eo '[0-9]+' | paste -sd+ - | bc || echo 0)

      errors=$(( fivexx + sock ))
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
  local py=$(cat <<'PY'
import os, sys, random, math, json
total  = int(sys.argv[1])
frac   = float(sys.argv[2])
seed   = int(os.environ.get("SEED", "16")) + int(sys.argv[3])  # vary per round
random.seed(seed)
kill_cnt = max(1, math.ceil(total * frac))
victims  = random.sample(sys.stdin.read().split(), k=kill_cnt)
print('\n'.join(victims))
PY
)
  mapfile -t victims < <(printf '%s\n' "${containers[@]}" \
                         | python - "$total" "$fraction" "$round")

  printf '%s\n' "${victims[@]}" >"$OUTDIR/killed_${round}.txt"

  # diff: disable auto-restart so that victims stay down for the whole round
  docker update --restart=no "${victims[@]}" || true
  docker kill "${victims[@]}" || true
}

echo "=== Chaos test ($ROUNDS rounds, fail=$FAIL_FRACTION, seed=$SEED) ==="

for round in $(seq 1 "$ROUNDS"); do
  echo "-- round $round/$ROUNDS --"
  
  # 1) make sure the stack is healthy after the last restart
  wait_ready
  
  # 2) inject chaos
  random_kill "$FAIL_FRACTION" "$round"

  # 3) apply load
  logfile="$OUTDIR/wrk_${round}.log"
  read total errors < <(run_wrk "$logfile")
  echo "$round,$total,$errors" >>"$OUTDIR/metrics.csv"

  # 4) full restart of the stack before the next round
  docker compose down -v
  docker compose up -d
done

# ─── Aggregate R_live ─────────────────────────────────────────────────────
python - <<'PY' "$OUTDIR/metrics.csv" "$OUTDIR/summary.json"
import csv, json, statistics, sys
csv_path, json_path = sys.argv[1:]
vals = []
with open(csv_path) as f:
    next(f)
    for _, total, errors in csv.reader(f):
        t, e = int(total), int(errors)
        vals.append(1.0 - e / t if t else 0.0)
json.dump({"rounds": len(vals), "R_live": statistics.mean(vals)}, open(json_path, "w"), indent=2)
print(f"*** Mean R_live over {len(vals)} rounds: {statistics.mean(vals):.4f}")
PY

# ─── Dump per-round stats to chaos_runs.json ──────────────────────────────
python - <<'PY' "$OUTDIR/metrics.csv" "$OUTDIR/chaos_runs.json"
import csv, json, sys
csv_path, json_path = sys.argv[1:]
rows = []
with open(csv_path) as f:
    next(f)
    for r, total, errors in csv.reader(f):
        rows.append({"round": int(r), "total": int(total), "errors": int(errors)})
json.dump(rows, open(json_path, "w"), indent=2)
PY
