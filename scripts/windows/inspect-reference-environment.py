#!/usr/bin/env python3
"""Read-only current guest inventory. Never installs, activates COM, or changes a session."""
from __future__ import annotations
import argparse
import base64
import datetime as dt
import hashlib
import gzip
import json
import re
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).with_name('Inspect-ReferenceEnvironment.ps1')


def assess(inventory):
    """Presence is only a prerequisite, never launch/licensing/round-trip evidence."""
    errors = inventory.get('errors', [])
    views = inventory.get('registryViews', [])
    complete = {v.get('registryView') for v in views} == {'Registry32', 'Registry64'} and not errors
    present = any(v.get('visioClsid') for v in views) and bool(inventory.get('visioExecutables'))
    busy = bool(inventory.get('relevantProcesses'))
    prerequisites = []
    if not complete: prerequisites.append('Complete error-free 32/64-bit inventory')
    if not present: prerequisites.append('Appropriately licensed exact-build Visio Professional 2019 installation with executable and COM registration')
    if busy: prerequisites.append('An isolated idle reference session; current processes must not be disturbed')
    prerequisites += ['Verified license entitlement and activation status', 'Exact edition/build/bitness/OS/font manifest freeze', 'Isolated COM launch and real open/edit/save/reopen/export smoke', 'Offline reference-image restore followed by the same smoke']
    return {'state': 'needs_input' if not present else 'installed_unaccepted', 'inventoryComplete': complete,
            'installedPrerequisiteObserved': present, 'sessionBusy': busy, 'accepted': False,
            'prerequisites': prerequisites}


def collect(instance, timeout):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', instance): raise ValueError('Unsafe Lima instance name')
    listed = subprocess.run(['limactl', 'list'], capture_output=True, text=True, timeout=30)
    if listed.returncode: raise RuntimeError('limactl list failed')
    if not any(len(parts := line.split()) > 1 and parts[0] == instance and parts[1].lower() == 'running' for line in listed.stdout.splitlines()):
        raise RuntimeError('Named Lima instance is not Running; this inspector never starts a guest')
    script = SCRIPT.read_bytes()
    payload = base64.b64encode(gzip.compress(script)).decode()
    # Compress to remain below Windows command-line limits without staging a guest file.
    stub = "$b=[Convert]::FromBase64String('" + payload + "'); $m=New-Object IO.MemoryStream(,$b); $z=New-Object IO.Compression.GzipStream($m,[IO.Compression.CompressionMode]::Decompress); $r=New-Object IO.StreamReader($z); & ([ScriptBlock]::Create($r.ReadToEnd()))"
    encoded = base64.b64encode(stub.encode('utf-16le')).decode()
    ran = subprocess.run(['limactl', 'shell', instance, 'powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], capture_output=True, text=True, timeout=timeout)
    if ran.returncode: raise RuntimeError(f'Guest inventory failed ({ran.returncode}): {ran.stderr.strip()}')
    value = json.loads(ran.stdout.lstrip('\ufeff').strip())
    if value.get('schemaVersion') != 1: raise ValueError('Unsupported inventory schema')
    value['hostProbe'] = {'instance': instance, 'scriptSha256': hashlib.sha256(script).hexdigest(), 'stderr': ran.stderr.strip()}
    value['assessment'] = assess(value)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance', default='mondrian-win')
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=60)
    args = parser.parse_args()
    if not 10 <= args.timeout <= 120: parser.error('timeout must be between 10 and 120 seconds')
    try:
        report = collect(args.instance, args.timeout)
        code = 0 if report['assessment']['inventoryComplete'] else 1
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report = {'schemaVersion': 1, 'collectedUtc': dt.datetime.now(dt.timezone.utc).isoformat(), 'assessment': {'accepted': False, 'state': 'needs_input', 'inventoryComplete': False}, 'errors': [{'type': type(error).__name__, 'message': str(error)}]}
        code = 2
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    print(json.dumps({'report': str(args.report), 'assessment': report['assessment']}))
    return code

if __name__ == '__main__': raise SystemExit(main())
