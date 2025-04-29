#!/usr/bin/env bash
# Kill a given fraction of running Social-Network containers.
#   ./just_kill.sh 0.30   # ⇒ kill ≈30 % containers except the entrypoint one (nginx)
set -euo pipefail
ratio="${1:-0.30}"
ids=$(docker ps --filter "name=socialnetwork" -q)
total=$(echo "$ids" | wc -l)
[ "$total" -eq 0 ] && { echo "No containers found"; exit 1; }
kill_n=$(printf "%.0f" "$(echo "$ratio*$total" | bc -l)")
echo "⛔  Killing $kill_n of $total containers ($ratio)"
echo "$ids" | shuf | head -n "$kill_n" | xargs -r docker kill
