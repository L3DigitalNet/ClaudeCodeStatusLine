#!/usr/bin/env python3
"""Reproducible benchmark harness for Antigravity CLI statusline executable.

Measures fresh-process execution latency across N samples using a representative
JSON payload in an isolated temporary environment.
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

SAMPLE_PAYLOAD = json.dumps(
    {
        "agent_state": "idle",
        "model": {"display_name": "Gemini 3.6 Flash (High)", "effort": "high"},
        "cwd": "/tmp",
        "workspace": {"workspace_name": "benchmark-repo"},
        "context_window": {
            "total_input_tokens": 42100,
            "total_output_tokens": 1300,
            "context_window_size": 1048576,
            "used_percentage": 4.0,
        },
        "quota": {
            "5h_bucket": {"remaining_fraction": 0.85, "reset_in_seconds": 10800},
            "weekly_bucket": {"remaining_fraction": 0.90, "reset_in_seconds": 518400},
        },
    }
)


def get_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def get_rpm_version(package_name: str) -> str:
    try:
        res = subprocess.run(
            ["rpm", "-q", package_name],
            capture_output=True,
            text=True,
            check=False,
        )
        if res.returncode == 0:
            return res.stdout.strip()
    except OSError:
        pass
    return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark statusline executable latency.")
    parser.add_argument(
        "--executable",
        type=Path,
        default=Path("data/sys76/files/.gemini/antigravity-cli/statusline"),
        help="Path to statusline executable",
    )
    parser.add_argument("--warmups", type=int, default=10, help="Number of warmup iterations")
    parser.add_argument("--samples", type=int, default=100, help="Number of measured samples")
    parser.add_argument(
        "--max-p95-ms", type=float, default=50.0, help="Maximum allowed p95 latency in ms"
    )

    args = parser.parse_args()

    exe_path: Path = args.executable.resolve()
    if not exe_path.is_file():
        print(f"Error: Executable missing at {exe_path}", file=sys.stderr)
        return 1

    exe_hash = get_sha256(exe_path)

    # Set up isolated home and git repo for benchmark run
    tmp_dir = Path("/tmp") / f"statusline_bench_{os.getpid()}"
    shutil.rmtree(tmp_dir, ignore_errors=True)
    tmp_dir.mkdir(parents=True, exist_ok=True)

    iso_home = tmp_dir / "home"
    iso_home.mkdir()

    repo_dir = tmp_dir / "repo"
    repo_dir.mkdir()
    subprocess.run(
        ["git", "-C", str(repo_dir), "init", "-b", "main"], check=True, capture_output=True
    )

    env = {
        "HOME": str(iso_home),
        "PATH": "/usr/bin:/bin",
        "LANG": "C.UTF-8",
    }

    cache_file = iso_home / ".gemini/antigravity-cli/last_payload.json"

    # Warmup runs
    for _ in range(args.warmups):
        if cache_file.exists():
            cache_file.unlink()
        subprocess.run(
            [str(exe_path)],
            input=SAMPLE_PAYLOAD,
            capture_output=True,
            text=True,
            cwd=repo_dir,
            env=env,
            check=True,
        )

    # Measured runs
    durations_ms: list[float] = []
    for _ in range(args.samples):
        if cache_file.exists():
            cache_file.unlink()

        t0 = time.perf_counter_ns()
        res = subprocess.run(
            [str(exe_path)],
            input=SAMPLE_PAYLOAD,
            capture_output=True,
            text=True,
            cwd=repo_dir,
            env=env,
            check=False,
        )
        t1 = time.perf_counter_ns()

        if res.returncode != 0:
            print(f"Error: Executable failed with exit code {res.returncode}", file=sys.stderr)
            shutil.rmtree(tmp_dir, ignore_errors=True)
            return 1

        lines = [line for line in res.stdout.splitlines() if line.strip()]
        if len(lines) != 2:
            print(f"Error: Expected 2 output rows, got {len(lines)}", file=sys.stderr)
            shutil.rmtree(tmp_dir, ignore_errors=True)
            return 1

        durations_ms.append((t1 - t0) / 1_000_000.0)

    shutil.rmtree(tmp_dir, ignore_errors=True)

    durations_ms.sort()
    p50_idx = int(0.50 * len(durations_ms))
    p95_idx = int(0.95 * len(durations_ms)) - 1

    p50_ms = durations_ms[p50_idx]
    p95_ms = durations_ms[p95_idx]
    max_ms = max(durations_ms)

    passed = p95_ms <= args.max_p95_ms

    report = {
        "timestamp": datetime.now(UTC).isoformat(),
        "host": platform.node(),
        "executable": str(exe_path),
        "sha256": exe_hash,
        "python_version": sys.version.split()[0],
        "python3_rpm": get_rpm_version("python3"),
        "python3_rich_rpm": get_rpm_version("python3-rich"),
        "warmups": args.warmups,
        "samples": args.samples,
        "p50_ms": round(p50_ms, 3),
        "p95_ms": round(p95_ms, 3),
        "max_ms": round(max_ms, 3),
        "max_p95_threshold_ms": args.max_p95_ms,
        "passed": passed,
    }

    print(json.dumps(report, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
