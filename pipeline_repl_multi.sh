#!/usr/bin/env bash
set -euo pipefail
APP="${APP:-${1:-social-network}}"

./01_prepare_env_multi.sh "$APP"
./04_steady_repl_multi.sh "$APP"
./chaos_multi.sh --app "$APP" --repl 1 -o "results/${APP}/repl/summary.json"

jq -n \
  --arg m "$(jq .R_avg  "results/${APP}/repl/R_avg_repl.json")" \
  --arg l "$(jq .R_live "results/${APP}/repl/summary.json")" \
  '{R_model_repl: ($m|tonumber), R_live_repl: ($l|tonumber)}' \
  > "results/${APP}/summary_repl.json"
