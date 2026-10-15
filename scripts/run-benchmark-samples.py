#!/usr/bin/env python3
"""Retain every synthetic benchmark adapter attempt and reject incomplete evidence."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("benchmark_corpus", Path(__file__).with_name("generate-benchmark-corpus.py"))
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)
PHASES = ("open", "event", "commit", "calculation", "textLayout", "scenePreparation", "route", "draw", "snapshot", "encoding", "save", "close")
METRICS = ("peakRssBytes", "inputToFeedbackMs", "frameTimeMs", "maxMainThreadSaveStallMs", "maxPostOpenStallMs")
TARGETS = {
    "standard": {"openWarmMs": 3000, "openColdMs": 5000, "saveMs": 3000, "peakRssBytes": 1000000000},
    "large": {"openWarmMs": 15000, "saveMs": 10000, "peakRssBytes": 3000000000, "maxPostOpenStallMs": 250},
    "interaction": {"inputToFeedbackMs": 50, "frameTimeMs": 33},
    "allSave": {"maxMainThreadSaveStallMs": 100},
}


def number(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def aggregate(values):
    ordered = sorted(values)
    return {"samples": len(ordered), "p50": statistics.median(ordered), "p95": ordered[math.ceil(.95*len(ordered))-1], "max": ordered[-1]} if ordered else None


def validate_environment(environment):
    if not isinstance(environment, dict):
        raise ValueError("Environment must be a JSON object")
    for name in ("hardware", "os", "appBuild", "storage", "cacheProcedure"):
        if not isinstance(environment.get(name), str) or not environment[name].strip():
            raise ValueError(f"Environment requires {name}")
    if type(environment.get("memoryBytes")) is not int or environment["memoryBytes"] <= 0 or type(environment.get("controlledHardware")) is not bool:
        raise ValueError("Environment requires positive integer memoryBytes and boolean controlledHardware")


def validate_result(result, fixture, cache, index, mode):
    errors = []
    for key, expected in (("schemaVersion", 1), ("fixtureSha256", fixture["sha256"]), ("cacheCondition", cache), ("sampleIndex", index), ("mode", mode)):
        if type(result.get(key)) != type(expected) or result.get(key) != expected:
            errors.append(f"{key}: expected {expected!r}")
    preparation = result.get("cachePreparation", {})
    if not isinstance(preparation, dict) or preparation.get("status") != "passed" or not isinstance(preparation.get("method"), str) or not preparation["method"].strip():
        errors.append("cachePreparation: explicit successful method required")
    phases = result.get("phases", {})
    if not isinstance(phases, dict):
        phases = {}
    for name in PHASES + (("recovery",) if mode == "recovery" else ()):
        phase = phases.get(name, {})
        if not isinstance(phase, dict) or phase.get("status") != "passed" or not number(phase.get("elapsedMs")):
            errors.append(f"phase {name}: successful finite elapsedMs required")
    # An adapter cannot hide an extra failed/skipped phase merely by supplying the required phases.
    for name, phase in phases.items():
        if not isinstance(phase, dict) or phase.get("status") != "passed":
            errors.append(f"phase {name}: failure/skipped phase retained")
    counts = result.get("workCounts", {})
    if not isinstance(counts, dict):
        counts = {}
    for name, expected in fixture["counts"].items():
        if type(counts.get(name)) is not int or counts[name] != expected:
            errors.append(f"workCounts.{name}: expected {expected}")
    for name in ("visitedObjects", "evaluatedCells", "drawnObjects"):
        value = counts.get(name)
        if type(value) is not int or value < 0 or (name != "evaluatedCells" and value == 0) or (name == "evaluatedCells" and fixture["counts"]["formulaCells"] > 0 and value == 0):
            errors.append(f"workCounts.{name}: nonempty applicable instrumented work required")
    metrics = result.get("metrics", {})
    if not isinstance(metrics, dict):
        errors.append("metrics must be an object")
        metrics = {}
    for name, value in metrics.items():
        if name in METRICS and not number(value):
            errors.append(f"metrics.{name}: finite nonnegative value required")
    if mode == "memory" and (not number(metrics.get("peakRssBytes")) or metrics["peakRssBytes"] <= 0):
        errors.append("memory cycle requires positive peakRssBytes")
    if mode == "recovery":
        fault = result.get("fault", {})
        if not isinstance(fault, dict) or not isinstance(fault.get("name"), str) or not fault["name"].strip() or any(fault.get(k) is not True for k in ("injected", "lastValidFilePreserved", "checkpointRecoverable")):
            errors.append("recovery requires named injected fault and file/checkpoint preservation evidence")
    return errors


def assess(fixture, attempts, environment, cache, mode):
    minimum = 20 if mode == "memory" else 30
    complete = len(attempts) >= minimum and all(not a["errors"] for a in attempts)
    observations = {"aggregationScope": "All finite reported samples; failed attempts still prevent qualification", "phasesMs": {}, "metrics": {}}
    def observed(attempt, section, key, nested=None):
        result = attempt.get("result")
        section_value = result.get(section) if isinstance(result, dict) else None
        value = section_value.get(key) if isinstance(section_value, dict) else None
        return value.get(nested) if nested is not None and isinstance(value, dict) else value if nested is None else None
    for phase in PHASES + (("recovery",) if mode == "recovery" else ()):
        values = [observed(a, "phases", phase, "elapsedMs") for a in attempts]
        observations["phasesMs"][phase] = aggregate([v for v in values if number(v)])
    for metric in METRICS:
        values = [observed(a, "metrics", metric) for a in attempts]
        observations["metrics"][metric] = aggregate([v for v in values if number(v)])
    controlled = environment.get("controlledHardware") is True and environment.get("architecture") == "AppleSilicon" and environment.get("memoryBytes", 0) >= 16*1024**3 and environment.get("localSSD") is True
    gates = {}
    def gate(name, statistic, limit, rank="p95"):
        if not complete or not controlled or len(attempts) < 30 or statistic is None or statistic["samples"] != len(attempts):
            gates[name] = {"status": "unaccepted", "limit": limit, "reason": "Incomplete samples, missing metric or uncontrolled hardware"}
        else:
            gates[name] = {"status": "passed" if statistic[rank] <= limit else "failed", "limit": limit, "observed": statistic[rank], "statistic": rank}
    profile = fixture.get("targetProfile")
    if profile in ("standard", "large"):
        # Exact public counts and page cardinality are required even if the profile is relabelled.
        exact = {"standard": (2000, 1000, 10), "large": (20000, 10000, 50)}[profile]
        if (fixture["counts"]["shapes"], fixture["counts"]["connectors"], len(fixture["expected"]["pages"])) != exact:
            complete = False
        targets = TARGETS[profile]
        open_limit = targets.get("open" + cache.title() + "Ms")
        if open_limit is not None:
            gate("open", observations["phasesMs"]["open"], open_limit)
        gate("save", observations["phasesMs"]["save"], targets["saveMs"])
        gate("peakRssBytes", observations["metrics"]["peakRssBytes"], targets["peakRssBytes"], "max")
        if profile == "large":
            gate("postOpenStall", observations["metrics"]["maxPostOpenStallMs"], 250, "max")
    gate("mainThreadSaveStall", observations["metrics"]["maxMainThreadSaveStallMs"], 100, "max")
    exact_interaction = len(fixture["expected"]["pages"]) == 1 and fixture["counts"]["shapes"] == 1000
    interaction = exact_interaction and isinstance(environment.get("interactionTrace"), str) and bool(environment["interactionTrace"].strip()) and all(isinstance(a.get("result"), dict) and type(a["result"].get("activePageShapes")) is int and a["result"]["activePageShapes"] == 1000 for a in attempts)
    if profile == "interaction":
        for name, limit in TARGETS["interaction"].items():
            gate(name, observations["metrics"][name] if interaction else None, limit)
    return {"evidenceComplete": complete, "minimumSamples": minimum, "observations": observations,
            "absoluteGates": gates, "absoluteAcceptance": "unaccepted" if not gates or any(g["status"] == "unaccepted" for g in gates.values()) else "failed" if any(g["status"] == "failed" for g in gates.values()) else "passed",
            "memoryLeakAcceptance": "unaccepted: requires settled-cache trend review over 20 complete cycles",
            "faultCoverageAcceptance": "unaccepted: requires review against named fault matrix"}


def write_json(path, value):
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")
    os.replace(temp, path)


def run(args, adapter):
    manifest = corpus.validate_corpus(args.fixtures)
    environment = corpus.parse_json(args.environment.read_text())
    validate_environment(environment)
    fixtures = [f for f in manifest["fixtures"] if not args.fixture or f["file"] in args.fixture]
    if not fixtures or (args.fixture and set(args.fixture) != {f["file"] for f in fixtures}):
        raise ValueError("Unknown or empty fixture selection")
    if not adapter:
        raise ValueError("Supply an adapter argv after --")
    if args.report.exists() or args.report.is_symlink():
        raise ValueError("Report must be a new path; previous attempts cannot be overwritten")
    report_path = args.report.resolve()
    fixture_root = args.fixtures.resolve()
    if report_path == fixture_root or fixture_root in report_path.parents:
        raise ValueError("Evidence output must be outside the immutable fixture directory")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    artifact_root = report_path.parent / (report_path.stem + "-attempts")
    artifact_root.mkdir()  # Refuse reuse, including stale result JSON.
    report = {"schemaVersion": 1, "syntheticOnly": True, "kind": "benchmark-adapter-evidence", "status": "running", "startedUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
              "environment": environment, "cacheCondition": args.cache, "mode": args.mode, "adapterArgv": adapter, "targets": TARGETS,
              "fixtureManifestSha256": hashlib.sha256((args.fixtures / "manifest.json").read_bytes()).hexdigest(), "fixtures": []}
    write_json(report_path, report)
    for fixture in fixtures:
        record = {"file": fixture["file"], "sha256": fixture["sha256"], "bytes": fixture["bytes"], "counts": fixture["counts"], "attempts": []}
        report["fixtures"].append(record)
        for index in range(1, args.samples+1):
            result_path = artifact_root / f"{Path(fixture['file']).stem}-{index}.json"
            command = adapter + ["--fixture", str(fixture_root / fixture["file"]), "--result", str(result_path), "--cache", args.cache, "--sample", str(index), "--mode", args.mode]
            attempt = {"sampleIndex": index, "errors": [], "result": None}
            start = time.monotonic()
            try:
                proc = subprocess.run(command, capture_output=True, timeout=args.timeout, check=False)
                attempt.update({"exitCode": proc.returncode, "stdout": proc.stdout.decode("utf-8", errors="replace"), "stderr": proc.stderr.decode("utf-8", errors="replace")})
                if proc.returncode:
                    attempt["errors"].append(f"Adapter exit code {proc.returncode}")
            except (OSError, subprocess.TimeoutExpired) as error:
                attempt["errors"].append(f"{type(error).__name__}: {error}")
            attempt["adapterProcessWallMs"] = (time.monotonic()-start)*1000
            try:
                if result_path.is_symlink():
                    raise ValueError("Adapter result cannot be a symlink")
                result = corpus.parse_json(result_path.read_text())
                if not isinstance(result, dict):
                    raise ValueError("Adapter result must be an object")
                attempt["result"] = result
                attempt["errors"].extend(validate_result(result, fixture, args.cache, index, args.mode))
            except (OSError, ValueError, TypeError) as error:
                attempt["errors"].append(f"Invalid result: {error}")
            # Revalidate all input hashes, contents, counts, metadata and links after each adapter attempt.
            try:
                if corpus.validate_corpus(args.fixtures) != manifest:
                    raise ValueError("Manifest changed during run")
            except (OSError, ValueError, KeyError, corpus.ET.ParseError, corpus.zipfile.BadZipFile) as error:
                attempt["errors"].append(f"Input mutation/validation failure: {error}")
            record["attempts"].append(attempt)
            write_json(report_path, report)
        record.update(assess(fixture, record["attempts"], environment, args.cache, args.mode))
    report["status"] = "complete" if all(f["evidenceComplete"] for f in report["fixtures"]) else "incomplete"
    report["endedUtc"] = dt.datetime.now(dt.timezone.utc).isoformat()
    report["acceptance"] = "unaccepted: adapter/count evidence does not establish compatibility, fault coverage or absence of leaks"
    write_json(report_path, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--fixture", action="append")
    parser.add_argument("--environment", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--cache", choices=("cold", "warm"), required=True)
    parser.add_argument("--mode", choices=("performance", "memory", "recovery"), default="performance")
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--timeout", type=float, default=120)
    argv = sys.argv[1:]
    split = argv.index("--") if "--" in argv else len(argv)
    args = parser.parse_args(argv[:split])
    adapter = argv[split+1:]
    if not 1 <= args.samples <= 10000 or not math.isfinite(args.timeout) or not 0 < args.timeout <= 3600:
        parser.error("samples must be 1..10000 and timeout >0..3600 seconds")
    try:
        report = run(args, adapter)
    except (OSError, ValueError, KeyError, corpus.ET.ParseError, corpus.zipfile.BadZipFile) as error:
        parser.exit(1, f"Benchmark rejected: {error}\n")
    print(f"{report['status']}: {args.report}")
    return 0 if report["status"] == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
