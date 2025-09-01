#!/usr/bin/env python3
"""
Resilience index (R_avg) calculator.

Design goals (matches the release script’s behavior):
- Use an explicit, per-app endpoint catalog (endpoint -> required service set, weight).
- For Social-Network, reproduce the original “compose-post” extras logic
  (media/url-shortener/user-mention) to mirror the empirical workload mix.
- Respect --repl by reading apps/<app>/replicas.json and treating each service
  as a multi-replica pool (endpoint succeeds if at least one replica of every
  required service remains and the client has a path to each target).
- Fail fast on empty or degenerate Jaeger deps (no edges / no targets present)
  to avoid silent “always-1.0” outcomes from vacuous truth on empty sets.

Inputs:
  deps.json    — Jaeger dependencies graph (as produced by export_deps.sh)
  apps/<app>/config.json   — selects compose project and files
  apps/<app>/replicas.json — replica counts (used only when --repl=1)
"""

from __future__ import annotations

import argparse
import json
import math
import random
from collections import Counter
from pathlib import Path
from typing import Dict, List, Set, Tuple

import networkx as nx
import numpy as np


# ------------------------- CLI -------------------------

ap = argparse.ArgumentParser()
ap.add_argument("deps", help="Path to Jaeger deps.json")
ap.add_argument("-o", "--out", help="Write result JSON here")
ap.add_argument("--samples", type=int, default=500_000, help="Monte-Carlo samples")
ap.add_argument("--p_fail", type=float, default=0.30, help="Fraction of app containers to kill per round (0..1)")
ap.add_argument("--repl", type=int, choices=[0, 1], default=0, help="Use replicas.json (1) or single-instance (0)")
ap.add_argument("--seed", type=int, default=16, help="Base RNG seed")
ap.add_argument("--app", choices=["social-network", "media-service", "hotel-reservation"],
                default="social-network",
                help="Which DSB app profile to use")
ap.add_argument("--config", help="Explicit path to apps/<app>/config.json (overrides --app)")
args = ap.parse_args()

random.seed(args.seed)


# --------------------- Load deps.json -------------------

deps_path = Path(args.deps)
if not deps_path.exists():
    raise SystemExit(f"[resilience] deps.json not found: {deps_path}")

raw = json.loads(deps_path.read_text())

# Jaeger deps payload must have a non-empty "data" array of edges
edges = raw.get("data", [])
if not isinstance(edges, list) or len(edges) == 0:
    # Hard fail per requirement: stop the job loudly on empty deps
    raise SystemExit("[resilience] Jaeger deps.json has no edges ('data' is empty). "
                     "Make sure tracing captured calls before export.")

# Graph: nodes are service names; directed parent -> child
G = nx.DiGraph((e["parent"], e["child"]) for e in edges)
graph_nodes: Set[str] = set(G.nodes())


# --------------------- App config & replicas ---------------------

cfg_path = Path(args.config) if args.config else Path("apps") / args.app / "config.json"
cfg = json.loads(cfg_path.read_text())

replicas_path = Path(cfg["replicas_file"])
if replicas_path.exists():
    replicas_cfg: Dict[str, int] = {k: int(v) for k, v in json.loads(replicas_path.read_text()).items()}
else:
    replicas_cfg = {"default": 1}
default_rep = int(replicas_cfg.get("default", 1))


def rep_for(svc: str) -> int:
    return int(replicas_cfg.get(svc, default_rep)) if args.repl == 1 else 1


# --------------------- Explicit endpoint catalog ---------------------
# IMPORTANT: endpoints list *explicit* required services (not discovered dynamically),
# mirroring the release script style.

# Social-Network (client is nginx-web-server)
SN_ENDPOINTS: Dict[str, Tuple[Set[str], float]] = {
    # 60%: home-timeline (HT) path
    "home-timeline": (
        {
            # minimal set to serve HT
            "home-timeline-service",
            "post-storage-service",
            "user-timeline-service",
            "social-graph-service",
        },
        0.60,
    ),
    # 30%: user-timeline (UT)
    "user-timeline": (
        {
            "user-timeline-service",
            "post-storage-service",
        },
        0.30,
    ),
    # 10%: compose-post (CP) — base targets + extras per original workload
    "compose-post": (
        {
            "compose-post-service",
            "unique-id-service",
            "text-service",
            "user-service",
            "post-storage-service",
            "social-graph-service",
        },
        0.10,
    ),
}

# Media-Microservices (client is nginx-web-server)
# Workload is centered on a single endpoint: compose-review (weight 1.0)
# See DSB wrk2 script for the HTTP path (/wrk2-api/review/compose). :contentReference[oaicite:1]{index=1}
MS_ENDPOINTS: Dict[str, Tuple[Set[str], float]] = {
    "compose-review": (
        {
            "compose-review-service",
            "unique-id-service",
            "user-service",
            "movie-id-service",
            "movie-review-service",
            "user-review-service",
            "cast-info-service",
            "plot-service",
            "rating-service",
            "review-storage-service",
        },
        1.00,
    ),
}

