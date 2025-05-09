#!/usr/bin/env python3
"""
Compute R_avg for the Social-Network graph in deps.json, mirroring the empirical workload.
For each endpoint, check that all required services are reachable from nginx-web-server, and aggregate using the workload mix.
"""
import json, random, numpy as np, networkx as nx, argparse # type: ignore
from scipy.stats import hypergeom # Add this import
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
graph_nodes = list(G) # All services in the dependency graph

# stateless services scaled to 3 replicas in replica-scenario
replicas = {
    "compose-post-service":     3,
    "home-timeline-service":    3,
    "user-timeline-service":    3,
    "text-service":             3,
    "media-service":            3,
}

# --- Calculate total application containers and number to kill ---
# Assuming all nodes in G are potential application containers subject to chaos
# Adjust this list if some services in G are excluded from chaos (like jaeger, etc.)
application_service_names = [node for node in graph_nodes] # Or filter this list

N_app_containers = 0
for s_name in application_service_names:
    if args.repl and s_name in replicas:
        N_app_containers += replicas[s_name]
    else:
        N_app_containers += 1

if N_app_containers == 0:
    K_killed_containers = 0 # Avoid division by zero if no app containers
else:
    K_killed_containers = max(1, int(round(args.p_fail * N_app_containers)))
    if K_killed_containers > N_app_containers: # Cannot kill more than exist
        K_killed_containers = N_app_containers


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
    alive_services_this_round = set()
    if N_app_containers == 0 and K_killed_containers == 0: # Special case: no containers
        alive_services_this_round.update(graph_nodes) # All services considered up
    elif N_app_containers > 0 : # Proceed only if there are containers to analyze
        for service_name in graph_nodes:
            k_service_replicas = 1
            if args.repl and service_name in replicas:
                k_service_replicas = replicas[service_name]

            service_is_alive = True # Assume alive initially
            if K_killed_containers > 0: # Only apply killing logic if containers are actually killed
                if k_service_replicas == 1:
                    # Probability this single replica is killed
                    p_killed_single = K_killed_containers / N_app_containers
                    if random.random() < p_killed_single:
                        service_is_alive = False
                else: # k_service_replicas > 1
                    # Probability all k_service_replicas are killed
                    # hypergeom.pmf(x, M, n, N_draws)
                    # x = k_service_replicas (all replicas of this service are killed)
                    # M = N_app_containers (total app containers)
                    # n = k_service_replicas (number of this service's replicas in the population)
                    # N_draws = K_killed_containers (number of containers drawn/killed)
                    if K_killed_containers < k_service_replicas:
                        p_all_replicas_killed = 0.0 # Cannot kill all if K_killed < k_service_replicas
                    else:
                        try:
                            p_all_replicas_killed = hypergeom.pmf(k_service_replicas, N_app_containers, k_service_replicas, K_killed_containers)
                        except ValueError: # Can happen if params are inconsistent (e.g., N_app_containers too small)
                            p_all_replicas_killed = 1.0 # Conservatively assume all killed if error
                    
                    if random.random() < p_all_replicas_killed:
                        service_is_alive = False
            
            if service_is_alive:
                alive_services_this_round.add(service_name)
    
    G_alive = G.subgraph(alive_services_this_round)
    for ep, info in endpoints.items():
        # For each endpoint, all targets must be reachable from client
        ok = all(
            client in alive_services_this_round and t in alive_services_this_round and nx.has_path(G_alive, client, t)
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
    "p_fail": args.p_fail, # This now represents the fraction of containers targeted for killing
}
print(result)
if args.out:
    json.dump(result, open(args.out, "w"))
