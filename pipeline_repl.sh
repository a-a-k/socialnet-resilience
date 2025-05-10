#!/usr/bin/env bash
set -e

if [ ! -d venv ]; then
  echo "🔧  creating venv ..."
  python3 -m venv venv
  ./venv/bin/pip install -q --upgrade pip
  ./venv/bin/pip install -q networkx numpy aiohttp scipy
fi

source ./venv/bin/activate
echo "✅  venv activated ($(python -V))"

./01_prepare_env.sh
./04_steady_repl.sh
./chaos.sh --repl

echo "==> summary_repl.json ready"
cat DeathStarBench/socialNetwork/results/repl/summary.json
