#!/usr/bin/env python3
"""
Compute R_avg for the Social-Network graph in deps.json, mirroring the empirical workload.
For each endpoint, check that all required services are reachable from nginx-web-server, and aggregate using the workload mix.
"""
import json
import random
import math
import numpy as np
import networkx as nx
import argparse
from collections import Counter
from pathlib import Path

# ---------------- deterministic RNG ----------------
_FIXED_SEED = 16

# ---------------- argument parsing ----------------
ap = argparse.ArgumentParser()
ap.add_argument("deps", help="Jaeger deps.json")
ap.add_argument("-o", "--out", help="store result JSON here")
ap.add_argument("--samples", type=int, default=500000)
ap.add_argument("--p_fail",  type=float, default=0.30)
ap.add_argument('--repl', type=int, choices=[0,1], default=0)
ap.add_argument('--seed', type=int, default=_FIXED_SEED)
ap.add_argument("--app", choices=["social-network", "media-service", "hotel-reservation"],
                default="social-network",
                help="Which DSB app profile to use (also selects apps/<app>/replicas.json).")
ap.add_argument("--config",
                help="Explicit path to apps/<app>/config.json (overrides --app).")

args = ap.parse_args()

random.seed(args.seed)

# ----- load graph ----------------------------------------------------------
E = json.load(open(args.deps))["data"]
G = nx.DiGraph((e["parent"], e["child"]) for e in E)
graph_nodes = list(G)

# --- read per-app config & replicas -----------------------------------------
cfg_path = Path(args.config) if args.config else Path("apps") / args.app / "config.json"
cfg = json.loads(cfg_path.read_text())

replicas_path = Path(cfg["replicas_file"])
replicas_cfg = json.loads(replicas_path.read_text()) if replicas_path.exists() else {"default": 1}
default_rep = int(replicas_cfg.get("default", 1))

# --- Calculate total application containers and number to kill ---
application_service_names = graph_nodes  # Adjust if some services are excluded

# Build service → replica count map (per-app, from replicas.json)
k_i_map = {}
for svc in graph_nodes:
    if int(args.repl) == 1:
        k_i_map[svc] = int(replicas_cfg.get(svc, default_rep))
    else:
        k_i_map[svc] = 1

N_app_containers = sum(k_i_map.values())
K_killed_containers = 0
if N_app_containers > 0:
    K_killed_containers = max(1, int(math.ceil(args.p_fail * N_app_containers)))
    K_killed_containers = min(K_killed_containers, N_app_containers)

# --- Build container list for sampling without replacement ---
container_list = []
for svc, count in k_i_map.items():
    container_list.extend([svc] * count)

# --- app-specific roots & weights from DSB wrk2 scripts ---
APP_SPEC = {
    "social-network": {
        "client": "nginx-web-server",
        "roots": {
            "home-timeline":   {"root": "home-timeline-service", "weight": 0.60},
            "user-timeline":   {"root": "user-timeline-service", "weight": 0.30},
            "compose-post":    {"root": "compose-post-service",  "weight": 0.10},
        },
    },
    "media-service": {
        "client": "nginx-web-server",
        # compose-review only
        "roots": {
            "compose-review":  {"root": "compose-review-service", "weight": 1.00},
        },
    },
    "hotel-reservation": {
        "client": "frontend",
        "roots": {
            "search-hotels":   {"root": "search",          "weight": 0.60},
            "recommend":       {"root": "recommendation",  "weight": 0.39},
            "user-login":      {"root": "user",            "weight": 0.005},
            "reserve":         {"root": "reservation",     "weight": 0.005},
        },
    },
}

def expand_targets(G, root):
    """All descendants of `root` (including itself) in the dependency graph."""
    if root not in G:
        return set()
    # descendants in a DiGraph: all nodes reachable from root via outgoing edges
    seen = set([root])
    stack = [root]
    while stack:
        u = stack.pop()
        for v in G.successors(u):
            if v not in seen:
                seen.add(v); stack.append(v)
    return seen

# pick app
app = args.app
spec = APP_SPEC[app]
client = spec["client"]

# build endpoint -> target-set using Jaeger deps.json
endpoints = {}
for name, cfg in spec["roots"].items():
    roots_targets = expand_targets(G, cfg["root"])
    endpoints[name] = {"targets": sorted(roots_targets), "weight": cfg["weight"]}

client = "nginx-web-server"

# --- Simulation ---
results = {ep: [] for ep in endpoints}
for _ in range(args.samples):
    # Determine alive services via sampling without replacement
    if K_killed_containers == 0:
        alive_services = set(graph_nodes)
    else:
        victims = random.sample(container_list, K_killed_containers)
        vict_counts = Counter(victims)
        alive_services = {svc for svc, count in k_i_map.items() if vict_counts.get(svc, 0) < count}

    # Build subgraph of alive services
    G_alive = G.subgraph(alive_services)

    # Evaluate each endpoint
    for ep, info in endpoints.items():
        targets = list(info["targets"])
        if ep == "compose-post":
            # simulate media usage: num_media in [0,4]
            if random.randint(0, 4) > 0:
                targets.append("media-service")
            # simulate URL inclusion: num_urls in [0,5]
            if random.randint(0, 5) > 0:
                targets.append("url-shorten-service")
            # simulate mentions: num_user_mentions in [0,5]
            if random.randint(0, 5) > 0:
                targets.append("user-mention-service")

        # Check reachability for all required targets
        ok = all(
            client in alive_services and t in alive_services and nx.has_path(G_alive, client, t)
            for t in targets
        )
        results[ep].append(int(ok))

# --- Aggregate results ---
R_ep = {ep: float(np.mean(vals)) for ep, vals in results.items()}
R_avg = sum(R_ep[ep] * endpoints[ep]["weight"] for ep in endpoints)

# --- Output ---
output = {
    "R_avg": round(R_avg, 5),
    "R_ep": {ep: round(R_ep[ep], 5) for ep in R_ep},
    "samples": args.samples,
    "p_fail": args.p_fail,
    "seed": args.seed,
}
print(output)
if args.out:
    json.dump(output, open(args.out, "w"))
