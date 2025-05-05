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
./04_steady_repl.sh
./chaos.sh --repl

jq -s '.' DeathStarBench/socialNetwork/results/*_repl.json \
          DeathStarBench/socialNetwork/results/04_meta.json \
        > DeathStarBench/socialNetwork/results/summary_repl.json

echo "==> summary_repl.json ready"
