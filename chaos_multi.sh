#!/usr/bin/env bash
set -euo pipefail

APP="social-network"
REPL=0
P_FAIL="${P_FAIL:-0.30}"
OUT="results/${APP}/norepl/summary.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --repl) REPL="$2"; shift 2 ;;
    -o|--out) OUT="$2"; shift 2 ;;
    --p_fail) P_FAIL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

CFG="apps/${APP}/config.json"
COMPOSE_PROJECT="$(jq -r '.compose_project' "$CFG")"
WRK=wrk
URL="$(jq -r '.front_url' "$CFG")"
SCRIPT="$(jq -r '.wrk2.script' "$CFG")"
T="$(jq -r '.wrk2.threads' "$CFG")"
C="$(jq -r '.wrk2.connections' "$CFG")"
D="$(jq -r '.wrk2.duration' "$CFG")"
R="$(jq -r '.wrk2.rate' "$CFG")"

echo "[chaos] project=${COMPOSE_PROJECT}"

# Kill ≈P_FAIL of containers in the selected compose project
TARGETS=$(docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" -q)
COUNT=$(echo "$TARGETS" | wc -w | xargs)
KILL_N=$(python3 - <<PY
import math, os
n=int(os.environ.get("COUNT") or 0)
p=float(os.environ["P_FAIL"])
print(max(1, math.floor(n*p)) if n>0 else 0)
PY
)
if [[ "$KILL_N" -gt 0 ]]; then
  echo "$TARGETS" | tr ' ' '\n' | shuf -n "$KILL_N" | xargs -r docker kill
fi

# Drive workload and compute success ratio (works without custom Lua for MS/HR)
mkdir -p "results/${APP}/$([[ "$REPL" -eq 1 ]] && echo repl || echo norepl)"
LOG="$(mktemp)"
set +e
$WRK -t"$T" -c"$C" -d"$D" -L -s "$SCRIPT" "$URL" -R "$R" >"$LOG" 2>&1
set -e

# Prefer wrk's "X requests in"; else derive from duration*rate
total=$(awk '/requests in/ {print $1; exit}' "$LOG")
if [[ -z "$total" ]]; then
  dur=$(echo "$D" | sed 's/s$//')
  total=$(( dur * R ))
fi

# Generic error extraction (no SN-only hooks):
#   - Non-2xx or 3xx responses
#   - Socket errors: connect/read/write/timeout
non23=$(awk -F': ' '/^Non-2xx or 3xx responses:/ {print $2}' "$LOG" | tail -1)
non23=${non23:-0}
sock=$(awk '/^Socket errors:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i} END{print s+0}' "$LOG")
errs=$(( non23 + sock ))

R_live=0
if [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
  ok=$(( total - errs ))
  (( ok < 0 )) && ok=0
  R_live=$(python3 - <<PY
tot=${total}; ok=${ok}
print(round(ok/float(tot), 5))
PY
)
fi

jq -n --arg v "$R_live" '{R_live: ($v|tonumber)}' > "$OUT"
echo "[chaos] total=${total} non23=${non23} sock=${sock} -> R_live=$(jq -r .R_live "$OUT")"
