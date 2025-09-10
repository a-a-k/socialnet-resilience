#!/usr/bin/env bash
set -euo pipefail
APP="${APP:-${1:-social-network}}"

./01_prepare_env_multi.sh "$APP"
./02_steady_norepl_multi.sh "$APP"
./chaos_multi.sh --app "$APP" --repl 0 -o "results/${APP}/norepl"

jq -n \
  --arg m "$(jq .R_avg  "results/${APP}/norepl/R_avg_base.json")" \
  --arg l "$(jq .R_live "results/${APP}/norepl/summary.json")" \
  '{R_model_norepl: ($m|tonumber), R_live_norepl: ($l|tonumber)}' \
  > "results/${APP}/summary_norepl.json"