# Hotel-Reservation (client is frontend)
# Mix corresponds to common “mixed-workload_type_1” proportions.
HR_ENDPOINTS: Dict[str, Tuple[Set[str], float]] = {
    "search-hotels": (
        {
            "search",
            "geo",
            "profile",
            "rate",
            # downstream helpers commonly hit during search
            "recommendation",
            "review",
        },
        0.60,
    ),
    "recommend": (
        {
            "recommendation",
            "profile",
            "rate",
        },
        0.39,
    ),
    "user-login": (
        {
            "user",
        },
        0.005,
    ),
    "reserve": (
        {
            "reservation",
            "profile",
            "rate",
            "user",
        },
        0.005,
    ),
}

APP_SPEC = {
    "social-network": {
        "client": "nginx-web-server",
        "endpoints": SN_ENDPOINTS,
        # extras applied only to compose-post (see below)
        "compose_post_extras": {"media-service", "url-shorten-service", "user-mention-service"},
    },
    "media-service": {
        "client": "nginx-web-server",
        "endpoints": MS_ENDPOINTS,
    },
    "hotel-reservation": {
        "client": "frontend",
        "endpoints": HR_ENDPOINTS,
    },
}

spec = APP_SPEC[args.app]
client = spec["client"]
EP: Dict[str, Tuple[Set[str], float]] = spec["endpoints"]


# --------------------- Sanity checks on targets ---------------------

def ensure_nonempty_targets():
    """
    Validate that for every endpoint at least one declared target exists in the graph.
    This prevents the 'empty target set' -> vacuous True -> R=1.0 pitfall.
    """
    problems = []
    for name, (targets, _w) in EP.items():
        present = [t for t in targets if t in graph_nodes]
        if len(present) == 0:
            problems.append(name)
    if problems:
        raise SystemExit(
            "[resilience] No declared targets found in deps.json for endpoints: "
            + ", ".join(sorted(problems))
            + ". Ensure tracing captured the calls before export (or adjust target names)."
        )

# Client must exist too (Jaeger must see it in the deps graph)
if client not in graph_nodes:
    raise SystemExit(f"[resilience] Client service '{client}' not present in deps.json nodes; "
                     "did the trace include frontend/nginx?")

ensure_nonempty_targets()


# --------------------- Replica model ---------------------

# service -> replica count
k_i = {svc: rep_for(svc) for svc in graph_nodes}

# Build flat container list for sampling without replacement
container_list: List[str] = []
for svc, cnt in k_i.items():
    container_list.extend([svc] * cnt)

N_app_containers = len(container_list)
if N_app_containers == 0:
    raise SystemExit("[resilience] No application containers derived from deps graph/replicas.")

# how many to kill per sample
K_kill = max(1, int(math.ceil(args.p_fail * N_app_containers)))


# --------------------- Simulation ---------------------

def alive_after_random_kill() -> Set[str]:
    """Sample K_kill containers, then return the set of services that still have at least one replica alive."""
    victims = random.sample(container_list, K_kill)
    gone = Counter(victims)  # service -> how many replicas killed
    alive = {svc for svc, cnt in k_i.items() if gone.get(svc, 0) < cnt}
    return alive


def ok_for_endpoint(G_all: nx.DiGraph, alive: Set[str], ep_name: str) -> int:
    """Check reachability from client to all required targets of a given endpoint."""
    base_targets, _w = EP[ep_name]

    # Compose base list using only nodes present in the graph (others are ignored here;
    # earlier non-presence was already validated to be non-empty).
    targets: List[str] = [t in alive and t or t for t in base_targets if t in G_all]

    # Social-Network: add empirical extras for compose-post, as in the release script
    if args.app == "social-network" and ep_name == "compose-post":
        # replicate original random knobs:
        # - num_media in [0,4]  -> include media-service if >0
        # - num_urls  in [0,5]  -> include url-shorten-service if >0
        # - num_mentions in [0,5] -> include user-mention-service if >0
        extras = spec.get("compose_post_extras", set())
        if random.randint(0, 4) > 0 and "media-service" in extras:
            targets.append("media-service")
        if random.randint(0, 5) > 0 and "url-shorten-service" in extras:
            targets.append("url-shorten-service")
        if random.randint(0, 5) > 0 and "user-mention-service" in extras:
            targets.append("user-mention-service")

    if len(targets) == 0:
        # Paranoia: should be impossible after ensure_nonempty_targets(), but guard anyway.
        return 0

    # Subgraph induced by alive nodes
    G_alive = G_all.subgraph(alive)

    # Endpoint succeeds iff client is alive *and* has a path to every target
    if client not in alive:
        return 0
    return int(all(nx.has_path(G_alive, client, t) for t in targets))


# Run Monte-Carlo
results: Dict[str, List[int]] = {name: [] for name in EP}
for _ in range(args.samples):
    alive = alive_after_random_kill()
    for name in results:
        results[name].append(ok_for_endpoint(G, alive, name))

# Aggregate per-endpoint and weighted average
R_ep: Dict[str, float] = {name: float(np.mean(vals)) for name, vals in results.items()}
R_avg = sum(R_ep[name] * EP[name][1] for name in EP)

out = {
    "R_avg": round(R_avg, 5),
    "R_ep": {k: round(v, 5) for k, v in R_ep.items()},
    "samples": int(args.samples),
    "p_fail": float(args.p_fail),
    "seed": int(args.seed),
}
print(out)

if args.out:
    Path(args.out).write_text(json.dumps(out))
