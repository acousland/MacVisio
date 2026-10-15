#!/usr/bin/env python3
"""Drive one verified public synthetic fixture through an owned product process."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

spec = importlib.util.spec_from_file_location("adapter_corpus", Path(__file__).with_name("generate-benchmark-corpus.py"))
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)
PHASES = ("open", "event", "commit", "calculation", "textLayout", "scenePreparation", "route", "draw", "snapshot", "encoding", "save", "close")


def run(args):
    fixture = args.fixture
    corpus_root = fixture.parent
    if fixture.is_symlink():
        raise ValueError("Fixture cannot be linked")
    result = args.result.resolve()
    resolved_root = corpus_root.resolve()
    if args.result.exists() or args.result.is_symlink() or result == resolved_root or resolved_root in result.parents:
        raise ValueError("Result must be a new path outside the immutable corpus")
    report = {"schemaVersion": 1, "cacheCondition": args.cache, "sampleIndex": args.sample, "mode": args.mode,
              "cachePreparation": {"status": "failed", "method": "Not prepared"},
              "phases": {p: {"status": "not_observed", "reason": "Product not run"} for p in PHASES}, "workCounts": {}, "metrics": {}}
    passed = False
    try:
        # The existing validator checks hashes, public XML, synthetic-only text,
        # exact counts and relationship/metadata policy across the entire corpus.
        manifest = corpus.validate_corpus(corpus_root)
        fixture = fixture.resolve(strict=True)
        entry = next((f for f in manifest["fixtures"] if f["file"] == fixture.name), None)
        if entry is None:
            raise ValueError("Fixture is not a validated corpus entry")
        report.update(fixtureSha256=entry["sha256"], workCounts=dict(entry["counts"]))
        if args.cache != "warm":
            raise ValueError("Cold cache preparation is unsupported; no OS cache eviction was performed")
        if args.mode != "performance":
            raise ValueError(f"{args.mode} mode is unsupported; no fault injection or memory-cycle qualification was performed")
        # This warms filesystem bytes only. Each product process starts afresh;
        # document, route, text and image caches inside the app are not warmed.
        if hashlib.sha256(fixture.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("Fixture changed during pre-read")
        report["cachePreparation"] = {"status": "passed", "method": "Validated corpus then complete fixture pre-read; fresh product process, no app-cache warm-up or OS cache flush"}
        app = args.app.resolve(strict=True)
        if not app.is_file() or not os.access(app, os.X_OK):
            raise ValueError("App must be an executable file")
        report["appPath"] = str(app)
        report["appSha256"] = hashlib.sha256(app.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix="macvisio-adapter-") as temporary:
            raw_path = Path(temporary) / "product.json"
            started = time.monotonic()
            proc = subprocess.run([str(app), "--benchmark-sample", str(fixture), str(raw_path)], capture_output=True, timeout=args.timeout, check=False)
            report["driver"] = {"exitCode": proc.returncode, "processWallMs": (time.monotonic()-started)*1000,
                                "stdout": proc.stdout.decode("utf-8", errors="replace"), "stderr": proc.stderr.decode("utf-8", errors="replace")}
            raw = corpus.parse_json(raw_path.read_text())
            if not isinstance(raw, dict) or raw.get("schemaVersion") != 1:
                raise ValueError("Invalid product evidence schema")
            for key in ("phases", "metrics", "activePageShapes", "instrumentation", "eventTrace", "inputSaved", "importWarningCount", "calculationIssueCount"):
                if key in raw:
                    report[key] = raw[key]
            runtime_counts = raw.get("workCounts", {})
            if not isinstance(runtime_counts, dict) or set(runtime_counts) & set(entry["counts"]):
                raise ValueError("Product counters cannot replace independently verified fixture counts")
            report["workCounts"].update(runtime_counts)
            passed = proc.returncode == 0 and raw.get("status") == "passed"
            if not passed:
                report["phases"]["driver"] = {"status": "failed", "reason": "Product process or scripted operation failed"}
        if hashlib.sha256(app.read_bytes()).hexdigest() != report["appSha256"]:
            raise ValueError("Executable changed during product run")
        if corpus.validate_corpus(corpus_root) != manifest:
            raise ValueError("Corpus changed during product run")
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired, corpus.ET.ParseError, corpus.zipfile.BadZipFile) as error:
        report["phases"]["driver"] = {"status": "failed", "reason": f"{type(error).__name__}: {error}"}
        passed = False
    result.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation preserves an earlier attempt even if another process
    # created the path after the initial refusal check.
    with result.open("x") as stream:
        json.dump(report, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--cache", choices=("cold", "warm"), default="warm")
    parser.add_argument("--sample", type=int, required=True)
    parser.add_argument("--mode", choices=("performance", "memory", "recovery"), default="performance")
    parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args()
    if args.sample < 1 or not 0 < args.timeout <= 3600:
        parser.error("sample must be positive and timeout must be >0..3600 seconds")
    try:
        return 0 if run(args) else 1
    except (OSError, ValueError) as error:
        parser.exit(1, f"Adapter rejected: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
