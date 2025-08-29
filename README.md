# SocialNet Resilience (DeathStarBench)

Reproducible resilience experiments on **three** DeathStarBench (DSB) apps:

* **Social Network**
* **Media Service**
* **Hotel Reservation**

This repo measures resilience both **theoretically** (model on the live service graph) and **empirically** (chaos + 5xx/error‑aware workloads). Key properties:

* **Pinned DSB submodule** at `third_party/DeathStarBench` for reproducibility.
* **Multi‑app** entrypoints that don’t break your original single‑app flow.
* **Dynamic** dependency graph exported from **Jaeger** (`/api/dependencies`) at run time — no static deps are checked in.
* **Priming** per app (SN + Media) before workloads are driven.

---

## Requirements

* Docker & Docker Compose
* Bash, `jq`
* Python 3.8+ with:

  ```bash
  python3 -m pip install --upgrade pip
  pip install networkx numpy scipy
  ```

---

## Clone (with submodules)

```bash
git clone --recurse-submodules https://github.com/a-a-k/socialnet-resilience.git
cd socialnet-resilience
# If you forgot --recurse-submodules:
git submodule update --init --recursive
```

> The DSB code lives under `third_party/DeathStarBench` and is **pinned** to the SHA recorded in `third_party/DeathStarBench.COMMIT`. This keeps runs reproducible.

---

## Quick start (multi‑app pipelines)

Each app has a small JSON config in `apps/<app>/config.json` that declares:

* the **frontend URL** to hit,
* which **wrk2 script** to use,
* a stable **compose project** name, and
* (optionally) a **replica scale map** under `apps/<app>/replicas.json`.

Run any app end‑to‑end:

```bash
# Social Network
./pipeline_norepl_multi.sh social-network
./pipeline_repl_multi.sh  social-network

# Media Service
./pipeline_norepl_multi.sh media-service
./pipeline_repl_multi.sh  media-service

# Hotel Reservation
./pipeline_norepl_multi.sh hotel-reservation
./pipeline_repl_multi.sh  hotel-reservation
```

Where results land:

```
results/<app>/norepl/{wrk.txt, deps.json, R_avg_base.json, summary.json}
results/<app>/repl/{  wrk.txt, deps.json, R_avg_repl.json, summary.json}
results/<app>/summary_{norepl|repl}.json
```

---

## What the pipelines do

### 1) Prepare environment & prime data — `01_prepare_env_multi.sh`

* Ensures the DSB submodule is present and builds **wrk2** if needed.
* Starts the chosen app with a stable Compose project (`-p dsb-<app>`).
* **Priming (idempotent):**

  * **Social Network** – runs `scripts/init_social_graph.py` to register users + construct the social graph (required upstream).
  * **Media Service** – runs `scripts/write_movie_info.py` and `scripts/register_users.sh` if TMDB JSONs exist in `mediaMicroservices/datasets/tmdb`.
  * **Hotel Reservation** – no explicit seeding (works out‑of‑box).

> Social Network uses your existing workload at `00_helpers/mixed-workload-5xx.lua`. We do **not** introduce another copy; the script is just installed into the submodule’s `wrk2/scripts/social-network/` path for execution.

### 2) Steady‑state workload + model — `02_steady_norepl_multi.sh` / `04_steady_repl_multi.sh`

* Drives wrk2 using the configured Lua script.
* **Exports the live service graph** from Jaeger Query (`/api/dependencies?endTs=…&lookback=…`) into `results/<app>/<mode>/deps.json`.
* Calls `resilience.py` on that **live** graph to compute the theoretical baseline:

  * `results/<app>/norepl/R_avg_base.json` (no replication)
  * `results/<app>/repl/R_avg_repl.json` (replicated)
* In `repl` mode, scales services using `apps/<app>/replicas.json` if present (Social Network is prefilled; Media/Hotel default to 1× unless you add entries).

