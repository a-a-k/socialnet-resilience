#!/usr/bin/env bash

echo "prepare_env.sh ..."

# One-time environment bootstrap
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")"; pwd)
mkdir -p results

### Clone benchmark
git clone https://github.com/delimitrou/DeathStarBench.git
cd DeathStarBench
cd socialNetwork

mkdir -p 00_helpers

### System packages (Ubuntu)
sudo apt-get update -qq
sudo apt-get install -y jq bc git python3-venv lua-socket luarocks python3-scipy python3-pip
sudo luarocks install luasocket

# Use pip to ensure Python packages are available for the default python3
sudo python3 -m pip install --upgrade pip
sudo python3 -m pip install numpy networkx scipy

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

### Helper scripts
cp ../../00_helpers/just_kill.sh 00_helpers/
cp ../../resilience.py          .
cp "$REPO_ROOT/overrides/socialnetwork-jaeger.override.yml" ./docker-compose.override.yml
cp ../../00_helpers/mixed-workload-5xx.lua wrk2/scripts/social-network/

### Build wrk2 load-generator

WRK2_DIR="$HOME/wrk2"
if [ ! -x "$WRK2_DIR/wrk" ]; then
  echo "[bootstrap] cloning & building wrk2..."
  git clone --depth 1 https://github.com/giltene/wrk2.git  "$WRK2_DIR"
  make -C "$WRK2_DIR"
fi

if [ ! -x /usr/local/bin/wrk ]; then
  sudo install -m 0755 "$WRK2_DIR/wrk" /usr/local/bin/wrk
  echo "[bootstrap] wrk2 installed ➜ $(command -v wrk)"
fi

echo "✅ Environment prepared"
