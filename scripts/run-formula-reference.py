#!/usr/bin/env python3
"""Run the ShapeSheet formula reference: Visio 2019 in the reference guest, then MacVisio on Visio's
own probe drawing, then compare. Writes visio-results.json, context.vsdx, macvisio-results.json
and comparison.json to --output."""
import argparse, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "windows"))
import visio_guest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, default=ROOT / ".build/debug/MacVisio")
parser.add_argument("--cases", type=Path, default=ROOT / "docs/evidence/reference/formulas/formula-cases.json")
parser.add_argument("--output", type=Path, default=ROOT / "build/m3/formula-probe")
parser.add_argument("--skip-visio", action="store_true", help="Reuse the existing Visio results and probe drawing")
args = parser.parse_args()
subprocess.run([sys.executable, str(ROOT / "scripts/reference-formula-cases.py"), str(args.cases)], check=True)
if not args.skip_visio:
    code = visio_guest.run(ROOT / "scripts/windows/Probe-VisioFormulas.ps1", [args.cases], args.output,
                           arguments={"Cases": args.cases.name}, timeout=1800)
    if code: sys.exit(f"Visio probe failed with exit code {code}; see {args.output}/console.txt")
subprocess.run([str(args.app), "--probe-formulas", str(args.output / "context.vsdx"), str(args.cases), str(args.output / "macvisio-results.json")], check=True)
formulas = subprocess.run([sys.executable, str(ROOT / "scripts/compare-formula-probe.py"), "--visio", str(args.output / "visio-results.json"),
                           "--macvisio", str(args.output / "macvisio-results.json"), "--report", str(args.output / "comparison.json")]).returncode
# The host matrix: the same formulas through MacVisio's document calculation in each consuming cell.
subprocess.run([str(args.app), "--probe-hosts", str(args.output / "context.vsdx"), str(args.cases), str(args.output / "macvisio-hosts.json")], check=True)
hosts = subprocess.run([sys.executable, str(ROOT / "scripts/compare-host-probe.py"), "--visio", str(args.output / "visio-results.json"),
                        "--macvisio", str(args.output / "macvisio-hosts.json"), "--dispositions", str(args.cases.parent / "host-dispositions.json"),
                        "--report", str(args.output / "host-comparison.json")]).returncode
sys.exit(formulas or hosts)