### 3) Chaos — `chaos_multi.sh`

* Randomly kills ≈`P_FAIL` of containers **scoped to the app’s compose project** label.
* Drives the same wrk2 workload and computes:

  ```
  R_live = 1 - (Non-2xx/3xx responses + socket errors) / total
  ```

  This works across apps without depending on app‑specific Lua hooks.

### 4) Summaries

* `results/<app>/summary_norepl.json` contains `{ R_model_norepl, R_live_norepl }`.
* `results/<app>/summary_repl.json` contains `{ R_model_repl,  R_live_repl  }`.

---

## App configuration (overview)

`apps/<app>/config.json` fields:

```json
{
  "name": "social-network",
  "front_url": "http://localhost:8080/index.html",
  "wrk2": {
    "script": "third_party/DeathStarBench/wrk2/scripts/social-network/mixed-workload-5xx.lua",
    "threads": 2,
    "connections": 64,
    "duration": "30s",
    "rate": 300
  },
  "compose_project": "dsb-social-network",
  "replicas_file": "apps/social-network/replicas.json"
}
```

* **front\_url** – complete URL used by wrk2.
* **wrk2.script** – path inside the submodule; for Social Network we point to **your** `mixed-workload-5xx.lua` (placed there by the prepare step).
* **compose\_project** – stable name used by Compose and by `chaos_multi.sh` to scope victim selection.
* **replicas\_file** (optional) – a JSON map of service→replicas for the replicated scenario.

---

## Dynamic dependency graph (Jaeger)

We **do not** check in static service graphs. Each run exports the current dependency graph from Jaeger Query:

```
GET http://localhost:16686/api/dependencies?endTs=<ms_since_epoch>&lookback=<ms>
```

The export goes to `results/<app>/<mode>/deps.json` and is fed to `resilience.py` immediately after steady‑state load.

> If your Jaeger is at a different URL/port, set `JAEGER=http://host:port` before running `*_multi.sh` scripts (they call `00_helpers/export_deps.sh` under the hood).

---

## Reproducibility

* `third_party/DeathStarBench/` is a **git submodule**, pinned to the exact SHA recorded in `third_party/DeathStarBench.COMMIT`.
* Always clone with `--recurse-submodules` or run:

  ```bash
  git submodule update --init --recursive
  ```
* You can deliberately update to a newer upstream commit later (normal submodule workflow).

---

## Advanced

* **Customizing wrk2 parameters:** edit `apps/<app>/config.json` (`threads`, `connections`, `duration`, `rate`).
* **Scaling in `repl` mode:** add entries to `apps/<app>/replicas.json`, e.g. for Social Network:

  ```json
  {
    "default": 1,
    "compose-post-service": 3,
    "home-timeline-service": 3,
    "user-timeline-service": 3,
    "text-service": 3,
    "media-service": 3
  }
  ```
* **Legacy single‑app scripts:** your original `pipeline_norepl.sh`, `pipeline_repl.sh`, `chaos.sh` remain untouched and usable for the Social Network–only flow.

---

## Troubleshooting

* **“Submodule folder looks empty”** – initialize it:

  ```bash
  git submodule update --init --recursive
  ```
* **Jaeger deps export is empty** – make sure the app has handled some requests first; the steady‑state step runs wrk2, so run the pipelines in order.
* **Windows (CRLF)** – if you edit shell scripts on Windows, ensure LF endings and executable bit are preserved.

---

## License

MIT — see [LICENSE](./LICENSE).

---

**Notes**

* Social Network priming uses `scripts/init_social_graph.py` (upstream‑recommended) before any load is applied.
* Media Service priming uses `scripts/write_movie_info.py` and `scripts/register_users.sh` if `datasets/tmdb/{casts.json,movies.json}` are available.
* Hotel Reservation runs out‑of‑the‑box without explicit seeding in most setups. If you add seeding scripts later, the prepare step can call them idempotently.
