#!/usr/bin/env bash
set -euo pipefail

failures=0

ok() {
  echo "[OK] $1"
}

fail() {
  echo "[FAIL] $1"
  if [ $# -gt 1 ]; then
    echo "$2"
  fi
  failures=$((failures + 1))
}

echo "Preflight checks:"

python3_ok=0
if command -v python3 >/dev/null 2>&1; then
  ok "python3"
  python3_ok=1
else
  fail "python3 not found in PATH" "Install Python 3 and ensure python3 is in PATH."
fi

if [ "$python3_ok" -eq 1 ]; then
  missing_deps=""
  if ! missing_deps="$(python3 - <<'PY'
import importlib
import sys

missing = []
for name in ("numpy", "networkx", "scipy"):
    try:
        importlib.import_module(name)
    except Exception:
        missing.append(name)

sys.stdout.write(" ".join(missing))
PY
  )"; then
    fail "Python deps check failed" "pip install numpy networkx scipy"
  elif [ -n "$missing_deps" ]; then
    fail "Missing Python deps: $missing_deps" "pip install numpy networkx scipy"
  else
    ok "python deps (numpy, networkx, scipy)"
  fi
else
  fail "python deps (numpy, networkx, scipy) not checked: python3 missing" \
    "Install Python 3 first."
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker CLI and daemon"
  else
    fail "docker daemon not reachable" "Start Docker and retry (e.g., Docker Desktop)."
  fi
else
  fail "docker not found in PATH" "Install Docker and ensure docker is in PATH."
fi

compose_ok=0
if command -v docker >/dev/null 2>&1; then
  if docker compose version >/dev/null 2>&1; then
    compose_ok=1
  fi
fi
if [ "$compose_ok" -eq 0 ] && command -v docker-compose >/dev/null 2>&1; then
  if docker-compose --version >/dev/null 2>&1; then
    compose_ok=1
  fi
fi
if [ "$compose_ok" -eq 1 ]; then
  ok "docker compose"
else
  fail "docker compose not found" "Install Docker Compose (docker compose or docker-compose)."
fi

if command -v jq >/dev/null 2>&1; then
  ok "jq"
else
  fail "jq not found in PATH" "Install jq."
fi

deathstar_base="${DEATHSTARBENCH_DIR:-./DeathStarBench}"
if [ -d "$deathstar_base/socialNetwork" ]; then
  ok "DeathStarBench socialNetwork dir ($deathstar_base/socialNetwork)"
else
  clone_cmd="git clone https://github.com/delimitrou/DeathStarBench.git \"$deathstar_base\""
  fail "DeathStarBench socialNetwork dir missing: $deathstar_base/socialNetwork" "$clone_cmd"
fi

if [ "$failures" -ne 0 ]; then
  echo "PREFLIGHT FAILED"
  exit 1
fi

echo "PREFLIGHT PASSED"
