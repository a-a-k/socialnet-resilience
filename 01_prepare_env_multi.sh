#!/usr/bin/env bash
set -euo pipefail

APP="${APP:-${1:-social-network}}"
CFG="apps/${APP}/config.json"

FRONT_URL="$(jq -r '.front_url' "$CFG")"
COMPOSE_PROJECT="$(jq -r '.compose_project' "$CFG")"

git submodule update --init --recursive
echo "[prepare] DSB pinned to $(tr -d ' \n' < third_party/DeathStarBench.COMMIT)"

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

# Start the selected app with a stable compose project
source 00_helpers/app_paths.sh
APP_DIR="$(app_dir_for "$APP")"
DC="$(compose_cmd)"
echo "[prepare] starting ${APP} (${APP_DIR}) project=${COMPOSE_PROJECT}"
(
  cd "third_party/DeathStarBench/${APP_DIR}"
  $DC -p "${COMPOSE_PROJECT}" up -d
)

# --------- Priming per app (idempotent) ---------
case "$APP" in
  social-network)
    echo "[prime] social-network: init_social_graph.py"
    (
      cd third_party/DeathStarBench/socialNetwork
      # Upstream docs require this step to register users and build the graph. :contentReference[oaicite:2]{index=2}
      python3 scripts/init_social_graph.py --graph socfb-Reed98 --compose --ip 127.0.0.1 --port 8080
    )
    ;;
  media-service)
    echo "[prime] media-service: write_movie_info + register_users (if TMDB JSONs exist)"
    (
      cd third_party/DeathStarBench/mediaMicroservices
      # Many DSB guides instruct to run these before load. :contentReference[oaicite:3]{index=3}
      if [[ -f datasets/tmdb/casts.json && -f datasets/tmdb/movies.json ]]; then
        python3 scripts/write_movie_info.py \
          -c datasets/tmdb/casts.json \
          -m datasets/tmdb/movies.json \
          --server_address "127.0.0.1:8080"
        bash scripts/register_users.sh
      else
        echo "[prime] TMDB dataset missing—skipping (safe)."
      fi
    )
    ;;
  hotel-reservation)
    echo "[prime] hotel-reservation: no explicit seeding required (works OOTB)"
    ;;
esac

echo "[prepare] ready at ${FRONT_URL}"
