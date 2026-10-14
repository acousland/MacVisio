#!/usr/bin/env python3
"""Compare direct public cached content before/after a Windows Visio round trip.

This intentionally does not inspect MacVisio metadata. It is a bounded semantic
check for the synthetic corpus, not a renderer or a full master/style evaluator.
"""
import argparse
import json
import math
import os
import posixpath
import sys
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

NS = "{http://schemas.microsoft.com/office/visio/2012/main}"
REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"
RID = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
TYPE = "http://schemas.microsoft.com/visio/2010/relationships/"
CELLS = ("PinX", "PinY", "Width", "Height", "LocPinX", "LocPinY", "Angle", "FlipX", "FlipY")
PAGE_CELLS = ("PageWidth", "PageHeight", "PageScale", "DrawingScale")


def resolved(source, target):
    if "\\" in target or ":" in target:
        raise ValueError("Unsupported package relationship target")
    name = posixpath.normpath(target.lstrip("/") if target.startswith("/") else posixpath.join(posixpath.dirname(source), target))
    if name == ".." or name.startswith("../"):
        raise ValueError("Package relationship escapes its root")
    return name


def relpart(source):
    return posixpath.join(posixpath.dirname(source), "_rels", posixpath.basename(source) + ".rels") if source else "_rels/.rels"


def snapshot(path):
    if path.stat().st_size > 100 * 1024 * 1024:
        raise ValueError("Package exceeds supported size")
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 10000 or len({entry.filename for entry in entries}) != len(entries):
            raise ValueError("Too many or duplicate ZIP entries")
        if sum(entry.file_size for entry in entries) > 128 * 1024 * 1024 or any(entry.file_size > 16 * 1024 * 1024 for entry in entries):
            raise ValueError("Expanded package exceeds supported size")

        def xml(name):
            data = archive.read(name)
            if b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
                raise ValueError("DTD/entity declarations are unsupported")
            return ET.fromstring(data.decode("utf-8-sig"))

        def relations(source):
            return {r.attrib["Id"]: r for r in xml(relpart(source)).findall(REL + "Relationship")}

        def related(source, kind):
            matches = [r for r in relations(source).values() if r.get("Type") == TYPE + kind and r.get("TargetMode") != "External"]
            if len(matches) != 1:
                raise ValueError("Missing or ambiguous " + kind + " relationship")
            return resolved(source, matches[0].attrib["Target"])

        def cells(element, names):
            values = {cell.attrib["N"]: cell.get("V", "") for cell in element.findall(NS + "Cell")} if element is not None else {}
            result = {}
            for name in names:
                if name in values:
                    value = float(values[name])
                    if not math.isfinite(value):
                        raise ValueError("Nonfinite cached cell")
                    result[name] = value
            return result

        document = related("", "document")
        if xml(document).tag != NS + "VisioDocument":
            raise ValueError("The document relationship does not reference a Visio document")
        pages_part = related(document, "pages")
        pages_rels = relations(pages_part)
        pages = {}
        pages_root = xml(pages_part)
        if pages_root.tag != NS + "Pages":
            raise ValueError("Invalid Visio pages root")
        for page in pages_root.findall(NS + "Page"):
            identifier = page.attrib["ID"]
            if identifier in pages:
                raise ValueError("Duplicate page identifier")
            relation = pages_rels[page.find(NS + "Rel").attrib[RID]]
            if relation.get("TargetMode") == "External":
                raise ValueError("External page relationship")
            shapes = {}

            def visit(container, parent=None, depth=0):
                if container is None:
                    return
                if depth > 64:
                    raise ValueError("Shape nesting exceeds supported depth")
                for shape in container.findall(NS + "Shape"):
                    shape_id = shape.attrib["ID"]
                    if shape_id in shapes:
                        raise ValueError("Duplicate shape identifier")
                    text = shape.find(NS + "Text")
                    shapes[shape_id] = {"parentID": parent, "text": "".join(text.itertext()) if text is not None else "", "cells": cells(shape, CELLS)}
                    visit(shape.find(NS + "Shapes"), shape_id, depth + 1)

            page_contents = xml(resolved(pages_part, relation.attrib["Target"]))
            if page_contents.tag != NS + "PageContents":
                raise ValueError("Invalid Visio page contents root")
            visit(page_contents.find(NS + "Shapes"))
            pages[identifier] = {"name": page.get("Name", ""), "background": page.get("Background", "0") in ("1", "true"), "backPage": page.get("BackPage"), "cells": cells(page.find(NS + "PageSheet"), PAGE_CELLS), "shapes": shapes}
        if not pages:
            raise ValueError("A drawing must contain at least one page")
        return pages


