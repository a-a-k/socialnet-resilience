#!/usr/bin/env bash
set -e

if [ ! -d venv ]; then
  echo "🔧  creating venv ..."
  python3 -m venv venv
  ./venv/bin/pip install -q --upgrade pip
  ./venv/bin/pip install -q networkx numpy aiohttp
fi

source ./venv/bin/activate
echo "✅  venv activated ($(python -V))"

./01_prepare_env.sh
./02_steady_norepl.sh
SCALE_ARGS="" OUTDIR=DeathStarBench/socialNetwork/results/norepl ./chaos.sh 

jq -s '.' DeathStarBench/socialNetwork/results/*_base.json \
          DeathStarBench/socialNetwork/results/02_meta.json \
          DeathStarBench/socialNetwork/results/norepl/chaos_runs.json \
        > DeathStarBench/socialNetwork/results/summary_norepl.json
        
echo "==> summary_norepl.json ready"
