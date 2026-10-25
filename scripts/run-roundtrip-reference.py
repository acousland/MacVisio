#!/usr/bin/env python3
"""Round-trip reference (M3, G2): Visio-authored drawings through MacVisio and back to Visio.

1. In the reference guest, Visio authors the recipe drawings (scripts/windows/VisioRecipes.ps1) and
   snapshots them (Snapshot-VisioDrawings.ps1).
2. MacVisio opens each drawing and saves it unchanged and with scripted edits (--apply-edits), with
   its private metadata part removed so only public content travels.
3. Visio snapshots MacVisio's output. compare-visio-snapshots.py reports every difference Visio
   sees between the original and the round-tripped drawing, and checks edits changed only their
   targets.
"""
import argparse, json, shutil, subprocess, sys, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "windows"))
import visio_guest

RECIPES = ["flowchart", "intelligent", "structure", "pages"]


def strip_private(path: Path) -> None:
    """Remove MacVisio's private metadata so Visio (and any reader) sees public content only."""
    temporary = path.with_suffix(".tmp")
    with zipfile.ZipFile(path) as source, zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as target:
        for item in source.infolist():
            if item.filename.startswith("macvisio/"):
                continue
            data = source.read(item.filename)
            if item.filename == "_rels/.rels":
                data = data.replace(b'<Relationship Id="rIdMacVisio" Type="urn:macvisio:relationships:diagram" Target="macvisio/document.json"/>', b"")
            target.writestr(item, data)
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/debug/MacVisio")
    parser.add_argument("--output", type=Path, default=ROOT / "build/m3/roundtrip")
    parser.add_argument("--edits", type=Path, default=ROOT / "docs/evidence/reference/roundtrip/edits.json")
    parser.add_argument("--recipes", default=",".join(RECIPES))
    parser.add_argument("--skip-authoring", action="store_true", help="Reuse the Visio-authored drawings and snapshots already in --output")
    args = parser.parse_args()
    authored, mac = args.output / "visio", args.output / "macvisio"
    for folder in (authored, mac):
        folder.mkdir(parents=True, exist_ok=True)
    windows = ROOT / "scripts/windows"
    if not args.skip_authoring:
        code = visio_guest.run(windows / "Snapshot-VisioDrawings.ps1", [windows / "VisioRecipes.ps1"], authored,
                               arguments={"Build": args.recipes, "Recipes": "VisioRecipes.ps1"}, timeout=1800)
        if code:
            sys.exit(f"Visio authoring failed ({code}); see {authored}")
    edits = json.loads(args.edits.read_text()) if args.edits.exists() else {}
    for drawing in sorted(authored.glob("visio-*.vsdx")):
        name = drawing.stem.removeprefix("visio-")
        unchanged = mac / f"mac-{name}-unchanged.vsdx"
        subprocess.run([str(args.app), "--convert", str(drawing), str(unchanged)], check=True, capture_output=True)
        strip_private(unchanged)
        for edit_name, operations in edits.get(name, {}).items():
            spec = mac / f"{name}-{edit_name}.json"
            spec.write_text(json.dumps(operations, indent=1))
            edited = mac / f"mac-{name}-{edit_name}.vsdx"
            subprocess.run([str(args.app), "--apply-edits", str(drawing), str(spec), str(edited)], check=True, capture_output=True)
            strip_private(edited)
    code = visio_guest.run(windows / "Snapshot-VisioDrawings.ps1", sorted(mac.glob("*.vsdx")), mac, timeout=1800)
    if code:
        sys.exit(f"Visio snapshot of MacVisio output failed ({code})")
    return subprocess.run([sys.executable, str(ROOT / "scripts/compare-visio-snapshots.py"), "--authored", str(authored / "snapshots.json"),
                           "--roundtrip", str(mac / "snapshots.json"), "--edits", str(args.edits), "--report", str(args.output / "comparison.json")]).returncode


if __name__ == "__main__":
    sys.exit(main())