def compare(before, after, tolerance):
    changes = []

    def difference(path, expected, actual):
        changes.append({"path": path, "expected": expected, "actual": actual})

    def cell_values(path, expected, actual):
        # Only assert cells explicitly authored in the baseline. Visio may add defaults.
        for cell, value in expected.items():
            current = actual.get(cell)
            if current is None or not math.isclose(value, current, rel_tol=tolerance, abs_tol=tolerance):
                difference(path + "/" + cell, value, current)

    if set(before) != set(after):
        difference("pages", sorted(before), sorted(after))
    elif list(before) != list(after):
        difference("pageOrder", list(before), list(after))
    for page_id in before.keys() & after.keys():
        old, new = before[page_id], after[page_id]
        path = "page/" + page_id
        for key in ("name", "background", "backPage"):
            if old[key] != new[key]:
                difference(path + "/" + key, old[key], new[key])
        cell_values(path + "/cells", old["cells"], new["cells"])
        if set(old["shapes"]) != set(new["shapes"]):
            difference(path + "/shapes", sorted(old["shapes"]), sorted(new["shapes"]))
        elif list(old["shapes"]) != list(new["shapes"]):
            difference(path + "/shapeOrder", list(old["shapes"]), list(new["shapes"]))
        for shape_id in old["shapes"].keys() & new["shapes"].keys():
            a, b = old["shapes"][shape_id], new["shapes"][shape_id]
            shape_path = path + "/shape/" + shape_id
            for key in ("text", "parentID"):
                if a[key] != b[key]:
                    difference(shape_path + "/" + key, a[key], b[key])
            cell_values(shape_path + "/cells", a["cells"], b["cells"])
    return sorted(changes, key=lambda change: change["path"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--tolerance", type=float, default=1e-7)
    args = parser.parse_args()
    if not math.isfinite(args.tolerance) or not 0 <= args.tolerance <= 0.01:
        parser.error("tolerance must be finite and between zero and 0.01")
    if args.report.resolve() in (args.before.resolve(), args.after.resolve()) or (args.report.exists() and any(args.report.samefile(path) for path in (args.before, args.after) if path.exists())):
        parser.error("report must not replace an input drawing")
    try:
        changes = compare(snapshot(args.before), snapshot(args.after), args.tolerance)
        result = {"schemaVersion": 1, "scope": "Direct cached public page/shape content only; no inherited master/style, formula execution or visual equivalence assertion", "matched": not changes, "differences": changes}
        # Replace atomically so an existing hard link or symlink cannot make report
        # writing truncate an unrelated drawing.
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=args.report.parent, prefix=".visio-comparison-", delete=False) as handle:
                temporary = Path(handle.name)
                json.dump(result, handle, indent=2, ensure_ascii=False)
                handle.write("\n")
            os.replace(temporary, args.report)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        print(f"Public cached comparison: {len(changes)} difference(s). Details written to the report.")
        return 1 if changes else 0
    except (OSError, ValueError, KeyError, AttributeError, ET.ParseError, zipfile.BadZipFile, RuntimeError) as error:
        print(f"Comparison failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
