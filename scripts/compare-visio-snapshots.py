#!/usr/bin/env python3
"""Compare Visio's snapshots of Visio-authored drawings with its snapshots after a MacVisio round trip.

An unchanged round trip (mac-<name>-unchanged.vsdx) must leave everything Visio reports identical.
An edited round trip (mac-<name>-<edit>.vsdx) may differ only where edits.json says the edit acts,
plus the routes of connectors glued to a moved or resized shape. Every other difference is reported.
"""
from __future__ import annotations
import argparse, json, math, sys
from pathlib import Path

ROUTE_CELLS = {"BeginX", "BeginY", "EndX", "EndY", "PinX", "PinY", "Width", "Height", "Angle", "LocPinX", "LocPinY", "TxtPinX", "TxtPinY", "TxtWidth", "TxtHeight"}


def same(a, b) -> bool:
    if isinstance(a, float) or isinstance(b, float):
        try: return math.isclose(float(a), float(b), rel_tol=1e-9, abs_tol=1e-6)
        except (TypeError, ValueError): return a == b
    return a == b


def diff(a, b, path: str, out: list[str]) -> None:
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a: out.append(f"{path}.{key}: added {json.dumps(b[key])[:120]}")
            elif key not in b: out.append(f"{path}.{key}: removed {json.dumps(a[key])[:120]}")
            else: diff(a[key], b[key], f"{path}.{key}", out)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b): out.append(f"{path}: {len(a)} items became {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)): diff(x, y, f"{path}[{i}]", out)
    elif not same(a, b):
        out.append(f"{path}: {json.dumps(a)[:100]} became {json.dumps(b)[:100]}")


def index(drawing: dict) -> dict:
    """Pages by name; shapes by ID within each page, so order changes are not differences."""
    pages = {}
    for page in drawing["pages"]:
        shapes = {s["id"]: s for s in page["shapes"]}
        connects = sorted(json.dumps(c, sort_keys=True) for c in page["connects"])
        pages[page["name"]] = {"page": {k: v for k, v in page.items() if k not in ("shapes", "connects", "index")}, "shapes": shapes, "connects": connects}
    return {"pages": pages, "masters": sorted(json.dumps(m, sort_keys=True) for m in drawing["masters"]),
            "styles": sorted(drawing["styles"]), "user": drawing["user"]}


def compare_drawings(authored: dict, roundtrip: dict, allow: list[dict]) -> list[str]:
    before, after, out = index(authored), index(roundtrip), []
    allowed_pages = {a.get("page") for a in allow if a.get("op") in ("renamePage", "addPage")}
    moved = {(a.get("page"), a.get("shape")) for a in allow if a.get("op") in ("move", "resize")}
    for name in sorted(set(before["pages"]) | set(after["pages"])):
        if name not in after["pages"]:
            if name not in allowed_pages: out.append(f"page {name!r} missing after round trip")
            continue
        if name not in before["pages"]:
            if not any(a.get("op") == "addPage" and a.get("name") == name or a.get("op") == "renamePage" and a.get("name") == name for a in allow):
                out.append(f"page {name!r} added by round trip")
            continue
        b, r = before["pages"][name], after["pages"][name]
        page_diffs: list[str] = []
        diff(b["page"], r["page"], f"{name}", page_diffs)
        if any(a.get("op") == "layerVisible" and a.get("page") == name for a in allow):
            page_diffs = [d for d in page_diffs if not d.startswith(f"{name}.layers")]
        out.extend(page_diffs)
        glued = {c["from"] for c in map(json.loads, b["connects"]) if (name, c["to"]) in moved}
        targets = {a.get("shape") for a in allow if a.get("page") == name}
        for shape_id in sorted(set(b["shapes"]) | set(r["shapes"]), key=lambda s: int(s)):
            if shape_id not in r["shapes"]:
                out.append(f"{name}/{shape_id} ({b['shapes'][shape_id]['nameU']}) missing"); continue
            if shape_id not in b["shapes"]:
                if not any(a.get("op") in ("connect", "addShape") and a.get("page") == name for a in allow):
                    out.append(f"{name}/{shape_id} ({r['shapes'][shape_id]['nameU']}) added")
                continue
            local: list[str] = []
            diff(b["shapes"][shape_id], r["shapes"][shape_id], f"{name}/{shape_id}", local)
            if shape_id in targets: continue
            if shape_id in glued: local = [d for d in local if not any(f".cells.{c}." in d for c in ROUTE_CELLS) and ".geometry" not in d]
            out.extend(local)
        if b["connects"] != r["connects"] and not any(a.get("op") in ("connect", "delete") for a in allow if a.get("page") == name):
            out.append(f"{name} connects changed: {sorted(set(b['connects']) ^ set(r['connects']))[:4]}")
    for key in ("masters", "styles", "user"):
        diff(before[key], after[key], key, out)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authored", type=Path, required=True)
    parser.add_argument("--roundtrip", type=Path, required=True)
    parser.add_argument("--edits", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    authored = json.loads(args.authored.read_text(encoding="utf-8-sig"))
    roundtrip = json.loads(args.roundtrip.read_text(encoding="utf-8-sig"))
    edits = json.loads(args.edits.read_text()) if args.edits.exists() else {}
    results, failures = {}, 0
    for file, drawing in sorted(roundtrip["drawings"].items()):
        stem = file.removesuffix(".vsdx").removeprefix("mac-")
        name, _, edit = stem.partition("-")
        for recipe in authored["drawings"]:
            recipe_name = recipe.removesuffix(".vsdx").removeprefix("visio-")
            if stem.startswith(recipe_name + "-"):
                name, edit = recipe_name, stem[len(recipe_name) + 1:]
        source = authored["drawings"].get(f"visio-{name}.vsdx")
        if source is None: continue
        allow = [] if edit == "unchanged" else edits.get(name, {}).get(edit, [])
        differences = compare_drawings(source, drawing, allow)
        results[file] = {"recipe": name, "edit": edit, "differences": differences}
        failures += bool(differences)
    errors = roundtrip.get("errors", []) + authored.get("errors", [])
    report = {"schemaVersion": 1, "visioVersion": roundtrip.get("visioVersion"), "drawings": results, "errors": errors,
              "passed": failures == 0 and not errors}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n")
    for file, result in results.items():
        print(f"{file}: {len(result['differences'])} differences")
    if errors: print("errors:", json.dumps(errors)[:400])
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
