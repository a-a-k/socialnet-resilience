#!/usr/bin/env bash
# One-time environment bootstrap.
set -euo pipefail
mkdir -p results 00_helpers

### 1. Clone benchmark
[ -d DeathStarBench ] || git clone https://github.com/delimitrou/DeathStarBench.git
cd DeathStarBench/socialNetwork

### 2. System packages (Ubuntu)
sudo apt-get update -qq
sudo apt-get install -y docker.io docker-compose jq bc git python3-venv

### 3. Python venv
python3 -m venv venv
source venv/bin/activate
pip install -q --upgrade pip
pip install -q networkx numpy

### 4. Helper scripts
cp ../../00_helpers/just_kill.sh 00_helpers/
cp ../../resilience.py          .

echo "✅ Environment prepared"
