#!/usr/bin/env bash
set -e

if [ ! -d venv ]; then
  echo "🔧  creating venv ..."
  python3 -m venv venv
  ./venv/bin/pip install -q --upgrade pip
  ./venv/bin/pip install -q networkx numpy
fi

source ./venv/bin/activate
echo "✅  venv activated ($(python -V))"

./01_prepare_env.sh
./02_steady_norepl.sh
./03_chaos_norepl.sh
jq -s '.' results/*_base.json results/02_meta.json > results/summary_norepl.json
echo "==> summary_norepl.json ready"
