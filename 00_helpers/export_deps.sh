#!/usr/bin/env bash
set -euo pipefail

# Usage: ./00_helpers/export_deps.sh --out results/<app>/<mode>/deps.json [--jaeger http://localhost:16686] [--lookback 3600000] [--retries 12] [--sleep 5]
OUT=""
JAEGER="${JAEGER:-http://localhost:16686}"
LOOKBACK="${LOOKBACK:-3600000}"   # 1h
RETRIES="${RETRIES:-12}"          # ~ 1 minute total с задержкой 5s
SLEEP_SEC="${SLEEP_SEC:-5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --jaeger) JAEGER="$2"; shift 2 ;;
    --lookback) LOOKBACK="$2"; shift 2 ;;
    --retries) RETRIES="$2"; shift 2 ;;
    --sleep) SLEEP_SEC="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$OUT" ]]; then
  echo "[export_deps] --out is required" >&2
  exit 2
fi
mkdir -p "$(dirname "$OUT")"

endTs=$(($(date +%s%N)/1000000))

# пробуем несколько раз, пока в 'data' не появятся рёбра
for i in $(seq 1 "$RETRIES"); do
  curl -fsS "${JAEGER}/api/dependencies?endTs=${endTs}&lookback=${LOOKBACK}" -o "$OUT" || true
  if jq -e '.data | length > 0' <"$OUT" >/dev/null 2>&1; then
    echo "[export_deps] wrote ${OUT} ($(jq '.data | length' "$OUT") edges)"
    exit 0
  fi
  echo "[export_deps] deps empty (try $i/${RETRIES}); waiting ${SLEEP_SEC}s..."
  sleep "$SLEEP_SEC"
done

echo "[export_deps] ERROR: deps.json is still empty after retries. Make sure traces are reaching Jaeger." >&2
exit 1
