[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.15396047.svg)](https://doi.org/10.5281/zenodo.15396047)

# Social-Network Resilience

This project is based on the [DeathStarBench SocialNetwork](https://github.com/delimitrou/DeathStarBench/tree/master/socialNetwork) benchmark, adapting its workload and service graph for resilience analysis.

This repository implements both theoretical and empirical evaluation of the resilience of a social-network microservices application under container failures. It includes and organizes:

* **resilience.py**: Monte Carlo simulation of service outages using sampling without replacement.
* **chaos.sh**: Script for injecting failures (killing containers) and measuring live request success rate.
* **pipeline\_norepl.sh** / **pipeline\_repl.sh**: Combined workflows for scenarios without and with replicas.
* **results**: Generated under `DeathStarBench/socialNetwork/results/{norepl|repl}` (and variant subfolders for matrix runs), each containing `summary_*.json`.
* **helpers/mixed-workload-5xx.lua**: wrk2 script to surface status-code detail during chaos runs.
* **overrides/socialnetwork-jaeger.override.yml**: docker-compose override enabling Jaeger tracing for dependency capture.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Setup & Local Reproduction](#setup--local-reproduction)
3. [Repository Layout](#repository-layout)
4. [Dependency Graph](#dependency-graph)
5. [Theoretical Model (resilience.py)](#theoretical-model-resiliencepy)
6. [Empirical Test (chaos.sh)](#empirical-test-chaossh)
7. [Pipeline Workflows](#pipeline-workflows)
8. [Outputs & Reuse](#outputs--reuse)
9. [CI / GitHub Actions](#ci--github-actions)
10. [Citation](#citation)
11. [License](#license)

---

## Prerequisites

* **Python 3.8+**
* **Bash** (Unix-like environment)
* **Docker & Docker Compose**
* **jq** (JSON processor)

Recommended Python packages (installed via `pip`):

```bash
pip install networkx numpy scipy
```

`jq` may be installed via your OS package manager (e.g., `apt install jq`).

---

## Setup & Local Reproduction

End-to-end steps to run locally (Docker daemon required):

1. **Clone this repository**:

   ```bash
   git clone https://github.com/a-a-k/socialnet-resilience.git
   cd socialnet-resilience
   ```

2. **(Optional) Create & activate a virtual environment** for local tooling:

   ```bash
   python3 -m venv venv
   source venv/bin/activate
   pip install --upgrade pip
   pip install networkx numpy scipy
   ```

3. **Ensure `jq` is available**:

   ```bash
   jq --version
   ```

4. **Run the pipelines** (they will call `prepare_env.sh` automatically, which may prompt for `sudo` to install system deps and clone DeathStarBench):

   ```bash
   # Non-replica pipeline (writes to DeathStarBench/socialNetwork/results/norepl)
   ./pipeline_norepl.sh

   # Replica pipeline (writes to DeathStarBench/socialNetwork/results/repl)
   ./pipeline_repl.sh
   ```

   If you prefer to preinstall everything to avoid prompts mid-run, run `./prepare_env.sh` once before the pipelines.

Optional tunables (affect both pipelines): `SEED`, `P_FAIL` (model failure probability), `FAIL_FRACTION` (fraction of containers killed per chaos round), and `OUTDIR` (artifact destination).

---

## Repository Layout

```
README.md                      # This guide
resilience.py                  # Theoretical Monte Carlo model
chaos.sh                       # Chaos experiment driver (wrk2 + random kills)
steady_norepl.sh               # Steady-state prep + deps.json capture (no replicas)
steady_repl.sh                 # Steady-state prep + deps.json capture (with replicas)
pipeline_norepl.sh             # End-to-end non-replica pipeline
pipeline_repl.sh               # End-to-end replica pipeline
prepare_env.sh                 # Bootstrap DeathStarBench, system deps, wrk2
helpers/mixed-workload-5xx.lua # wrk2 script used during chaos runs
overrides/socialnetwork-jaeger.override.yml # Compose override enabling Jaeger tracing
```

## Dependency Graph

Service dependencies are pulled from Jaeger into `DeathStarBench/socialNetwork/deps.json` by `steady_norepl.sh` / `steady_repl.sh` (or you can fetch it yourself). The graph is loaded by `resilience.py` via NetworkX:

```python
with open('deps.json') as f:
    data = json.load(f)['data']
G = nx.DiGraph((e['parent'], e['child']) for e in data)
```

---

## Theoretical Model (`resilience.py`)

Monte Carlo simulation of container failures without replacement.

**Usage:**

```bash
python3 resilience.py DeathStarBench/socialNetwork/deps.json \
  --samples 500000 \
  --p_fail 0.30 \
  [--repl 1] \
  -o DeathStarBench/socialNetwork/results/norepl/R_avg_base.json
```

* `--repl 1`: enable replica counts (uses the `replicas` map). Omit for the non-replica case.
* `--samples`: defaults to 500000; increase for tighter estimates.
* `--seed`: defaults to 16 for reproducibility.
* Output JSON fields:

  * `R_avg`: weighted average availability.
  * `R_ep`: per-endpoint availability.

---

## Empirical Test (`chaos.sh`)

Docker Compose–based chaos experiment: kills a fraction of containers and measures successful HTTP requests. The script changes into `DeathStarBench/socialNetwork/` and expects that stack to be available (via `prepare_env.sh`).

**Usage:**

```bash
# Without replicas (default)
OUTDIR=DeathStarBench/socialNetwork/results/norepl ./chaos.sh

# With replicas (flag only; no numeric arg)
OUTDIR=DeathStarBench/socialNetwork/results/repl ./chaos.sh --repl
```

* Output: `${OUTDIR}/summary.json` containing `R_live`.
* Default `OUTDIR` (if unset) is `results/{mode}` relative to `DeathStarBench/socialNetwork/`; pipelines set it explicitly.
* `FAIL_FRACTION`, `ROUNDS`, `RATE`, and other tunables can be set via environment variables.

---

## Pipeline Workflows

Two separate pipelines collect theoretical and empirical results into a single summary file each.

Shared behavior:

* Creates a local Python venv (numpy, networkx, scipy, aiohttp) if absent.
* Calls `prepare_env.sh`, which clones and prepares `DeathStarBench/socialNetwork`.
* Propagates `SEED`, `P_FAIL`, and `FAIL_FRACTION` to both the steady-state capture and chaos phases.
* `OUTDIR` controls where artifacts are written; defaults differ by mode.

### `pipeline_norepl.sh`

Runs the non-replica scenario end-to-end. Key steps:

```bash
# creates venv with numpy/networkx/scipy, then bootstraps DeathStarBench
./pipeline_norepl.sh

# Internals (defaults):
# - OUTDIR=DeathStarBench/socialNetwork/results/norepl
# - steady_norepl.sh fetches deps.json and writes R_avg_base.json
# - chaos.sh writes summary.json
# - combined summary at $OUTDIR/summary_norepl.json
```

### `pipeline_repl.sh`

Runs the replicated scenario (selected services scaled to 3 replicas):

```bash
./pipeline_repl.sh

# Internals (defaults):
# - OUTDIR=DeathStarBench/socialNetwork/results/repl
# - steady_repl.sh fetches deps.json and writes R_avg_repl.json
# - chaos.sh --repl writes summary.json
# - combined summary at $OUTDIR/summary_repl.json
```

Environment variables `SEED`, `P_FAIL`, and `FAIL_FRACTION` tune both pipelines.

---

## Outputs & Reuse

After running a pipeline, inspect the combined summary (example for non-repl default paths):

```bash
cat DeathStarBench/socialNetwork/results/norepl/summary_norepl.json
```

Key artifacts per scenario:

* `R_avg_base.json` / `R_avg_repl.json`: theoretical availability from `resilience.py`.
* `summary.json`: empirical success rate from `chaos.sh`.
* `summary_{norepl|repl}.json`: combined view produced by the pipelines.

Example raw results:

`R_avg_repl.json`:
```json
{"R_avg": 0.62807, 
  "R_ep": {
    "home-timeline": 0.62815, 
    "user-timeline": 0.73992, 
    "compose-post": 0.29208
  }, 
  "samples": 500000, 
  "p_fail": 0.1, 
  "seed": 9
}
```

`summary.json`:
```json
{
  "rounds": 450,
  "R_live": 0.55679
}
```

`summary_repl.json`:
```json
{
  "R_model_repl": 0.62807,
  "R_live_repl": 0.69885
}
```
Tips for reuse/repurposing:

* Point `resilience.py` at any Jaeger-style `deps.json`; adjust endpoint definitions and weights inside the script for new workloads.
* Swap the wrk2 script via `LUA=...` when calling `chaos.sh` to change the traffic mix.
* Override `OUTDIR` to route artifacts to a different location; pipelines propagate this to all sub-steps.
* Tweak replica counts in `chaos.sh` and the `replicas` map in `resilience.py` to match your service topology.

### Aggregate Results [![v1.0.0 Artifact](https://img.shields.io/badge/Artifact-v1.0.0_norepl-blue)](https://github.com/a-a-k/socialnet-resilience/actions/runs/14955221899/artifacts/3101768547) [![v1.0.0 Artifact](https://img.shields.io/badge/Artifact-v1.0.0_repl-blue)](https://github.com/a-a-k/socialnet-resilience/actions/runs/14955221900/artifacts/3101807581)

| Mode   | $p_{\mathit{fail}}$ | $R_{\text{model}}$ | $R_{\text{live}}$ |
| ------ | ------------------- | ------------------ | ----------------- |
| norepl | 0.1                 | 0.4182 ± 0.0005    | 0.5533 ± 0.0031   |
| norepl | 0.3                 | 0.1613 ± 0.0005    | 0.1775 ± 0.0021   |
| norepl | 0.5                 | 0.0454 ± 0.0002    | 0.0376 ± 0.0006   |
| norepl | 0.7                 | 0.0014 ± 0.0000    | 0.0067 ± 0.0000   |
| norepl | 0.9                 | 0.0000 ± 0.0000    | 0.0000 ± 0.0000   |
| repl   | 0.1                 | 0.6281 ± 0.0005    | 0.6969 ± 0.0026   |
| repl   | 0.3                 | 0.3054 ± 0.0007    | 0.3054 ± 0.0017   |
| repl   | 0.5                 | 0.1145 ± 0.0004    | 0.0958 ± 0.0011   |
| repl   | 0.7                 | 0.0132 ± 0.0001    | 0.0155 ± 0.0003   |
| repl   | 0.9                 | 0.0000 ± 0.0000    | 0.0000 ± 0.0000   |

---

## CI / GitHub Actions

Workflow file: `.github/workflows/resilience-matrix.yml` (manual `workflow_dispatch`).

How to run on GitHub:

1) Push your changes to a branch.
2) In GitHub → Actions → **Resilience-Matrix** → **Run workflow**, pick the branch and trigger.
3) The matrix runs both modes (`norepl`, `repl`) across `fail_fraction` ∈ {0.1,0.3,0.5,0.7,0.9} and seeds {1,2}.
4) Download artifacts named `${mode}-${fail_fraction}-seed${seed}`; each contains JSONs under `DeathStarBench/socialNetwork/results/${mode}-${fail_fraction}-${seed}`.

In GitHub Actions, the included workflow runs both pipelines across a matrix and uploads the results stored in `DeathStarBench/socialNetwork/results/...`:

* Workflow: `.github/workflows/resilience-matrix.yml`.
* Matrix dimensions: `mode` (norepl|repl), `fail_fraction` (0.1–0.9), `seed` (1,2).
* Per-job `OUTDIR`: `DeathStarBench/socialNetwork/results/${mode}-${fail_fraction}-${seed}`.

```yaml
- name: Run pipelines
  run: |
    ./pipeline_norepl.sh
    ./pipeline_repl.sh

- name: Upload summaries
  uses: actions/upload-artifact@v4
  with:
    path: "${{ env.OUTDIR }}/*.json"
```

---

## Citation

If you use this work, please cite:

```bibtex
@inproceedings{krasnovsky2026modeldiscovery,
  author    = {Anatoly A. Krasnovsky},
  title     = {Model Discovery and Graph Simulation: A Lightweight Gateway to Chaos Engineering},
  booktitle = {Proceedings of the 48th IEEE/ACM International Conference on Software Engineering: New Ideas and Emerging Results (ICSE-NIER '26)},
  year      = {2026},
  address   = {Rio de Janeiro, Brazil},
  publisher = {ACM},
  pages     = {5},
  #doi       = {10.1145/nnnnnnn.nnnnnnn} — to be updated
}
```

---

## License

MIT License. See [LICENSE](./LICENSE) for details.
