#!/usr/bin/env python3
"""Check a real Windows Visio runner report against synthetic authored expectations."""
import argparse
import copy
import json
import math
import os
import sys
import tempfile
from pathlib import Path


def assess(manifest, report, tolerance=1e-7):
    issues = []

    def issue(file, phase, path, expected, actual):
        issues.append({"file": file, "phase": phase, "path": path, "expected": expected, "actual": actual})

    fixtures = manifest.get("fixtures", [])
    results = report.get("files", [])
    if manifest.get("schemaVersion") != 1 or report.get("schemaVersion") != 1 or not fixtures:
        raise ValueError("Unsupported or empty comparison manifest/report")
    if len({f["file"] for f in fixtures}) != len(fixtures) or len({f["file"] for f in results}) != len(results):
        raise ValueError("Duplicate fixture or result filenames")
    by_file = {result["file"]: result for result in results}
    if not report.get("environment", {}).get("visioVersion"):
        issue("*", "environment", "visioVersion", "an observed version", None)
    if report.get("status") != "passed":
        issue("*", "execution", "status", "passed", report.get("status"))

    def same(file, phase, path, expected, actual):
        if isinstance(expected, (int, float)) and not isinstance(expected, bool):
            equal = isinstance(actual, (int, float)) and not isinstance(actual, bool) and math.isfinite(actual) and math.isclose(expected, actual, rel_tol=tolerance, abs_tol=tolerance)
        else:
            equal = expected == actual
        if not equal:
            issue(file, phase, path, expected, actual)

    def pages(file, phase, expected, actual):
        if not isinstance(actual, list):
            issue(file, phase, "pages", "page snapshots", actual)
            return
        same(file, phase, "pageCount", len(expected), len(actual))
        for index, (old, new) in enumerate(zip(expected, actual), 1):
            path = "page/" + str(index)
            for key in ("index", "name", "background", "width", "height"):
                same(file, phase, path + "/" + key, old[key], new.get(key))
            expected_shapes = old.get("shapes", [])
            actual_shapes = new.get("shapes", [])
            if not isinstance(actual_shapes, list):
                issue(file, phase, path + "/shapes", "shape snapshots", actual_shapes)
                continue
            same(file, phase, path + "/shapeOrder", [str(s["id"]) for s in expected_shapes], [str(s.get("id")) for s in actual_shapes])
            shapes_by_id = {str(shape.get("id")): shape for shape in actual_shapes}
            if len(shapes_by_id) != len(actual_shapes):
                issue(file, phase, path + "/shapes", "unique shape IDs", "duplicate IDs")
            for shape in expected_shapes:
                shape_id = str(shape["id"])
                current = shapes_by_id.get(shape_id)
                if current is None:
                    continue  # The missing shape is already reported in shapeOrder.
                shape_path = path + "/shape/" + shape_id
                for key in ("text", "parentID"):
                    same(file, phase, shape_path + "/" + key, shape[key], current.get(key))
                for key, value in shape.get("cells", {}).items():
                    same(file, phase, shape_path + "/cells/" + key, value, current.get("cells", {}).get(key))

    for fixture in fixtures:
        file = fixture["file"]
        result = by_file.get(file)
        if result is None:
            issue(file, "execution", "result", "executed fixture", None)
            continue
        same(file, "execution", "inputSha256", fixture["sha256"], result.get("inputSha256"))
        same(file, "execution", "status", "passed", result.get("status"))
        expected = fixture["expected"]["pages"]
        phases = result.get("phases", {})
        for name in ("open", "inspect", "saveAs", "close", "reopen", "exportPdf", "exportSvg"):
            same(file, name, "status", "passed", phases.get(name, {}).get("status"))
        pages(file, "inspect", expected, phases.get("inspect", {}).get("pages"))
        edited = copy.deepcopy(expected)
        mutation = phases.get("mutation", {})
        shape_count = sum(len(page.get("shapes", [])) for page in expected)
        if shape_count:
            same(file, "mutation", "status", "passed", mutation.get("status"))
            target = None
            for page in edited:
                if page["index"] == mutation.get("pageIndex"):
                    target = next((shape for shape in page.get("shapes", []) if str(shape["id"]) == str(mutation.get("shapeId"))), None)
            key = mutation.get("property")
            if target is None or key not in ("text", "PinX", "PinY", "Width", "Height", "Angle"):
                issue(file, "mutation", "target", "a supported property of an existing shape", mutation)
            else:
                values = target if key == "text" else target.get("cells", {})
                if key in values:
                    same(file, "mutation", "originalValue", values[key], mutation.get("originalValue"))
                if mutation.get("originalValue") == mutation.get("newValue"):
                    issue(file, "mutation", "newValue", "a changed value", mutation.get("newValue"))
                values[key] = mutation.get("newValue")
                if key != "text":
                    target["cells"] = values
        else:
            same(file, "mutation", "status", "skipped", mutation.get("status"))
        pages(file, "reopen", edited, phases.get("reopen", {}).get("pages"))
    extra = sorted(set(by_file) - {fixture["file"] for fixture in fixtures})
    if extra:
        issue("*", "execution", "unexpectedFiles", [], extra)
    return {"schemaVersion": 1, "matched": not issues, "fixtures": len(fixtures),
        "scope": "Windows open/edit/save/reopen and authored cached public content only; rendered fidelity and complete Visio parity are separate acceptance criteria",
        "differences": issues}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("windows_report", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.report.resolve() in (args.manifest.resolve(), args.windows_report.resolve()):
        parser.error("output must differ from input reports")
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8-sig"))
        windows = json.loads(args.windows_report.read_text(encoding="utf-8-sig"))
        result = assess(manifest, windows)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=args.report.parent, prefix=".visio-windows-comparison-", delete=False) as handle:
                temporary = Path(handle.name)
                json.dump(result, handle, indent=2, ensure_ascii=False, allow_nan=False)
                handle.write("\n")
            os.replace(temporary, args.report)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        print(f"Windows content comparison: {len(result['differences'])} difference(s) across {result['fixtures']} fixtures.")
        return 0 if result["matched"] else 1
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"Comparison failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
