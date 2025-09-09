#!/usr/bin/env bash
set -euo pipefail

APP="${APP:-${1:-social-network}}"
CFG="apps/${APP}/config.json"
FRONT_URL="$(jq -r '.front_url' "$CFG")"

git submodule update --init --recursive
echo "[prepare] DSB pinned to $(tr -d ' \n' < third_party/DeathStarBench.COMMIT)"

sudo apt-get update -qq
sudo apt-get install -y jq bc git python3-venv lua-socket luarocks python3-scipy python3-pip > /dev/null 2>&1
sudo luarocks install luasocket > /dev/null 2>&1

# --- wrk2 engine install: $HOME/wrk2 -> /usr/local/bin/wrk ---
WRK2_DIR="${WRK2_DIR:-$HOME/wrk2}"
if [[ ! -x "$WRK2_DIR/wrk" ]]; then
  echo "[bootstrap] cloning & building wrk2..."
  git clone --depth 1 https://github.com/giltene/wrk2.git "$WRK2_DIR"
  make -C "$WRK2_DIR"
fi
if ! command -v wrk >/dev/null 2>&1; then
  sudo install -m 0755 "$WRK2_DIR/wrk" /usr/local/bin/wrk
  echo "[bootstrap] wrk2 installed -> $(command -v wrk)"
fi
# --------------------------------------------------------------

# Install your existing SN 5xx workload into the submodule (SN only)
if [[ "$APP" == "social-network" && -f "00_helpers/mixed-workload-5xx.lua" ]]; then
  install -D -m 0644 00_helpers/mixed-workload-5xx.lua \
    third_party/DeathStarBench/wrk2/scripts/social-network/mixed-workload-5xx.lua
fi

echo "[prepare] ready at ${FRONT_URL}"
