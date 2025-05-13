[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.15332250.svg)](https://doi.org/10.5281/zenodo.15332250)

# Social-Network Resilience

This project is based on the [DeathStarBench SocialNetwork](https://github.com/delimitrou/DeathStarBench/tree/master/socialNetwork) benchmark, adapting its workload and service graph for resilience analysis.

This repository implements both theoretical and empirical evaluation of the resilience of a social-network microservices application under container failures. It includes:

* **resilience.py**: Monte Carlo simulation of service outages using sampling without replacement.
* **chaos.sh**: Script for injecting failures (killing containers) and measuring live request success rate.
* **pipeline\_norepl.sh** / **pipeline\_repl.sh**: Combined workflows for scenarios without and with replicas.
* **results**: Directory containing JSON summaries (`summary_norepl.json`, `summary_repl.json`).

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Setup](#setup)
3. [Dependency Graph](#dependency-graph)
4. [Theoretical Model (resilience.py)](#theoretical-model-resiliencepy)
5. [Empirical Test (chaos.sh)](#empirical-test-chaossh)
6. [Pipeline Workflows](#pipeline-workflows)
7. [Results](#results)
8. [CI Integration](#ci-integration)
9. [License](#license)

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

## Setup

1. **Clone this repository**:

   ```bash
   git clone https://github.com/a-a-k/socialnet-resilience.git
   cd socialnet-resilience
   ```

2. **Create & activate a virtual environment**:

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

## Dependency Graph

All service dependencies are defined in `deps.json` (Jaeger trace).
The graph is loaded by `resilience.py` via NetworkX:

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
python3 resilience.py deps.json \
  --samples 900000 \
  --p_fail 0.30 \
  [--repl 0|1] \
  -o results/R_model_{repl|norepl}.json
```

* `--repl`: enable replica counts (uses `replicas` map).
* Output JSON fields:

  * `R_avg`: weighted average availability.
  * `R_ep`: per-endpoint availability.

---

## Empirical Test (`chaos.sh`)

Docker Compose–based chaos experiment: kills a fraction of containers and measures successful HTTP requests.

**Usage:**

```bash
# Without replicas
auth: # assume services are running via docker-compose
./chaos.sh --repl 0 -o results/summary_norepl.json

# With replicas
auth:
./chaos.sh --repl 1 -o results/summary_repl.json
```

* Output JSON field:

  * `R_live`: observed success rate.

---

## Pipeline Workflows

Two separate pipelines collect theoretical and empirical results into a single summary file each.

### `pipeline_norepl.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Prepare environment
./01_prepare_env.sh
tests: ./02_steady_norepl.sh
./chaos.sh --repl 0

# Combine summaries
jq -n \
  --arg m "$(jq .R_avg  results/norepl/R_avg_base.json)" \
  --arg l "$(jq .R_live results/norepl/summary.json)" \
  '{R_model_norepl: ($m|tonumber), R_live_norepl: ($l|tonumber)}' \
  > results/summary_norepl.json
```

### `pipeline_repl.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Prepare environment
./01_prepare_env.sh
./04_steady_repl.sh --repl 1
./chaos.sh --repl 1

# Combine summaries
jq -n \
  --arg m "$(jq .R_avg  results/repl/R_avg_repl.json)" \
  --arg l "$(jq .R_live results/repl/summary.json)" \
  '{R_model_repl: ($m|tonumber), R_live_repl: ($l|tonumber)}' \
  > results/summary_repl.json
```

Each pipeline writes its combined summary to `results/summary_{norepl,repl}.json`.

---

## Results

After running a pipeline, inspect the combined summary:

```bash
cat results/summary_norepl.json
# {
#   "R_model_norepl": 0.179,
#   "R_live_norepl": 0.193
# }
```

Actual results for v1.0.0 release:


[![v1.0.0 Artifact (norepl)](https://img.shields.io/badge/Artifact-v1.0.0-blue)](https://github.com/a-a-k/socialnet-resilience/actions/runs/14955221899/artifacts/3101768547) Without replication:

```
{
  "R_model_norepl": 0.161,
  "R_live_norepl": 0.1845
}
```

[![v1.0.0 Artifact (repl)](https://img.shields.io/badge/Artifact-v1.0.0-blue)](https://github.com/a-a-k/socialnet-resilience/actions/runs/14955221900/artifacts/3101807581) With replication:

```
{
  "R_model_repl": 0.305,
  "R_live_repl": 0.3046
}
```

---

## CI Integration

In GitHub Actions, upload summaries as artifacts:

```yaml
- name: Run pipelines
  run: |
    ./pipeline_norepl.sh
    ./pipeline_repl.sh

- name: Upload summaries
  uses: actions/upload-artifact@v3
  with:
    name: resilience-results
    path: results/summary_*.json
```

---

## License

MIT License. See [LICENSE](./LICENSE) for details.

