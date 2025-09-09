#!/usr/bin/env bash
# -------------------------------------------------------------------
# Usage examples:
#   # Social Network (default app), no replication
#   ./chaos_multi.sh
#
#   # Any app declared under apps/<app>/config.json (restructured branch)
#   ./chaos_multi.sh --app media-service
#   ./chaos_multi.sh --app hotel-reservation --repl
#
#   # Override tunables via env or flags (take precedence over app config)
#   RATE=500 DURATION=45 THREADS=4 CONNS=128 ./chaos_multi.sh --app social-network
#   ./chaos_multi.sh --rate 500 --duration 45 --threads 4 --conns 128
#
# Output:
#   results/<app>/<mode>/summary.json  with {"rounds": N, "R_live": <0..1>}
#
# Notes:
#   * Requires: bash, jq, python3, curl, docker, docker compose, wrk2.
#   * The app must be running via docker compose under a stable project (-p)
#     that matches `compose_project` from apps/<app>/config.json.
# -------------------------------------------------------------------
set -euo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
APPS_DIR="${APPS_DIR:-${REPO_ROOT}/apps}"
DSB_DIR="${DSB_DIR:-${REPO_ROOT}/third_party/DeathStarBench}"
OVERRIDE="${OVERRIDE:-${REPO_ROOT}/overrides/docker-compose.override.yml}"

# ─── Defaults (env‑overridable) — kept close to chaos.sh semantics ───────
ROUNDS=${ROUNDS:-450}
FAIL_FRACTION=${FAIL_FRACTION:-0.30}     # share of containers to kill
SEED=${SEED:-16}
RATE=${RATE:-300}
DURATION=${DURATION:-}                   # seconds (int) or "30s"/"5m"
THREADS=${THREADS:-2}
CONNS=${CONNS:-32}
URL=${URL:-}                             # front URL; can be overridden
LUA=${LUA:-}                             # wrk2 Lua script path; can be overridden
WRK=${WRK:-wrk}
APP=${APP:-social-network}
REPL_FLAG=0                               # 0 = norepl, 1 = repl
OUTDIR=${OUTDIR:-}                        # computed below if empty

# ─── CLI ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)        APP="$2"; shift 2 ;;
    -r|--repl)    REPL_FLAG=1; shift ;;
    --repl=*)     REPL_FLAG="${1#*=}"; shift ;;
    -o|--out)     OUTDIR="$2"; shift 2 ;;
    --p-fail|--p_fail|--fail-fraction) FAIL_FRACTION="$2"; shift 2 ;;
    --seed)       SEED="$2"; shift 2 ;;
    --rounds)     ROUNDS="$2"; shift 2 ;;
    --rate)       RATE="$2"; shift 2 ;;
    --duration)   DURATION="$2"; shift 2 ;;
    --threads)    THREADS="$2"; shift 2 ;;
    --conns)      CONNS="$2"; shift 2 ;;
    --url)        URL="$2"; shift 2 ;;
    --lua)        LUA="$2"; shift 2 ;;
    *)            shift ;;
  esac
done

# ─── App config (multi‑app style) ────────────────────────────────────────
CFG="${APPS_DIR}/${APP}/config.json"
if [[ ! -f "$CFG" ]]; then
  echo "ERROR: app config not found: $CFG" >&2
  exit 1
fi

# pull defaults from config.json; env/flags override these
COMPOSE_PROJECT="$(jq -r '.compose_project' "$CFG")"
CFG_URL="$(jq -r '.front_url' "$CFG")"
CFG_LUA="$(jq -r '.wrk2.script' "$CFG")"
CFG_THREADS="$(jq -r '.wrk2.threads' "$CFG")"
CFG_CONNS="$(jq -r '.wrk2.connections' "$CFG")"
CFG_DURATION_RAW="$(jq -r '.wrk2.duration' "$CFG")"   # e.g. "30s"
CFG_RATE="$(jq -r '.wrk2.rate' "$CFG")"
REPLICAS_FILE="$(jq -r '.replicas_file' "$CFG" 2>/dev/null || echo "")"

# apply overrides (if provided via env/flags)
URL="${URL:-$CFG_URL}"
LUA="${LUA:-$CFG_LUA}"
THREADS="${THREADS:-$CFG_THREADS}"
CONNS="${CONNS:-$CFG_CONNS}"
RATE="${RATE:-$CFG_RATE}"

# duration handling: accept 45, "45s", "2m"
if [[ -z "${DURATION}" ]]; then
  DURATION_STR="$CFG_DURATION_RAW"
else
  # normalize numeric seconds to "<n>s" for wrk
  if [[ "$DURATION" =~ ^[0-9]+$ ]]; then
    DURATION_STR="${DURATION}s"
  else
    DURATION_STR="$DURATION"
  fi
