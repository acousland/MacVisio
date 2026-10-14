#!/usr/bin/env python3
"""Run a bounded real-Visio smoke comparison in the existing Lima/QEMU guest."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WINDOWS_DIR = Path(__file__).resolve().parent
RUNNER_PS = WINDOWS_DIR / "Run-VisioAcceptance.ps1"
WORKER_PS = WINDOWS_DIR / "Invoke-VisioFixture.ps1"
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.-]+\.vsd(x)?$", re.IGNORECASE)
SAFE_INSTANCE = re.compile(r"^[A-Za-z0-9_.-]+$")


def powershell_encoded(script: str) -> str:
    return base64.b64encode(script.encode("utf-16le")).decode("ascii")


def run_checked(command: list[str], *, timeout: int | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, text=True, capture_output=True, timeout=timeout, check=False)
    except FileNotFoundError as error:
        raise RuntimeError(f"Required executable not found: {command[0]}") from error
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"Command timed out: {' '.join(command[:4])}") from error


def require_running_lima(instance: str) -> None:
    result = run_checked(["limactl", "list"], timeout=30)
    if result.returncode:
        raise RuntimeError(f"limactl list failed: {result.stderr.strip() or result.stdout.strip()}")
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields and fields[0] == instance:
            if len(fields) > 1 and fields[1].lower() == "running":
                return
            raise RuntimeError(f"Lima instance {instance!r} is not running; start it with its documented wrapper first.")
    raise RuntimeError(f"Lima instance {instance!r} is not registered.")


def validate_fixture_set(folder: Path) -> tuple[dict, list[dict]]:
    folder = folder.resolve(strict=True)
    manifest_path = folder / "manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise ValueError(f"Missing regular synthetic manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    if manifest.get("schemaVersion") != 1 or manifest.get("syntheticOnly") is not True:
        raise ValueError("Refusing fixture folder: manifest must use schemaVersion 1 and syntheticOnly=true.")
    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise ValueError("Manifest has no fixture list.")
    seen: set[str] = set()
    for fixture in fixtures:
        name = fixture.get("file")
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name) or Path(name).name != name:
            raise ValueError(f"Unsafe or unsupported fixture filename: {name!r}")
        if name in seen:
            raise ValueError(f"Duplicate fixture filename: {name}")
        seen.add(name)
        expected_format = "vsdx" if name.lower().endswith(".vsdx") else "vsd"
        if fixture.get("format") != expected_format:
            raise ValueError(f"Manifest format does not match extension for {name}.")
        if fixture.get("containsNativeMetadata") is True:
            raise ValueError(f"Refusing fixture marked as containing native metadata: {name}")
        if not isinstance(fixture.get("expected", {}).get("pages"), list):
            raise ValueError(f"Missing expected pages for {name}.")
        source = folder / name
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"Fixture is missing or not a regular file: {source}")
        actual_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        if actual_hash.lower() != str(fixture.get("sha256", "")).lower():
            raise ValueError(f"Host SHA-256 mismatch for {name}.")
    return manifest, fixtures


def report_for_host_error(fixtures: list[dict], message: str) -> dict:
    failed_files = []
    for fixture in fixtures:
        phases = {
            "open": {"status": "failed", "error": {"type": "HostRunnerError", "message": message}},
            "inspect": {"status": "skipped", "pages": None},
            "mutation": {"status": "skipped"},
            "saveAs": {"status": "skipped"},
            "close": {"status": "skipped"},
            "reopen": {"status": "skipped", "pages": None},
            "exportPdf": {"status": "skipped"},
            "exportSvg": {"status": "skipped"},
        }
        failed_files.append({
            "file": fixture["file"],
            "format": fixture["format"],
            "case": fixture.get("case"),
            "inputSha256": fixture["sha256"],
            "status": "failed",
            "phases": phases,
            "environment": None,
        })
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    return {
        "schemaVersion": 1,
        "status": "failed",
        "startedUtc": now,
        "endedUtc": now,
        "environment": {},
        "errors": [{"type": "HostRunnerError", "message": message}],
        "files": failed_files,
    }


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True, help="Directory containing manifest.json and synthetic .vsd/.vsdx files")
    parser.add_argument("--report", type=Path, default=Path("build/WindowsValidation/windows-report.json"))
    parser.add_argument("--artifacts", type=Path, default=Path("build/WindowsValidation/windows-artifacts"))
    parser.add_argument("--instance", default="mondrian-win")
    parser.add_argument("--timeout-per-file", type=int, default=300)
    parser.add_argument("--remote-base", default=r"C:\Users\mondrian\AppData\Local\Temp")
    args = parser.parse_args()

    if not SAFE_INSTANCE.fullmatch(args.instance):
        parser.error("--instance must contain only letters, numbers, dot, underscore, or hyphen")
    if not 10 <= args.timeout_per_file <= 3600:
        parser.error("--timeout-per-file must be between 10 and 3600 seconds")
    if not re.fullmatch(r"[A-Za-z]:\\[A-Za-z0-9_ .\\-]+", args.remote_base):
        parser.error("--remote-base must be a simple absolute Windows path without quotes")

    report_path = args.report.resolve()
    artifacts_path = args.artifacts.resolve()
    try:
        manifest, fixtures = validate_fixture_set(args.fixtures)
        if report_path == (args.fixtures.resolve() / "manifest.json") or report_path.parent == args.fixtures.resolve():
            raise ValueError("Report path must be outside the fixture directory.")
        require_running_lima(args.instance)

        run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        remote_root = args.remote_base.rstrip("\\/") + "\\MacVisio-WindowsValidation-" + run_id
        remote_input = remote_root + r"\input"
        remote_scripts = remote_root + r"\scripts"
        remote_artifacts = remote_root + r"\artifacts"
        remote_report = remote_root + r"\windows-report.json"

        bootstrap = (
            f"$root = '{remote_root}'; "
            "New-Item -ItemType Directory -Force -Path $root, (Join-Path $root 'input'), "
            "(Join-Path $root 'scripts'), (Join-Path $root 'artifacts') | Out-Null"
        )
        bootstrap_result = run_checked([
            "limactl", "shell", args.instance, "powershell.exe", "-NoLogo", "-NoProfile",
            "-NonInteractive", "-EncodedCommand", powershell_encoded(bootstrap),
        ], timeout=45)
        if bootstrap_result.returncode:
            detail = bootstrap_result.stderr.strip() or bootstrap_result.stdout.strip()
            raise RuntimeError(f"Could not create isolated guest work directory: {detail}")

        with tempfile.TemporaryDirectory(prefix="macvisio-windows-fixtures-") as staging_name:
            staging = Path(staging_name)
            shutil.copyfile(args.fixtures.resolve() / "manifest.json", staging / "manifest.json")
            for fixture in fixtures:
                shutil.copyfile(args.fixtures.resolve() / fixture["file"], staging / fixture["file"])
            fixture_sources = [str(staging / "manifest.json")] + [str(staging / fixture["file"]) for fixture in fixtures]
            commands = [
                ["limactl", "copy", "--backend=scp", *fixture_sources, f"{args.instance}:{remote_input}/"],
                ["limactl", "copy", "--backend=scp", str(RUNNER_PS), str(WORKER_PS), f"{args.instance}:{remote_scripts}/"],
            ]
            for command in commands:
                copied = run_checked(command, timeout=300)
                if copied.returncode:
                    detail = copied.stderr.strip() or copied.stdout.strip()
                    raise RuntimeError(f"Guest SCP failed: {detail}")

        quote = lambda value: "'" + str(value).replace("'", "''") + "'"
        guest_runner = remote_scripts + "\\Run-VisioAcceptance.ps1"
        guest_worker = remote_scripts + "\\Invoke-VisioFixture.ps1"
        guest_command = (
            f"& {quote(guest_runner)} "
            f"-FixtureDirectory {quote(remote_input)} "
            f"-WorkerPath {quote(guest_worker)} "
            f"-ReportPath {quote(remote_report)} "
            f"-ArtifactDirectory {quote(remote_artifacts)} "
            f"-InstanceName {quote(args.instance)} "
            f"-TimeoutSeconds {args.timeout_per_file}; exit $LASTEXITCODE"
        )
        remote_report_scp = remote_report.replace("\\", "/")
        remote_artifacts_scp = remote_artifacts.replace("\\", "/")
        command_timeout = len(fixtures) * (args.timeout_per_file + 5) + 180
        run_result = run_checked([
            "limactl", "shell", args.instance, "powershell.exe", "-NoLogo", "-NoProfile",
            "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", powershell_encoded(guest_command),
        ], timeout=command_timeout)

        report_path.parent.mkdir(parents=True, exist_ok=True)
        copied_report = run_checked([
            "limactl", "copy", "--backend=scp", f"{args.instance}:{remote_report_scp}", str(report_path),
        ], timeout=90)
        if copied_report.returncode:
            detail = copied_report.stderr.strip() or copied_report.stdout.strip()
            raise RuntimeError(f"Visio run ended with code {run_result.returncode}, but the guest report could not be retrieved: {detail}")

        artifacts_path.parent.mkdir(parents=True, exist_ok=True)
        copied_artifacts = run_checked([
            "limactl", "copy", "--backend=scp", "--recursive", f"{args.instance}:{remote_artifacts_scp}", str(artifacts_path),
        ], timeout=300)
        if copied_artifacts.returncode:
            print(f"Warning: report saved, but artifact retrieval failed: {copied_artifacts.stderr.strip() or copied_artifacts.stdout.strip()}", file=sys.stderr)

        report = json.loads(report_path.read_text(encoding="utf-8-sig"))
        print(f"Windows Visio report: {report.get('status', 'unknown')} across {len(report.get('files', []))} fixtures")
        print(f"Report: {report_path}")
        if run_result.returncode:
            if run_result.stderr.strip():
                print(run_result.stderr.strip(), file=sys.stderr)
            if run_result.stdout.strip():
                print(run_result.stdout.strip(), file=sys.stderr)
            return 1
        return 0 if report.get("status") == "passed" else 1
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        message = str(error)
        try:
            _, fixtures = validate_fixture_set(args.fixtures)
        except Exception:
            fixtures = []
        if fixtures:
            write_json(report_path, report_for_host_error(fixtures, message))
            print(f"Validation failed; machine-readable failure report: {report_path}", file=sys.stderr)
        print(f"Windows Visio validation failed: {message}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
