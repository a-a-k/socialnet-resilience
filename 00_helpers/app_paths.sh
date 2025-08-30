#!/usr/bin/env bash
set -euo pipefail

# Map app slugs to upstream DSB directories
app_dir_for() {
  case "${1:-}" in
    social-network)    echo "socialNetwork" ;;
    media-service)     echo "mediaMicroservices" ;;
    hotel-reservation) echo "hotelReservation" ;;
    *) echo "unknown"; return 1 ;;
  esac
}

# docker compose wrapper (supports both v1 and v2 CLIs)
compose_cmd() {
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo "docker compose"
  fi
}

override_for() {
  case "${1:-}" in
    social-network)    echo "overrides/sn-jaeger.override.yml" ;;
    media-service)     echo "overrides/ms-jaeger.override.yml" ;;
    hotel-reservation) echo "overrides/hr-jaeger.override.yml" ;;
    *) echo ""; return 1 ;;
  esac
}
