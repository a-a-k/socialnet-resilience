#!/usr/bin/env python3
"""
Compute R_avg for the Social-Network graph in deps.json.
Path of interest: nginx-web-server → post-storage-service.
"""
import json, random, numpy as np, networkx as nx, argparse, sys

ap = argparse.ArgumentParser()
ap.add_argument("deps", help="Jaeger deps.json")
ap.add_argument("-o", "--out", help="store result JSON here")
ap.add_argument("--samples", type=int, default=5000)
ap.add_argument("--p_fail",  type=float, default=0.30)
args = ap.parse_args()

# ----- load graph ----------------------------------------------------------
E = json.load(open(args.deps))["data"]
G = nx.DiGraph((e["parent"], e["child"]) for e in E)
client, target = "nginx-web-server", "post-storage-service"
assert nx.has_path(G, client, target), "No path in full graph!"

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
    k = replicas.get(v, 1)
    # survive if at least one replica survives
    return random.random() > p_node**k

def sim():
    alive = {v for v in nodes if node_alive(v)}
    return int(client in alive and target in alive
               and nx.has_path(G.subgraph(alive), client, target))

R = float(np.mean([sim() for _ in range(args.samples)]))
result = {"R_avg": round(R, 3), "samples": args.samples, "p_fail": p_node}
print(result)
if args.out:
    json.dump(result, open(args.out, "w"))
