#!/usr/bin/env bash
set -u

DURATION=${DURATION:-30}
RATE=${RATE:-300}
THREADS=${THREADS:-2}
CONNS=${CONNS:-32}
URL=${URL:-http://localhost:8080/index.html}
LUA=${LUA:-wrk2/scripts/social-network/mixed-workload.lua}
LOG=${1:-wrk.log}

EXPECTED_TOTAL=$((DURATION * RATE))

wrk -t"$THREADS" -c"$CONNS" -d"${DURATION}s" -R"$RATE" \
    -s "$LUA" "$URL" >"$LOG" 2>&1 || true

if grep -q 'requests in' "$LOG"; then
    total=$(grep -Eo '[0-9]+ requests in' "$LOG"     | awk '{print $1}')
    errs=$(grep -Eo 'Non-2xx or 3xx responses:[[:space:]]*[0-9]+' "$LOG" \
           | awk '{print $NF}')
    : "${errs:=0}"
else
    total=$EXPECTED_TOTAL
    errs=$total
fi

jq -nc \
   --arg total "$total" \
   --arg errs  "$errs"  \
   '{total:($total|tonumber), errors:($errs|tonumber)}'
