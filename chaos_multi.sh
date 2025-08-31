#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root to avoid 'unbound variable' under `set -u`
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
# Make sure mode dir is set for artifact paths
MODE_DIR="${MODE_DIR:-${MODE:-norepl}}"

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
OVERRIDE=""
case "$APP" in
  social-network)
    OVERRIDE="overrides/sn-jaeger.override.yml"
    ;;
  media-service)
    OVERRIDE="overrides/ms-jaeger.override.yml"
    SCRIPT="00_helpers/ms-compose-review.lua"
    ;;
  hotel-reservation)
    OVERRIDE="overrides/hr-jaeger.override.yml"
    ;;
esac

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

  # Build list of killable app containers (exclude tracing/monitoring helpers)
  mapfile -t TARGETS < <(
    docker ps \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
      --format '{{.ID}} {{.Names}}' \
    | grep -Ev '(^|[[:punct:]])(jaeger|jaeger-agent|grafana|prometheus|zipkin|otel|wrk|wrkbench)([[:punct:]]|$)' \
    | awk '{print $1}'
  )

  COUNT=${#TARGETS[@]}
  # Compute how many to kill this round
  KILL_N=$(python3 - <<'PY'
import math, os
n=int(os.environ.get("COUNT","0"))
p=float(os.environ.get("P_FAIL","0.30"))
print(max(1, math.floor(n*p)) if n>0 else 0)
PY
  )

  # Deterministic sampling without replacement, read targets from stdin
  export KILL_N SEED ROUND
  victims=$(
    printf '%s\n' "${TARGETS[@]}" | python3 -c '
import os, sys, random
targets=[l.strip() for l in sys.stdin if l.strip()]
k=int(os.environ.get("KILL_N","0") or 0)
seed=int(os.environ.get("SEED","16") or 16) + int(os.environ.get("ROUND","0") or 0)
random.seed(seed)
for v in (random.sample(targets, min(k, len(targets))) if targets and k>0 else []):
    print(v)
'
  )

  # Kill selected containers
  if [[ -n "$victims" ]]; then
    printf '%s\n' "$victims" | tee "results/${APP}/${MODE_DIR}/killed_round_${ROUND}.txt"
    printf '%s\n' "$victims" | xargs -r docker kill
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
    $DC -p "${COMPOSE_PROJECT}" -f "$OVERRIDE" up -d ${SCALE_ARGS}
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
