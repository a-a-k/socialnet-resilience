#!/usr/bin/env python3
"""
Compute R_avg for the Hotel-Reservation graph in deps.json,
mirroring the empirical workload.
For each endpoint, check that all required services are reachable
from frontend, and aggregate using the workload mix.
"""
import json
import random
import math
import numpy as np
import networkx as nx
import argparse
from collections import Counter

# ---------------- deterministic RNG ----------------
_FIXED_SEED = 16

# ---------------- argument parsing ----------------
ap = argparse.ArgumentParser()
ap.add_argument("deps", help="Jaeger deps.json")
ap.add_argument("-o", "--out", help="store result JSON here")
ap.add_argument("--samples", type=int, default=500000)
ap.add_argument("--p_fail",  type=float, default=0.30)
ap.add_argument('--repl', type=int, choices=[0, 1], default=0)
ap.add_argument('--seed', type=int, default=_FIXED_SEED)
args = ap.parse_args()

random.seed(args.seed)

# ----- load graph ----------------------------------------------------------
E = json.load(open(args.deps))["data"]
G = nx.DiGraph((e["parent"], e["child"]) for e in E)
graph_nodes = list(G)

# Hotel reservation services that can be scaled to 3 replicas
replicas = {
    "frontend":         3,
    "search":           3,
    "geo":              3,
    "profile":          3,
    "rate":             3,
    "recommendation":   3,
    "reservation":      3,
    "user":             3,
}

# --- Calculate total application containers and number to kill ---
application_service_names = graph_nodes

# Build service -> replica count map
k_i_map = {}
for svc in application_service_names:
    if args.repl and svc in replicas:
        k_i_map[svc] = replicas[svc]
    else:
        k_i_map[svc] = 1

N_app_containers = sum(k_i_map.values())
K_killed_containers = 0
if N_app_containers > 0:
    K_killed_containers = max(1, int(math.ceil(
        args.p_fail * N_app_containers)))
    K_killed_containers = min(K_killed_containers, N_app_containers)

# --- Build container list for sampling without replacement ---
container_list = []
for svc, count in k_i_map.items():
    container_list.extend([svc] * count)

# --- Hotel Reservation endpoint definitions and workload mix ---
endpoints = {
    "search-hotels": {
        "targets": [
            "search",
            "geo",
            "mongodb-geo",
            "rate",
            "mongodb-rate",
            "profile",
            "mongodb-profile"
        ],
        "weight": 0.6,
    },
    "recommendations": {
        "targets": [
            "recommendation",
            "mongodb-recommendation",
            "geo",
            "mongodb-geo",
            "rate",
            "mongodb-rate"
        ],
        "weight": 0.39,
    },
    "user-auth": {
        "targets": [
            "user",
            "mongodb-user"
        ],
        "weight": 0.005,
    },
    "reservation": {
        "targets": [
            "reservation",
            "mongodb-reservation",
            "memcached-reservation",
            "user",
            "mongodb-user",
            "profile",
            "mongodb-profile",
            "rate",
            "mongodb-rate"
        ],
        "weight": 0.005,
    },
}
client = "frontend"

# --- Simulation ---
results = {ep: [] for ep in endpoints}
for _ in range(args.samples):
    # Determine alive services via sampling without replacement
    if K_killed_containers == 0:
        alive_services = set(graph_nodes)
    else:
        victims = random.sample(container_list, K_killed_containers)
        vict_counts = Counter(victims)
        alive_services = {svc for svc, count in k_i_map.items()
                          if vict_counts.get(svc, 0) < count}

    # Build subgraph of alive services
    G_alive = G.subgraph(alive_services)

    # Evaluate each endpoint
    for ep, info in endpoints.items():
        targets = list(info["targets"])

        # Hotel reservation endpoints have fixed dependencies
        # All listed targets are always required

        # Check reachability for all required targets
        ok = all(
            client in alive_services and t in alive_services and
            nx.has_path(G_alive, client, t)
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