#!/usr/bin/env bash

echo "prepare_env.sh ..."

# One-time environment bootstrap.
set -euo pipefail
mkdir -p results

### 1. Clone benchmark (only socialNetwork for breavity)
git clone --depth 1 --filter=blob:none \
          --sparse https://github.com/delimitrou/DeathStarBench.git
cd DeathStarBench
git sparse-checkout set socialNetwork
cd socialNetwork

mkdir -p 00_helpers

### 2. System packages (Ubuntu)
sudo apt-get update -qq
sudo apt-get install -y jq bc git python3-venv

if ! command -v docker >/dev/null; then
  echo "[bootstrap] Installing Docker CE…"
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
     | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
   "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

### 3. Python venv
python3 -m venv venv
source venv/bin/activate
pip install -q --upgrade pip
pip install -q networkx numpy

### 4. Helper scripts
cp ../../00_helpers/just_kill.sh 00_helpers/
cp ../../resilience.py          .

### 5. Build wrk2 load-generator

WRK2_DIR="$HOME/wrk2"
if [ ! -x "$WRK2_DIR/wrk" ]; then
  echo "[bootstrap] cloning & building wrk2..."
  git clone --depth 1 https://github.com/giltene/wrk2.git  "$WRK2_DIR"
  make -C "$WRK2_DIR"
fi

export PATH="$WRK2_DIR:$PATH"
echo "[bootstrap] wrk2 ready: $(command -v wrk)"

echo "✅ Environment prepared"
