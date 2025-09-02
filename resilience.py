#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Resilience model with explicit per-endpoint target sets (no dynamic expansion).
Matches DSB workloads for:
  - social-network (home-timeline, user-timeline, compose-post)
  - media-service  (compose-review)
  - hotel-reservation (search-hotels, recommend, user-login, reserve)
"""

import argparse, json, math, random
from pathlib import Path
from collections import Counter

import networkx as nx
import numpy as np
import sys

def fail(msg: str, code: int = 2):
    print(f"[resilience] ERROR: {msg}", file=sys.stderr)
    sys.exit(code)

def load_graph(deps_path: Path) -> nx.DiGraph:
    raw = json.loads(deps_path.read_text())
    data = raw.get("data", [])
    if not data:
        fail(f"'{deps_path}' is empty or has no 'data'. "
             f"Export Jaeger dependencies before running the model.")
    return nx.DiGraph((e["parent"], e["child"]) for e in data)


# -------- explicit endpoint target sets (this is the key change) --------
# NOTE: These sets list the *microservices* that must be alive and reachable
# from the client for a request to succeed, mirroring the wrk2 workload logic.

EXPLICIT_TARGETS = {
    "social-network": {
        "client": "nginx-web-server",
        "endpoints": {
            # 60% home timeline reads
            "home-timeline": {
                "targets": {
                    "home-timeline-service",
                    "post-storage-service",
                    "social-graph-service",
                },
                "weight": 0.60,
            },
            # 30% user timeline reads
            "user-timeline": {
                "targets": {
                    "user-timeline-service",
                    "post-storage-service",
                },
                "weight": 0.30,
            },
            # 10% compose post (write fanout)
            # base targets + optional branches (media / url-shortener / mentions)
            "compose-post": {
                "targets": {
                    "compose-post-service",
                    "unique-id-service",
                    "text-service",
                    "user-service",
                    "post-storage-service",
                    "user-timeline-service",
                    "home-timeline-service",
                    "social-graph-service",
                },
                # optional subcalls as in mixed-workload (prob. > 0)
                "optional": {
                    "media-service": {"p": 0.8},           # ~ 4/5
                    "url-shorten-service": {"p": 0.83},    # ~ 5/6
                    "user-mention-service": {"p": 0.83},   # ~ 5/6
                },
                "weight": 0.10,
            },
        },
    },

    "media-service": {
        "client": "nginx-web-server",
        "endpoints": {
            # Compose a movie review (POST /wrk2-api/review/compose)
            # Services involved according to the compose-review path.
            "compose-review": {
                "targets": {
                    "compose-review-service",
                    "unique-id-service",
                    "user-service",
                    "movie-id-service",
                    "movie-info-service",
                    "cast-info-service",
                    "review-storage-service",
                    "user-review-service",
                    "movie-review-service",
                },
                "weight": 1.00,
            }
        },
    },

    "hotel-reservation": {
        "client": "frontend",
        "endpoints": {
            # /search hotels
            "search-hotels": {
                "targets": {"search", "profile", "geo", "rate"},
                "weight": 0.60,
            },
            # /recommend for a user/location
            "recommend": {
                "targets": {"recommendation", "profile", "geo"},
                "weight": 0.39,
            },
            # /user login
            "user-login": {
                "targets": {"user"},
                "weight": 0.005,
            },
            # /reserve
            "reserve": {
                "targets": {"reservation", "user", "profile", "rate"},
                "weight": 0.005,
            },
        },
    },
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("deps", help="Jaeger deps.json")
    ap.add_argument("-o", "--out", help="Write result JSON here")
    ap.add_argument("--samples", type=int, default=500_000)
    ap.add_argument("--p_fail", type=float, default=0.30)
    ap.add_argument("--repl", type=int, choices=[0, 1], default=0)
    ap.add_argument("--seed", type=int, default=16)
    ap.add_argument(
        "--app",
        choices=["social-network", "media-service", "hotel-reservation"],
        default="social-network",
        help="Which DSB app profile to use (selects target sets and replicas file).",
    )
    ap.add_argument(
        "--config",
        help="Explicit apps/<app>/config.json (overrides --app for replicas_file).",
    )
    args = ap.parse_args()

    random.seed(args.seed)

    # Load graph
    deps_path = Path(args.deps)
    G = load_graph(deps_path)
    graph_nodes = list(G.nodes())

    # Load per-app config to locate replicas file
    cfg_path = Path(args.config) if args.config else Path("apps") / args.app / "config.json"
    cfg = json.loads(cfg_path.read_text())
    replicas_path = Path(cfg.get("replicas_file", ""))

    replicas_cfg = {"default": 1}
    if replicas_path.is_file():
        replicas_cfg = json.loads(replicas_path.read_text())
    default_rep = int(replicas_cfg.get("default", 1))

    # Build service -> replica count map
    k_i_map = {}
    for svc in graph_nodes:
        k_i_map[svc] = int(replicas_cfg.get(svc, default_rep)) if args.repl == 1 else 1

    # Total containers and how many fail per round (without replacement)
    N = sum(k_i_map.values())
    K = 0
    if N > 0:
        K = max(1, int(math.ceil(args.p_fail * N)))
        K = min(K, N)

    # Container multiset for sampling without replacement
    container_list = []
    for svc, count in k_i_map.items():
        container_list.extend([svc] * count)

    # Select app profile and endpoints
    spec = EXPLICIT_TARGETS[args.app]
    client = spec["client"]
    endpoints_spec = spec["endpoints"]

    # Prepare results
    results = {ep: [] for ep in endpoints_spec}

    for _ in range(args.samples):
        # Sample failed containers
        if K == 0:
            alive = set(graph_nodes)
        else:
            fails = Counter(random.sample(container_list, K))
            alive = {svc for svc, cnt in k_i_map.items() if fails.get(svc, 0) < cnt}

        # Subgraph of alive services
        G_alive = G.subgraph(alive)

        for ep, info in endpoints_spec.items():
            base_targets = set(info["targets"])
            targets = set(base_targets)

            # Optional branches for social-network compose-post
            if ep == "compose-post" and "optional" in info:
                for svc, meta in info["optional"].items():
                    p = float(meta.get("p", 0.0))
                    if random.random() < p:
                        targets.add(svc)

            ok = (
                client in alive
                and all(t in alive and nx.has_path(G_alive, client, t) for t in targets)
            )
            results[ep].append(1 if ok else 0)

    # Aggregate
    R_ep = {ep: float(np.mean(vals)) if vals else 0.0 for ep, vals in results.items()}
    R_avg = sum(R_ep[ep] * endpoints_spec[ep]["weight"] for ep in endpoints_spec)

    output = {
        "app": args.app,
        "repl": int(args.repl),
        "R_avg": round(R_avg, 5),
        "R_ep": {ep: round(val, 5) for ep, val in R_ep.items()},
        "samples": int(args.samples),
        "p_fail": float(args.p_fail),
        "seed": int(args.seed),
    }
    print(output)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        json.dump(output, open(args.out, "w"))


if __name__ == "__main__":
    main()
