#!/usr/bin/env bash
set -euo pipefail

# Export Jaeger service dependency graph to a file.
# Usage: export_deps.sh --out <path> [--jaeger <url>] [--lookback-ms <ms>]
OUT=""
JAEGER="${JAEGER:-http://localhost:16686}"
LOOKBACK="${LOOKBACK_MS:-3600000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --jaeger) JAEGER="$2"; shift 2 ;;
    --lookback-ms) LOOKBACK="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "${OUT}" ]]; then
  echo "missing --out" >&2
  exit 2
fi

ts=$(($(date +%s%N)/1000000))
curl -s "${JAEGER}/api/dependencies?endTs=${ts}&lookback=${LOOKBACK}" -o "$OUT"
echo "[export_deps] wrote ${OUT}"
