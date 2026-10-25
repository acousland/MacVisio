#!/usr/bin/env python3
"""MacVisio-authored drawings in Visio 2019 (M3, G2, WP-20-T04 C001).

MacVisio writes its five templates (--generate-examples) and the M3 intelligent fixtures; the private
metadata part is removed so only public content travels. Visio opens and describes each drawing
(Snapshot-VisioDrawings.ps1), and the comparison checks that Visio sees what MacVisio's model of the
same public file says: page names and kinds, shape text, positions and sizes, connector endpoints,
Shape Data rows and text field formulas.
"""
import argparse, json, math, shutil, subprocess, sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "windows"))
sys.path.insert(0, str(ROOT / "scripts"))
import visio_guest
from importlib import import_module
strip_private = import_module("run-roundtrip-reference").strip_private


def close(a, b, tolerance=1e-3):
    return a is not None and b is not None and math.isclose(a, b, abs_tol=tolerance)


def compare(model: dict, visio: dict) -> list[str]:
    out = []
    pages = [p for p in model["pages"]]
    vpages = visio["pages"]
    # Visio keeps foreground pages first and background pages after them.
    order = lambda items, background: [p["name"] for p in items if bool(background(p))]
    for kind in (False, True):
        mine, theirs = order(pages, lambda p: p.get("isBackground")), order(vpages, lambda p: p["background"])
        mine = [n for n in [p["name"] for p in pages] if bool(next(q for q in pages if q["name"] == n).get("isBackground")) == kind]
        theirs = [n for n in [p["name"] for p in vpages] if next(q for q in vpages if q["name"] == n)["background"] == kind]
        if mine != theirs:
            out.append(f"{'background' if kind else 'foreground'} pages {mine} became {theirs}")
    by_name = {p["name"]: p for p in vpages}
    for page in pages:
        vpage = by_name.get(page["name"])
        if vpage is None: continue
        if bool(page.get("isBackground")) != vpage["background"]:
            out.append(f"{page['name']}: background {page.get('isBackground')} became {vpage['background']}")
        height = page["height"]
        nodes = {n["id"]: n for n in page["nodes"]}
        shapes = [s for s in vpage["shapes"] if not s["oneD"]]
        by_text = {}
        for s in shapes:
            by_text.setdefault(s["text"], []).append(s)
        texts = Counter(n["text"] for n in page["nodes"] if not n.get("parentID"))
        vtexts = Counter(s["text"] for s in shapes if s["parent"] is None)
        if texts != vtexts:
            out.append(f"{page['name']}: shape texts differ: missing {dict(texts - vtexts)}, extra {dict(vtexts - texts)}")
        for node in page["nodes"]:
            if node.get("parentID") or not node["text"] or len(by_text.get(node["text"], [])) != 1:
                continue
            cells = by_text[node["text"]][0]["cells"]
            expected = {"Width": node["width"] / 72, "Height": node["height"] / 72,
                        "PinX": (node["x"] + node["width"] / 2) / 72, "PinY": (height - node["y"] - node["height"] / 2) / 72}
            if node.get("rotation", 0) == 0:
                for name, value in expected.items():
                    actual = cells.get(name, {}).get("value")
                    if not close(actual, value):
                        out.append(f"{page['name']}/{node['text']!r}: {name} {value:.4f} became {actual}")
            details = node.get("details") or {}
            data = sorted(d["key"] for d in details.get("data", []))
            vdata = sorted(by_text[node["text"]][0]["data"].keys())
            if data != vdata:
                out.append(f"{page['name']}/{node['text']!r}: data rows {data} became {vdata}")
            fields = len(details.get("textFields") or [])
            if fields != len(by_text[node["text"]][0]["fieldFormulas"]):
                out.append(f"{page['name']}/{node['text']!r}: {fields} fields became {len(by_text[node['text']][0]['fieldFormulas'])}")
        ids = {s["id"]: s for s in vpage["shapes"]}
        ends = {}
        for c in vpage["connects"]:
            ends.setdefault(c["from"], {})["begin" if c["fromCell"].startswith("Begin") else "end"] = ids.get(c["to"], {}).get("text")
        # Unglued one-dimensional shapes (lines, arcs) have no Connect records.
        expected_edges = Counter((nodes.get(e["source"], {}).get("text"), nodes.get(e["target"], {}).get("text")) for e in page["edges"]
                                 if e["source"] in nodes or e["target"] in nodes)
        actual_edges = Counter((e.get("begin"), e.get("end")) for e in ends.values())
        if expected_edges != actual_edges:
            out.append(f"{page['name']}: connections differ: missing {dict(expected_edges - actual_edges)}, extra {dict(actual_edges - expected_edges)}")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/debug/MacVisio")
    parser.add_argument("--output", type=Path, default=ROOT / "build/m3/authored")
    args = parser.parse_args()
    drawings = args.output / "drawings"
    shutil.rmtree(drawings, ignore_errors=True); drawings.mkdir(parents=True)
    examples = args.output / "examples"
    subprocess.run([str(args.app), "--generate-examples", str(examples)], check=True, capture_output=True)
    # MacVisio's templates, and Visio-authored drawings rewritten from MacVisio's model alone (its own
    # serializer for masters, fields, connectors, layers and pages, with no retained source package).
    fresh = args.output / "fresh.json"
    fresh.write_text('[{"op": "fresh"}]')
    targets = []
    for source in sorted(examples.glob("*.vsdx")):
        target = drawings / f"mac-{source.stem}.vsdx"; shutil.copy(source, target); targets.append(target)
    for source in sorted((ROOT / "Tests/MacVisioTests/Fixtures/Reference").glob("visio-*.vsdx")):
        target = drawings / f"mac-fresh-{source.stem.removeprefix('visio-')}.vsdx"
        subprocess.run([str(args.app), "--apply-edits", str(source), str(fresh), str(target)], check=True, capture_output=True)
        targets.append(target)
    for target in targets:
        source = target
        strip_private(target)
        subprocess.run([str(args.app), "--dump-model", str(target), str(drawings / f"{target.stem}.json")], check=True, capture_output=True)
    code = visio_guest.run(ROOT / "scripts/windows/Snapshot-VisioDrawings.ps1", sorted(drawings.glob("*.vsdx")), drawings, timeout=1800)
    if code:
        sys.exit(f"Visio snapshot failed ({code})")
    snapshots = json.loads((drawings / "snapshots.json").read_text(encoding="utf-8-sig"))
    report, failures = {"visioVersion": snapshots.get("visioVersion"), "errors": snapshots.get("errors"), "drawings": {}}, 0
    for path in sorted(drawings.glob("*.vsdx")):
        model = json.loads((drawings / f"{path.stem}.json").read_text())
        model = model.get("diagram", model)
        visio = snapshots["drawings"].get(path.name)
        differences = ["Visio could not open the drawing"] if visio is None else compare(model, visio)
        report["drawings"][path.name] = differences
        failures += bool(differences)
        print(f"{path.name}: {len(differences)} differences")
    report["passed"] = failures == 0 and not snapshots.get("errors")
    (args.output / "comparison.json").write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
