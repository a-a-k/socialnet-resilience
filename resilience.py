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

# ---------------- deterministic RNG ----------------
_FIXED_SEED = 16
random.seed(_FIXED_SEED)

# ---------------- argument parsing ----------------
ap = argparse.ArgumentParser()
ap.add_argument("deps", help="Jaeger deps.json")
ap.add_argument("-o", "--out", help="store result JSON here")
ap.add_argument("--samples", type=int, default=2700000)
ap.add_argument("--p_fail",  type=float, default=0.30)
ap.add_argument('--repl', type=int, choices=[0,1], default=0)
args = ap.parse_args()

# ----- load graph ----------------------------------------------------------
E = json.load(open(args.deps))["data"]
G = nx.DiGraph((e["parent"], e["child"]) for e in E)
graph_nodes = list(G)

# Stateless services scaled to 3 replicas in replica-scenario
replicas = {
    "compose-post-service":     3,
    "home-timeline-service":    3,
    "user-timeline-service":    3,
    "text-service":             3,
    "media-service":            3,
}

# --- Calculate total application containers and number to kill ---
application_service_names = graph_nodes  # Adjust if some services are excluded

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
    K_killed_containers = max(1, int(math.ceil(args.p_fail * N_app_containers)))
    K_killed_containers = min(K_killed_containers, N_app_containers)

# --- Build container list for sampling without replacement ---
container_list = []
for svc, count in k_i_map.items():
    container_list.extend([svc] * count)

# --- Endpoint definitions and workload mix ---
endpoints = {
    "home-timeline": {
        "targets": ["home-timeline-service", "post-storage-service", "social-graph-service"],
        "weight": 0.6,
    },
    "user-timeline": {
        "targets": ["user-timeline-service", "post-storage-service"],
        "weight": 0.3,
    },
    "compose-post": {
        "targets": [
            "compose-post-service",
            "unique-id-service",
            "text-service",
            "user-service",
            "post-storage-service",
            "user-timeline-service",
            "home-timeline-service",
            "social-graph-service",
            "media-service",
            "url-shorten-service",
            "user-mention-service",
        ],
        "weight": 0.1,
    },
}
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
    "R_avg": round(R_avg, 3),
    "R_ep": {ep: round(R_ep[ep], 3) for ep in R_ep},
    "samples": args.samples,
    "p_fail": args.p_fail,
}
print(output)
if args.out:
    json.dump(output, open(args.out, "w"))