fi

# derive seconds for math (expected total requests)
parse_duration_sec() {
  local s="${1:-30s}"
  case "$s" in
    *ms) echo $(( ${s%ms} / 1000 )) ;;
    *m)  echo $(( ${s%m}   * 60  )) ;;
    *s)  echo $(( ${s%s}         )) ;;
    ''|*[!0-9sm]) echo 30 ;;                # fallback
    *)   echo "$s" ;;
  esac
}
DURATION_SEC="$(parse_duration_sec "$DURATION_STR")"

# app dir for compose
app_dir_for() {
  case "$1" in
    social-network)    echo "socialNetwork" ;;
    media-service)     echo "mediaMicroservices" ;;
    hotel-reservation) echo "hotelReservation" ;;
    *) echo "unknown"; return 1 ;;
  esac
}
APP_DIR="$(app_dir_for "$APP")" || { echo "Unknown app '$APP'"; exit 1; }

# docker compose shim
compose_cmd() {
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo "docker compose"
  fi
}
DC="$(compose_cmd)"

# scale flags for replicated runs (read from replicas.json; ignore "default")
SCALE_ARGS=""
MODE="norepl"
if [[ "$REPL_FLAG" -eq 1 ]]; then
  MODE="repl"
  if [[ -n "${REPLICAS_FILE:-}" && -f "$REPLICAS_FILE" ]]; then
    SCALE_ARGS="$(jq -r 'to_entries
        | map(select(.key!="default") | "--scale \(.key)=\(.value)") | join(" ")' "$REPLICAS_FILE")"
  fi
fi

# results dir
OUTDIR="${OUTDIR:-${REPO_ROOT}/results/${APP}/${MODE}}"
mkdir -p "$OUTDIR"

echo "=== Chaos test app=${APP} project=${COMPOSE_PROJECT} mode=${MODE} rounds=${ROUNDS} fail=${FAIL_FRACTION} seed=${SEED} ==="
echo "[wrk] url=${URL} lua=${LUA} rate=${RATE} dur=${DURATION_STR} threads=${THREADS} conns=${CONNS}"

# ─── Helpers ─────────────────────────────────────────────────────────────
wait_ready() {
  # wait until the frontend is reachable (give up after ~15s)
  timeout 15 bash -c \
    'until curl -fsS '"$URL"' >/dev/null 2>&1; do sleep 0.3; done' || true
}

run_wrk() {
  # ALWAYS echo two integers: "<total> <errors>"
  local logfile="$1"
  local expected_total=$(( RATE * DURATION_SEC ))
  local total errors sock

  set +e
  "$WRK" -t"$THREADS" -c"$CONNS" -d"$DURATION_STR" -R"$RATE" \
         -s "$LUA" "$URL" >"$logfile" 2>&1
  set -e

  if grep -q 'requests in' "$logfile"; then
    total="$(grep -Eo '[0-9]+ requests in' "$logfile" | awk '{print $1}' | tail -1)"
  else
    # frontend fully down or wrk misparsed: assume all failed
    total="$expected_total"
    errors="$total"
    echo "$total $errors"
    return
  fi

  # Prefer the app‑aware "Status 5xx:" line (from our Lua summary)
  if grep -qE '^Status 5xx:[[:space:]]+[0-9]+' "$logfile"; then
    errors="$(awk '/^Status 5xx:/ {print $NF; exit}' "$logfile")"
  # Fallback to wrk's generic counter if present
  elif grep -qE '^Non-2xx or 3xx responses:' "$logfile"; then
    errors="$(awk -F': ' '/^Non-2xx or 3xx responses:/ {print $2; exit}' "$logfile")"
  else
    errors="0"
  fi

  # Add socket errors (connect/read/write)
  sock="$(awk '
    /^Socket errors:/ {
      for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i
    }
    END {print s+0}' "$logfile")"
  errors=$(( ${errors:-0} + ${sock:-0} ))

  # numeric guards
  [[ "$total"  =~ ^[0-9]+$ ]] || total="$expected_total"
  [[ "$errors" =~ ^[0-9]+$ ]] || errors=0

  echo "$total $errors"
}

