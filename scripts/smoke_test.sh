#!/usr/bin/env bash
set -euo pipefail

deps_path="${DEPS_JSON:-./deps.json}"
if [ ! -f "$deps_path" ]; then
  echo "Deps JSON not found: $deps_path" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found in PATH" >&2
  exit 1
fi

missing_deps="$(
  python3 - <<'PY'
import importlib
import sys

missing = []
for name in ("numpy", "networkx", "scipy"):
    try:
        importlib.import_module(name)
    except Exception:
        missing.append(name)

if missing:
    sys.stdout.write(" ".join(missing))
PY
)"

if [ -n "$missing_deps" ]; then
  echo "Missing deps: $missing_deps; install with: pip install numpy networkx scipy" >&2
  exit 1
fi

smoke_samples="${SMOKE_SAMPLES:-1000}"
smoke_p_fail="${SMOKE_P_FAIL:-0.30}"
if [ -n "${SMOKE_REPLS:-}" ]; then
  repl_list="$SMOKE_REPLS"
elif [ -n "${SMOKE_REPL:-}" ]; then
  repl_list="$SMOKE_REPL"
else
  repl_list="0 1"
fi

for smoke_repl in $repl_list; do
  if [ "$smoke_repl" = "1" ]; then
    mode_label="repl"
  else
    mode_label="no-repl"
  fi

  echo "Running mode: $mode_label (repl=$smoke_repl)"
  out_file="$(mktemp)"

  python3 resilience.py "$deps_path" \
    --samples "$smoke_samples" \
    --p_fail "$smoke_p_fail" \
    --repl "$smoke_repl" \
    -o "$out_file"

  validation_output="$(
    OUT_PATH="$out_file" \
    EXP_SAMPLES="$smoke_samples" \
    EXP_P_FAIL="$smoke_p_fail" \
    python3 - <<'PY'
import json
import os
import sys

def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)

out_path = os.environ["OUT_PATH"]
expected_samples = int(os.environ["EXP_SAMPLES"])
expected_p_fail = float(os.environ["EXP_P_FAIL"])

with open(out_path, "r", encoding="utf-8") as f:
    data = json.load(f)

if "R_avg" not in data or "R_ep" not in data:
    fail('Missing required keys: "R_avg" and/or "R_ep"')

r_avg = data["R_avg"]
if not isinstance(r_avg, (int, float)) or isinstance(r_avg, bool):
    fail("R_avg must be a number")
if r_avg < 0 or r_avg > 1:
    fail("R_avg out of range [0, 1]")

r_ep = data["R_ep"]
if not isinstance(r_ep, dict) or not r_ep:
    fail("R_ep must be a non-empty dict")
for key, value in r_ep.items():
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        fail(f"R_ep[{key!r}] must be a number")
    if value < 0 or value > 1:
        fail(f"R_ep[{key!r}] out of range [0, 1]")

if "samples" not in data:
    fail('Missing required key: "samples"')
if int(data["samples"]) != expected_samples:
    fail(f"samples mismatch: expected {expected_samples}, got {data['samples']}")

if "p_fail" not in data:
    fail('Missing required key: "p_fail"')
p_fail = float(data["p_fail"])
if abs(p_fail - expected_p_fail) > 1e-6:
    fail(f"p_fail mismatch: expected {expected_p_fail}, got {p_fail}")

keys = sorted(str(k) for k in r_ep.keys())
print(f"R_avg: {r_avg}")
print("Endpoints: " + ", ".join(keys))
PY
  )"

  echo "SMOKE TEST PASSED"
  echo "Mode: $mode_label (repl=$smoke_repl)"
  echo "Output: $out_file"
  echo "$validation_output"
done
