#!/usr/bin/env bash
set -euo pipefail

# ---- CLI / env ----
APP="social-network"
REPL=0
OUT="results/${APP}/norepl/summary.json"
P_FAIL="${P_FAIL:-0.30}"  # failure fraction (0..1)
SEED="${SEED:-16}"        # base RNG seed
ROUNDS="${ROUNDS:-450}"   # number of chaos rounds

WRK=wrk

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)     APP="$2"; shift 2 ;;
    --repl)    REPL="$2"; shift 2 ;;
    -o|--out)  OUT="$2"; shift 2 ;;
    --p_fail)  P_FAIL="$2"; shift 2 ;;
    --seed)    SEED="$2"; shift 2 ;;
    --rounds)  ROUNDS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ---- Config ----
CFG="apps/${APP}/config.json"
COMPOSE_PROJECT="$(jq -r '.compose_project' "$CFG")"
URL="$(jq -r '.front_url' "$CFG")"
SCRIPT="$(jq -r '.wrk2.script' "$CFG")"
T="$(jq -r '.wrk2.threads' "$CFG")"
C="$(jq -r '.wrk2.connections' "$CFG")"
D="$(jq -r '.wrk2.duration' "$CFG")"
R="$(jq -r '.wrk2.rate' "$CFG")"
REPLICAS_FILE="$(jq -r '.replicas_file' "$CFG")"

# ---- helpers ----
app_dir_for() {
  case "$1" in
    social-network)    echo "socialNetwork" ;;
    media-service)     echo "mediaMicroservices" ;;
    hotel-reservation) echo "hotelReservation" ;;
    *) echo "unknown"; return 1 ;;
  esac
}
compose_cmd() {
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo "docker compose"
  fi
}

APP_DIR="$(app_dir_for "$APP")"
DC="$(compose_cmd)"

# Scale flags for replicated runs (read from replicas.json, ignore "default")
SCALE_ARGS=""
if [[ "$REPL" -eq 1 && -f "$REPLICAS_FILE" ]]; then
  SCALE_ARGS=$(jq -r 'to_entries | map(select(.key!="default") | "--scale \(.key)=\(.value)") | join(" ")' "$REPLICAS_FILE")
fi

MODE_DIR=$([[ "$REPL" -eq 1 ]] && echo "repl" || echo "norepl")
mkdir -p "results/${APP}/${MODE_DIR}"

echo "[chaos] app=${APP} project=${COMPOSE_PROJECT} url=${URL} rounds=${ROUNDS} p_fail=${P_FAIL} seed=${SEED}"

# ---- chaos loop ----
rounds=0
total_sum=0
error_sum=0

for round in $(seq 1 "$ROUNDS"); do
  echo "[round $round/$ROUNDS] selecting victims…"

  # Select only application containers of the target Compose project
  TARGETS=$(docker ps \
              --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
              --format '{{.ID}} {{.Names}}' \
            | grep -viE 'jaeger|prometheus|grafana|wrk' \
            | awk '{print $1}')

  COUNT=$(printf '%s\n' "$TARGETS" | sed '/^$/d' | wc -l | xargs)
  export COUNT P_FAIL

  # How many to kill: ceil(n * p_fail), min 1 when n>0
  KILL_N=$(python3 - <<'PY'
import math, os
n = int(os.environ.get("COUNT","0"))
p = float(os.environ.get("P_FAIL","0.30"))
print(max(1, math.ceil(n*p)) if n>0 else 0)
PY
)

  # Deterministic victim selection using (SEED + round)
  victims=""
  if [[ "$KILL_N" -gt 0 && "$COUNT" -gt 0 ]]; then
    export SEED round
    victims=$(python3 - <<'PY' <<< "$TARGETS"
import os,random,sys
k_env = os.environ.get("KILL_N","")
k = int(k_env) if k_env.isdigit() else 0
seed = int(os.environ.get("SEED","16")) + int(os.environ.get("round","0") or "0")
random.seed(seed)
targets = [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
if targets and k>0:
    from random import sample
    print("\n".join(sample(targets, min(k, len(targets)))))
PY
)
    if [[ -n "$victims" ]]; then
      printf '%s\n' "$victims" | tee "results/${APP}/${MODE_DIR}/killed_round_${round}.txt"
      printf '%s\n' "$victims" | xargs -r docker kill || true
    fi
  fi

  # Drive workload
  LOG="$(mktemp)"
  set +e
  $WRK -t"$T" -c"$C" -d"$D" -L -s "$SCRIPT" "$URL" -R "$R" >"$LOG" 2>&1
  rc=$?
  set -e

  # Parse metrics: total requests, non-2xx/3xx, socket errors
  total=$(awk '/requests in/ {print $1; exit}' "$LOG")
  if [[ -z "$total" ]]; then
    dur=$(echo "$D" | sed 's/s$//'); total=$(( dur * R ))
  fi
  non23=$(awk -F': ' '/^Non-2xx or 3xx responses:/ {print $2}' "$LOG" | tail -1); non23=${non23:-0}
  sock=$(awk '/^Socket errors:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i} END{print s+0}' "$LOG")
  errs=$(( non23 + sock ))

  rounds=$((rounds+1))
  total_sum=$((total_sum+total))
  error_sum=$((error_sum+errs))

  # Full stack restart between rounds (keeps failure effects independent)
  (
    cd "third_party/DeathStarBench/${APP_DIR}"
    $DC -p "${COMPOSE_PROJECT}" down -v
    $DC -p "${COMPOSE_PROJECT}" up -d ${SCALE_ARGS} -f "$REPO_ROOT/overrides/jaeger.override.yml"
  )
  # Small readiness wait for the frontend
  timeout 30 bash -c "until curl -fsS '$URL' >/dev/null; do sleep 0.5; done" || true
done

# Aggregate R_live over all rounds
R_live="0.0"
if [[ "$total_sum" -gt 0 ]]; then
  R_live=$(python3 - <<PY
tot=${total_sum}; err=${error_sum}
print(round(1.0 - (err/float(tot)), 5))
PY
)
fi

jq -n --arg v "$R_live" '{rounds:'"$rounds"',"R_live":($v|tonumber)}' > "$OUT"
echo "[chaos] rounds=$rounds total=$total_sum errors=$error_sum -> R_live=$(jq -r .R_live "$OUT")"