random_kill() {
  # Kill a deterministic random subset of *business* containers for this app.
  local fraction="$1" ; local round="$2"

  # Scope to the app's compose project; exclude monitoring/wrk helpers
  mapfile -t containers < <(
    docker ps \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
      --format '{{.ID}} {{.Names}}' \
    | grep -Ev '(^|[[:punct:]])(jaeger|jaeger-agent|grafana|prometheus|zipkin|otel|wrk|wrkbench)([[:punct:]]|$)' \
    | awk '{print $1}'
  )

  local total=${#containers[@]}
  (( total == 0 )) && { echo "No running containers for project ${COMPOSE_PROJECT}" >&2; return; }

  # Deterministic sampling via python (SEED + round), ceil(total * fraction)
  mapfile -t victims < <(python3 - "$fraction" "$SEED" "$round" "${containers[@]}" <<'PY'
import sys, random, math
frac   = float(sys.argv[1])
seed   = int(sys.argv[2]) + int(sys.argv[3])   # base-seed + round
containers = sys.argv[4:]
random.seed(seed)
k = max(1, math.ceil(len(containers) * frac))
print('\n'.join(random.sample(containers, k=k)))
PY
  )

  printf '%s\n' "${victims[@]}" >"${OUTDIR}/killed_${round}.txt"

  # Disable auto-restart; keep them down for the round
  docker update --restart=no "${victims[@]}" >/dev/null 2>&1 || true
  docker kill "${victims[@]}" >/dev/null 2>&1 || true
}

# ─── Round loop ──────────────────────────────────────────────────────────
rounds=0
total_sum=0
error_sum=0

for round in $(seq 1 "$ROUNDS"); do
  echo "-- round $round/$ROUNDS --"
  echo "[Round $round] waiting for stack to be healthy..."
  wait_ready
  echo "[Round $round] stack is healthy."

  echo "[Round $round] injecting chaos..."
  random_kill "$FAIL_FRACTION" "$round"
  echo "[Round $round] chaos injected."

  echo "[Round $round] applying workload..."
  logfile="${OUTDIR}/wrk_${round}.log"
  read total errors < <(run_wrk "$logfile")
  if [[ "$total" =~ ^[0-9]+$ ]] && [[ "$errors" =~ ^[0-9]+$ ]]; then
    echo "[Round $round] workload applied. Total: $total, Errors: $errors"
    echo "[Round $round] Status code summary:"
    grep -E '^Status ' "$logfile" | sort || true
    echo "[Round $round] Socket errors:"
    grep -E '^Socket errors:' "$logfile" || echo "None"
  else
    echo "[Round $round] ERROR: invalid wrk parse: total='$total' errors='$errors'"
    echo "[Round $round] --- wrk log tail ---"
    tail -40 "$logfile" || true
    echo "[Round $round] --- end wrk log ---"
  fi

  echo "[Round $round] restarting stack..."
  (
    # choose per-app Jaeger ports (unique per app)
    case "$APP" in
      social-network)  JAEGER_HTTP_PORT="${JAEGER_HTTP_PORT:-16686}"; JAEGER_UDP_PORT="${JAEGER_UDP_PORT:-6831}" ;;
      media-service)   JAEGER_HTTP_PORT="${JAEGER_HTTP_PORT:-16687}"; JAEGER_UDP_PORT="${JAEGER_UDP_PORT:-6832}" ;;
      hotel-reservation) JAEGER_HTTP_PORT="${JAEGER_HTTP_PORT:-16688}"; JAEGER_UDP_PORT="${JAEGER_UDP_PORT:-6833}" ;;
    esac
    export JAEGER_HTTP_PORT JAEGER_UDP_PORT

    cd "${DSB_DIR}/${APP_DIR}"
    $DC -p "${COMPOSE_PROJECT}" down -v >/dev/null
    if [[ "$REPL_FLAG" -eq 1 && -n "${SCALE_ARGS}" ]]; then
      $DC -p "${COMPOSE_PROJECT}" -f docker-compose.yml -f "$OVERRIDE" up -d ${SCALE_ARGS} >/dev/null
    else
      $DC -p "${COMPOSE_PROJECT}" -f docker-compose.yml -f "$OVERRIDE" up -d >/dev/null
    fi
  )
  echo "[Round $round] stack restarted."

  ((rounds++)) || true
  ((total_sum+=total)) || true
  ((error_sum+=errors)) || true

  # Optional diagnostic capture
  if [[ "$round" -eq 47 ]]; then
    echo "[Round $round] Capturing docker compose logs (all services)..."
    (
      cd "${DSB_DIR}/${APP_DIR}"
      $DC -p "${COMPOSE_PROJECT}" logs > "${OUTDIR}/docker_logs_round_${round}.txt" 2>&1 || true
    )
  fi
done

echo "done, aggregating results..."

# ─── Aggregate R_live ────────────────────────────────────────────────────
python3 - "$rounds" "$error_sum" "$total_sum" "${OUTDIR}/summary.json" <<'PY'
import json, sys
r, err, tot, path = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
R = 0.0 if tot == 0 else 1.0 - (err / float(tot))
with open(path, "w") as f:
    json.dump({"rounds": r, "R_live": round(R, 5)}, f, indent=2)
print(f"*** Mean R_live over {r} rounds: {R:.4f}")
PY

echo "done. Results written to ${OUTDIR}/summary.json"
exit 0
