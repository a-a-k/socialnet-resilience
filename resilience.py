#!/usr/bin/env python3
"""
Compute R_avg for the Social-Network graph in deps.json, mirroring the empirical workload.
For each endpoint, check that all required services are reachable from nginx-web-server, and aggregate using the workload mix.
"""
import json, random, numpy as np, networkx as nx, argparse
# ---------------- deterministic RNG ----------------
_FIXED_SEED = 16
random.seed(_FIXED_SEED)

ap = argparse.ArgumentParser()
ap.add_argument("deps", help="Jaeger deps.json")
ap.add_argument("-o", "--out", help="store result JSON here")
ap.add_argument("--samples", type=int, default=900000)
ap.add_argument("--p_fail",  type=float, default=0.30)
ap.add_argument('--repl', type=int, choices=[0,1], default=0)
args = ap.parse_args()

# ----- load graph ----------------------------------------------------------
E = json.load(open(args.deps))["data"]
G = nx.DiGraph((e["parent"], e["child"]) for e in E)
nodes = list(G)

# stateless services scaled to 3 replicas in replica-scenario
replicas = {
    "compose-post-service":     3,
    "home-timeline-service":    3,
    "user-timeline-service":    3,
    "text-service":             3,
    "media-service":            3,
}

p_node = args.p_fail
def node_alive(v):
    k = replicas.get(v, 1) if args.repl else 1
    return random.random() > p_node**k

# --- Endpoint definitions and workload mix ---
endpoints = {
    "home-timeline": {
        "targets": ["home-timeline-service", "post-storage-service"],
        "weight": 0.6,
    },
    "user-timeline": {
        "targets": ["user-timeline-service", "post-storage-service"],
        "weight": 0.3,
    },
    "compose-post": {
        "targets": [
            "compose-post-service", "text-service", "user-service",
            "unique-id-service", "media-service", "user-timeline-service",
            "home-timeline-service", "post-storage-service"
        ],
        "weight": 0.1,
    }
}

client = "nginx-web-server"

# --- Simulation ---
results = {k: [] for k in endpoints}
for _ in range(args.samples):
    alive = {v for v in nodes if node_alive(v)}
    G_alive = G.subgraph(alive)
    for ep, info in endpoints.items():
        # For each endpoint, all targets must be reachable from client
        ok = all(
            client in alive and t in alive and nx.has_path(G_alive, client, t)
            for t in info["targets"]
        )
        results[ep].append(int(ok))

# --- Aggregate ---
R_ep = {ep: float(np.mean(vals)) for ep, vals in results.items()}
R_avg = sum(R_ep[ep] * endpoints[ep]["weight"] for ep in endpoints)

# --- Output ---
result = {
    "R_avg": round(R_avg, 3),
    "R_ep": {ep: round(R_ep[ep], 3) for ep in R_ep},
    "samples": args.samples,
    "p_fail": p_node,
}
print(result)
if args.out:
    json.dump(result, open(args.out, "w"))
