#!/usr/bin/env python3
"""Run the SocialNetwork theoretical experiment through Bering + Sheaft.

This keeps the old output shape produced by resilience.py:

  {"R_avg": ..., "R_ep": {...}, "samples": ..., "p_fail": ..., "seed": ...}

The old script remains the baseline oracle. This runner is intentionally small:
it converts Jaeger deps.json into Bering topology_api JSON, runs Bering, runs
Sheaft with the requested sampling mode, and extracts the aggregate numbers
from Sheaft's report.json.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
from pathlib import Path
from typing import Any


ENTRY_SERVICE = "nginx-web-server"

REPLICATED_SERVICES = {
    "compose-post-service": 3,
    "home-timeline-service": 3,
    "user-timeline-service": 3,
    "text-service": 3,
    "media-service": 3,
}

ENDPOINTS = {
    "home-timeline": {
        "targets": [
            "home-timeline-service",
            "post-storage-service",
            "social-graph-service",
        ],
        "weight": 0.6,
    },
    "user-timeline": {
        "targets": [
            "user-timeline-service",
            "post-storage-service",
        ],
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("deps", help="Jaeger deps.json")
    parser.add_argument("-o", "--out", required=True, help="output JSON path")
    parser.add_argument("--workdir", help="intermediate artifact directory")
    parser.add_argument("--samples", type=int, default=500000)
    parser.add_argument("--p_fail", type=float, default=0.30)
    parser.add_argument("--seed", type=int, default=16)
    parser.add_argument("--repl", type=int, choices=[0, 1], default=0)
    parser.add_argument(
        "--sampling-mode",
        choices=["independent_replica", "fixed_k_replica_slots"],
        default="fixed_k_replica_slots",
    )
    parser.add_argument("--verbose", action="store_true", help="print toolchain commands")
    parser.add_argument(
        "--bering",
        default=os.environ.get("BERING_BIN", "bering"),
        help="Bering executable or command; env fallback: BERING_BIN",
    )
    parser.add_argument(
        "--sheaft",
        default=os.environ.get("SHEAFT_BIN", "sheaft"),
        help="Sheaft executable or command; env fallback: SHEAFT_BIN",
    )
    return parser.parse_args()


def command(value: str) -> list[str]:
    return shlex.split(value, posix=os.name != "nt")


def run(cmd: list[str], cwd: Path | None = None, verbose: bool = False) -> None:
    if verbose:
        print("+", subprocess.list2cmdline(cmd))
    subprocess.run(cmd, cwd=cwd, check=True)


def load_deps(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    edges = payload.get("data")
    if not isinstance(edges, list) or not edges:
        raise ValueError(f"{path} does not contain non-empty data[]")
    return edges


def service_replicas(service_id: str, repl: int) -> int:
    if repl:
        return REPLICATED_SERVICES.get(service_id, 1)
    return 1


def build_topology(edges: list[dict[str, Any]], deps_path: Path, repl: int) -> dict[str, Any]:
    services = set()
    edge_keys = set()
    for edge in edges:
        parent = str(edge["parent"]).strip()
        child = str(edge["child"]).strip()
        if not parent or not child:
            raise ValueError(f"invalid edge: {edge!r}")
        services.add(parent)
        services.add(child)
        edge_keys.add((parent, child))

    for endpoint in ENDPOINTS.values():
        services.add(ENTRY_SERVICE)
        services.update(endpoint["targets"])

    return {
        "source": {
            "type": "topology_api",
            "ref": f"file://{deps_path.as_posix()}",
        },
        "services": [
            {
                "id": service_id,
                "name": service_id,
                "replicas": service_replicas(service_id, repl),
                "support": {"observations": 1, "evidence": ["jaeger-deps"]},
            }
            for service_id in sorted(services)
        ],
        "edges": [
            {
                "from": parent,
                "to": child,
                "kind": "sync",
                "blocking": True,
                "support": {"observations": 1, "evidence": ["jaeger-deps"]},
            }
            for parent, child in sorted(edge_keys)
        ],
        "endpoints": [
            {
                "id": endpoint_id,
                "entry_service": ENTRY_SERVICE,
                "predicate_ref": endpoint_id,
                "weight": spec["weight"],
                "semantics": {
                    "predicate_mode": "immediate_response",
                    "mandatory_targets": spec["targets"],
                    "dependency_modes": ["sync"],
                    "source": "socialnet-resilience",
                    "confidence": 1.0,
                },
                "support": {"observations": 1, "evidence": ["socialnet-workload"]},
            }
            for endpoint_id, spec in ENDPOINTS.items()
        ],
    }


def build_analysis(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "schema_version": "1.0",
        "seed": args.seed,
        "trials": args.samples,
        "sampling_mode": args.sampling_mode,
        "failure_probability": args.p_fail,
        "endpoint_weights": {
            endpoint_id: spec["weight"] for endpoint_id, spec in ENDPOINTS.items()
        },
        "profiles": [
            {
                "name": args.sampling_mode,
                "trials": args.samples,
                "seed": args.seed,
                "sampling_mode": args.sampling_mode,
                "failure_probability": args.p_fail,
            }
        ],
        "gate": {
            "mode": "report",
            "default_action": "report",
            "evaluation_rule": "all_profiles",
            "global_threshold": 0.0,
            "aggregate_threshold": 0.0,
            "cross_profile_aggregate_threshold": 0.0,
        },
    }


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def extract_result(report_path: Path, args: argparse.Namespace) -> dict[str, Any]:
    with report_path.open("r", encoding="utf-8") as handle:
        report = json.load(handle)

    endpoint_results = report.get("endpoint_results") or []
    r_ep = {
        item["endpoint_id"]: round(float(item["availability"]), 5)
        for item in endpoint_results
        if item.get("profile") == args.sampling_mode
    }
    missing = sorted(set(ENDPOINTS) - set(r_ep))
    if missing:
        raise ValueError(f"report is missing endpoint results: {missing}")

    summary = report.get("summary") or {}
    r_avg = summary.get("weighted_overall_availability")
    if r_avg is None:
        r_avg = summary.get("overall_availability")
    if r_avg is None:
        raise ValueError("report summary does not contain aggregate availability")

    result = {
        "R_avg": round(float(r_avg), 5),
        "R_ep": r_ep,
        "samples": args.samples,
        "p_fail": args.p_fail,
        "seed": args.seed,
        "sampling_mode": args.sampling_mode,
    }
    for profile in report.get("profiles") or []:
        simulation = profile.get("simulation") or {}
        if profile.get("name") == args.sampling_mode and "fixed_k_failures" in simulation:
            result["fixed_k_failures"] = int(simulation["fixed_k_failures"])
            break
    return result


def main() -> int:
    args = parse_args()
    deps_path = Path(args.deps).resolve()
    out_path = Path(args.out).resolve()
    workdir = Path(args.workdir).resolve() if args.workdir else out_path.parent / "mb3r"
    sheaft_out = workdir / "sheaft"

    topology_path = workdir / "topology_api.json"
    analysis_path = workdir / "analysis.json"
    model_path = workdir / "bering-model.json"
    snapshot_path = workdir / "bering-snapshot.json"

    deps = load_deps(deps_path)
    write_json(topology_path, build_topology(deps, deps_path, args.repl))
    write_json(analysis_path, build_analysis(args))

    run(
        command(args.bering)
        + [
            "discover",
            "--input",
            str(topology_path),
            "--out",
            str(model_path),
            "--snapshot-out",
            str(snapshot_path),
        ],
        verbose=args.verbose,
    )
    run(
        command(args.sheaft)
        + [
            "run",
            "--model",
            str(snapshot_path),
            "--analysis",
            str(analysis_path),
            "--out-dir",
            str(sheaft_out),
        ],
        verbose=args.verbose,
    )

    result = extract_result(sheaft_out / "report.json", args)
    write_json(out_path, result)
    print(f"wrote {out_path}")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
