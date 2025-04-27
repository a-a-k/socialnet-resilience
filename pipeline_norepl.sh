#!/usr/bin/env bash
set -e
./01_prepare_env.sh
./02_steady_norepl.sh
./03_chaos_norepl.sh
jq -s '.' results/*_base.json results/02_meta.json > results/summary_norepl.json
echo "==> summary_norepl.json ready"
