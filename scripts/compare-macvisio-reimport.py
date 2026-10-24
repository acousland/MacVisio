#!/usr/bin/env python3
"""Reverse-direction (Visio -> MacVisio) comparison for the public interchange corpus (WP-03-T03).

For each fixture, MacVisio reads the authored public file and the copy Visio edited and saved during
the Windows acceptance run. Both readings must agree on pages, shapes, connectors, geometry and text,
except for the single text edit Visio made. Fixtures carry no MacVisio private metadata (they are
validation copies), so the Visio-saved reading depends only on public content. Reference-side phase
failures from the Windows report are carried into this report rather than hidden.
"""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

MARKER = " [MacVisio differential smoke]"
TOLERANCE = 1e-6


def dump(app: Path, drawing: Path, output: Path) -> dict:
    result = subprocess.run([str(app), "--dump-model", str(drawing), str(output)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise RuntimeError(f"MacVisio could not read {drawing.name}: {(result.stderr or result.stdout).strip()}")
    return json.loads(output.read_text())


def close(a, b) -> bool:
    return isinstance(a, (int, float)) and isinstance(b, (int, float)) and math.isclose(a, b, rel_tol=TOLERANCE, abs_tol=TOLERANCE * 72)


def compare(name: str, original: dict, saved: dict, edited_text: str | None) -> list[dict]:
    issues: list[dict] = []
    def issue(path, expected, actual):
        issues.append({"file": name, "path": path, "expected": expected, "actual": actual})
    if len(original["pages"]) != len(saved["pages"]):
        issue("pageCount", len(original["pages"]), len(saved["pages"]))
    edits = 0
    # Visio normalises page order on save (background pages move); pair pages by name.
    by_name = {page["name"]: page for page in saved["pages"]}
    pairs = [(page, by_name.get(page["name"])) for page in original["pages"]]
    for page in original["pages"]:
        if page["name"] not in by_name:
            issue(f"page/{page['name']}", "present after Visio save", None)
    for index, (a, b) in enumerate(((x, y) for x, y in pairs if y is not None), 1):
        page = f"page/{index}"
        for key in ("name", "isBackground", "width", "height"):
            if a.get(key) != b.get(key) and not close(a.get(key), b.get(key)):
                issue(f"{page}/{key}", a.get(key), b.get(key))
        if len(a["nodes"]) != len(b["nodes"]):
            issue(f"{page}/nodeCount", len(a["nodes"]), len(b["nodes"]))
        if len(a["edges"]) != len(b["edges"]):
            issue(f"{page}/edgeCount", len(a["edges"]), len(b["edges"]))
        index_a = {node["id"]: i for i, node in enumerate(a["nodes"])}
        index_b = {node["id"]: i for i, node in enumerate(b["nodes"])}
        for position, (x, y) in enumerate(zip(a["nodes"], b["nodes"]), 1):
            shape = f"{page}/node/{position}"
            for key in ("kind", "x", "y", "width", "height", "rotation", "locked"):
                if x.get(key) != y.get(key) and not close(x.get(key), y.get(key)):
                    issue(f"{shape}/{key}", x.get(key), y.get(key))
            parent_a = index_a.get(x.get("parentID")) if x.get("parentID") else None
            parent_b = index_b.get(y.get("parentID")) if y.get("parentID") else None
            if parent_a != parent_b:
                issue(f"{shape}/parentIndex", parent_a, parent_b)
            if x.get("text") != y.get("text"):
                if edited_text is not None and y.get("text") == edited_text and edited_text == (x.get("text") or "") + MARKER:
                    edits += 1
                else:
                    issue(f"{shape}/text", x.get("text"), y.get("text"))
        for position, (x, y) in enumerate(zip(a["edges"], b["edges"]), 1):
            edge = f"{page}/edge/{position}"
            for key in ("source", "target"):
                if index_a.get(x.get(key)) != index_b.get(y.get(key)):
                    issue(f"{edge}/{key}Index", index_a.get(x.get(key)), index_b.get(y.get(key)))
            if (x.get("label") or "") != (y.get("label") or ""):
                if not (edited_text is not None and y.get("label") == edited_text and edited_text == (x.get("label") or "") + MARKER):
                    issue(f"{edge}/label", x.get("label"), y.get("label"))
                else:
                    edits += 1
    if edited_text is not None and edits != 1:
        issue("edit", "exactly one shape text edited by Visio", edits)
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="MacVisio executable providing --dump-model")
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--windows-report", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True, help="Windows artifacts directory containing files/<case>/saved")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    reference = json.loads(args.windows_report.read_text(encoding="utf-8-sig"))
    files, differences, reference_failures = [], [], []
    with tempfile.TemporaryDirectory(prefix="macvisio-reimport-") as scratch:
        scratch = Path(scratch)
        for result in reference["files"]:
            name = result["file"]
            failed = {phase: data.get("error") for phase, data in result["phases"].items() if data.get("status") == "failed"}
            if failed:
                reference_failures.append({"file": name, "failedPhases": failed})
            saved_rel = (result["phases"].get("saveAs") or {}).get("path")
            saved = next(iter(sorted((args.artifacts / "files").glob(f"*/saved/{name}"))), None) if saved_rel else None
            if result["phases"].get("saveAs", {}).get("status") != "passed" or saved is None:
                files.append({"file": name, "status": "not_compared", "reason": "Visio did not save this fixture"})
                continue
            mutation = result["phases"].get("mutation") or {}
            edited = mutation.get("newValue") if mutation.get("status") == "passed" else None
            try:
                original = dump(args.app, args.fixtures / name, scratch / (name + ".original.json"))
                visio = dump(args.app, saved, scratch / (name + ".visio.json"))
            except RuntimeError as error:
                files.append({"file": name, "status": "failed", "reason": str(error)})
                differences.append({"file": name, "path": "read", "expected": "readable", "actual": str(error)})
                continue
            found = compare(name, original, visio, edited)
            differences += found
            files.append({"file": name, "status": "passed" if not found else "failed", "differences": len(found),
                          "pages": len(visio["pages"]), "editVerified": edited is not None})
    compared = [f for f in files if f["status"] != "not_compared"]
    report = {"schemaVersion": 1, "direction": "Visio-saved -> MacVisio reimport", "reference": reference.get("environment"),
              "matched": bool(compared) and not differences, "compared": len(compared), "files": files,
              "differences": differences, "referenceFailures": reference_failures}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(f"Reimport comparison: {len(compared)} compared, {len(differences)} difference(s), {len(reference_failures)} reference-side failure(s).")
    return 0 if report["matched"] else 1


if __name__ == "__main__":
    sys.exit(main())
