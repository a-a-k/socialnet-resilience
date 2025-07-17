#!/usr/bin/env bash

echo "prepare_env.sh for hotel-reservation ..."

# One-time environment bootstrap
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")"; pwd)
mkdir -p results

### Clone benchmark
if [ ! -d "DeathStarBench" ]; then
  echo "[bootstrap] Cloning DeathStarBench..."
  git clone https://github.com/delimitrou/DeathStarBench.git > /dev/null 2>&1
else
  echo "[bootstrap] DeathStarBench already exists, skipping clone..."
fi
cd DeathStarBench
cd hotelReservation

### System packages (Ubuntu)
sudo apt-get update -qq
sudo apt-get install -y jq bc git python3-venv lua-socket luarocks python3-scipy python3-pip > /dev/null 2>&1
sudo luarocks install luasocket > /dev/null 2>&1

# Use pip to ensure Python packages are available for the default python3
sudo python3 -m pip install --upgrade pip > /dev/null 2>&1
sudo python3 -m pip install numpy networkx scipy > /dev/null 2>&1

### Install Docker CE
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
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1
fi

### Install kubectl
if ! command -v kubectl >/dev/null; then
  echo "[bootstrap] Installing kubectl..."
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
fi

### Install minikube
if ! command -v minikube >/dev/null; then
  echo "[bootstrap] Installing minikube..."
  curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  sudo install minikube-linux-amd64 /usr/local/bin/minikube
  rm minikube-linux-amd64
fi

### Start minikube
echo "[bootstrap] Starting minikube..."
minikube start --driver=docker --memory=8192 --cpus=4

### Enable minikube addons
echo "[bootstrap] Enabling minikube addons..."
minikube addons enable ingress
minikube addons enable metrics-server

### Helper scripts
echo "[bootstrap] Copying hotel-resilience.py helper script..."
if [ -f "../hotel-resilience.py" ]; then
  cp ../hotel-resilience.py .
  echo "[bootstrap] ✓ hotel-resilience.py copied successfully"
else
  echo "[bootstrap] ✗ Error: hotel-resilience.py not found at ../hotel-resilience.py"
  exit 1
fi

### Update Kubernetes deployments with our overrides
echo "[bootstrap] Updating Kubernetes deployments..."

# Copy our overridden deployment files
OVERRIDES_PATH="../../../overrides/kubernetes-overrides"
if [ -d "$OVERRIDES_PATH" ]; then
  cp -r "$OVERRIDES_PATH"/* ./kubernetes/
  echo "[bootstrap] ✓ Kubernetes overrides copied successfully"
else
  echo "[bootstrap] ✗ Error: kubernetes-overrides not found at $OVERRIDES_PATH"
  exit 1
fi

### Build Docker images for hotel reservation
echo "[bootstrap] Building hotel reservation Docker images..."
if [ -f "kubernetes/scripts/build-docker-images.sh" ]; then
  chmod +x kubernetes/scripts/build-docker-images.sh
  ./kubernetes/scripts/build-docker-images.sh
  echo "[bootstrap] ✓ Docker images built successfully"
else
  echo "[bootstrap] ⚠️ Warning: build-docker-images.sh not found, assuming images exist"
fi

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

echo "✅ Environment prepared for hotel-reservation with Kubernetes" 