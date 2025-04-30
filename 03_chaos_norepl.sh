#!/usr/bin/env bash
# -------------------------------------------------------------------
# 03_chaos_norepl.sh
#
# Chaos test of the **baseline** social-network deployment  
# (exactly one replica per microservice).
#
# Per round we:
#   1) randomly kill ≈30 % of running containers;
#   2) apply a 300 RPS load for 30 s with wrk2 (mixed-workload);
#   3) record both *total* and *error* request counts — even when the
#      frontend (`nginx-thrift`) is completely down;
#   4) bring the whole compose stack back up before the next round.
#
# Output:
#   results/norepl/metrics.csv   — csv  round,total,errors
#   results/norepl/summary.json  — mean R_live over all rounds
# -------------------------------------------------------------------
set -euo pipefail

# ─── Tunables (can also be overridden via env-vars) ─────────────────
ROUNDS=${ROUNDS:-50}
FAIL_FRACTION=${FAIL_FRACTION:-0.30}     # share of containers to kill

RATE=${RATE:-300}        # requests per second
DURATION=${DURATION:-30} # seconds
THREADS=${THREADS:-2}
CONNS=${CONNS:-32}
URL=${URL:-http://localhost:8080/index.html}
LUA=${LUA:-wrk2/scripts/social-network/mixed-workload.lua}

OUTDIR=${OUTDIR:-results/norepl}
mkdir -p "$OUTDIR"
echo "round,total,errors" >"$OUTDIR/metrics.csv"

# ─── Helper: wait until the frontend is reachable (or give up after 60 s) ──
wait_ready() {
  timeout 60 bash -c \
    'until curl -fsS '"$URL"' >/dev/null 2>&1; do sleep 2; done' || true
}

# ─── Helper: run wrk and ALWAYS return two numbers: total errors ───────────
run_wrk() {
  local logfile="$1"
  local expected_total=$((RATE * DURATION))

  wrk -t"$THREADS" -c"$CONNS" -d"${DURATION}s" -R"$RATE" \
      -s "$LUA" "$URL" >"$logfile" 2>&1 || true     # ← ignore non-zero RC

  local total errors
  if grep -q 'requests in' "$logfile"; then
      total=$(grep -Eo '[0-9]+ requests in' "$logfile" | awk '{print $1}')
      errors=$(grep -Eo 'Non-2xx or 3xx responses:[[:space:]]*[0-9]+' "$logfile" \
               | awk '{print $NF}')
      errors=${errors:-0}
  else
      # wrk failed before producing stats (e.g., nginx-thrift was dead)
      total=$expected_total
      errors=$total
  fi
  echo "$total $errors"
}

# ─── Helper: kill a random subset of containers (≈30 %) ────────────────────
random_kill() {
  local fraction="$1" ; local round="$2"

  mapfile -t containers < <(docker compose ps -q)
  local total=${#containers[@]}
  (( total == 0 )) && { echo "No running containers!" >&2; return; }

  local kill_cnt
  kill_cnt=$(python - <<PY "$total" "$fraction"
import math, random, sys
t, f = int(sys.argv[1]), float(sys.argv[2])
print(max(1, round(t * f)))
PY
)

  local victims=($(printf '%s\n' "${containers[@]}" | shuf -n "$kill_cnt"))
  printf '%s\n' "${victims[@]}" >"$OUTDIR/killed_${round}.txt"
  docker kill "${victims[@]}" || true
}

echo "=== Chaos test without replicas ($ROUNDS rounds, fail=$FAIL_FRACTION) ==="

for round in $(seq 1 "$ROUNDS"); do
  echo "-- round $round / $ROUNDS --"

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

# ─── Calculate aggregated R_live ───────────────────────────────────────────
python - <<'PY' "$OUTDIR/metrics.csv" "$OUTDIR/summary.json"
import csv, json, statistics, sys
csv_path, json_path = sys.argv[1:]

vals = []
with open(csv_path) as f:
    next(f)                 # skip header
    for _, total, errors in csv.reader(f):
        total, errors = int(total), int(errors)
        vals.append(1.0 - errors / total if total else 0.0)

summary = {"rounds": len(vals), "R_live": statistics.mean(vals)}
json.dump(summary, open(json_path, "w"), indent=2)
print(f"*** Mean R_live over {summary['rounds']} rounds: {summary['R_live']:.4f}")
PY
