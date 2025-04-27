#!/usr/bin/env bash
set -e
./01_prepare_env.sh
./04_steady_repl.sh
./05_chaos_repl.sh
jq -s '.' results/*_repl.json results/04_meta.json > results/summary_repl.json
echo "==> summary_repl.json ready"
