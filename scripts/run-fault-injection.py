#!/usr/bin/env python3
"""Repeatable save-interruption fault runner (WP-03-T04, MV-NFR-01).

Each trial writes a large drawing over an existing valid file with the real MacVisio save path
(`--convert`), kills the process with SIGKILL at a random moment, and checks the destination: it must
be byte-identical to the previous valid file or a complete drawing MacVisio can read again. Stray
temporary files left beside the destination are reported. Inputs are never modified.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def readable(app: Path, drawing: Path, scratch: Path) -> bool:
    result = subprocess.run([str(app), "--dump-model", str(drawing), str(scratch / "readback.json")],
                            capture_output=True, timeout=600)
    return result.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--large", type=Path, required=True, help="Large drawing whose save is interrupted")
    parser.add_argument("--previous", type=Path, required=True, help="Small valid drawing that is the prior saved state")
    parser.add_argument("--trials", type=int, default=30)
    parser.add_argument("--seed", type=int, default=20261025)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    rng = random.Random(args.seed)
    # Calibrate the uninterrupted save time so kill points fall inside the write.
    with tempfile.TemporaryDirectory(prefix="macvisio-fault-") as scratch:
        scratch = Path(scratch)
        started = time.monotonic()
        subprocess.run([str(args.app), "--convert", str(args.large), str(scratch / "calibration.vsdx")],
                       capture_output=True, check=True, timeout=600)
        full = time.monotonic() - started
        trials, failures = [], 0
        for index in range(args.trials):
            folder = scratch / f"trial-{index:03d}"; folder.mkdir()
            destination = folder / "drawing.vsdx"
            shutil.copy2(args.previous, destination)
            before = sha(destination)
            delay = rng.uniform(0.05, max(0.1, full * 1.25))  # some kills land after the save commits
            process = subprocess.Popen([str(args.app), "--convert", str(args.large), str(destination)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(delay)
            killed = process.poll() is None
            if killed:
                os.kill(process.pid, signal.SIGKILL)
            process.wait(timeout=60)
            after = sha(destination) if destination.exists() else None
            state = "previous" if after == before else ("new" if after else "missing")
            ok = state == "previous" or (state == "new" and readable(args.app, destination, folder))
            strays = sorted(p.name for p in folder.iterdir() if p.name not in {"drawing.vsdx", "readback.json"})
            failures += 0 if ok else 1
            trials.append({"trial": index, "killAfterSeconds": round(delay, 3), "killedDuringSave": killed,
                           "destination": state, "valid": ok, "strayFiles": strays})
        report = {"schemaVersion": 1, "requirement": "MV-NFR-01", "seed": args.seed, "uninterruptedSaveSeconds": round(full, 3),
                  "trials": len(trials), "killedDuringSave": sum(t["killedDuringSave"] for t in trials),
                  "keptPrevious": sum(t["destination"] == "previous" for t in trials),
                  "completedNew": sum(t["destination"] == "new" for t in trials),
                  "invalidOrMissing": failures, "trialsWithStrayFiles": sum(bool(t["strayFiles"]) for t in trials),
                  "passed": failures == 0, "details": trials}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "details"}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
