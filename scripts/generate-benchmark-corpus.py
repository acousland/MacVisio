#!/usr/bin/env python3
"""Generate deterministic public VSDX performance inputs; never reads source drawings."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import posixpath
import re
import struct
import zipfile
import zlib
from pathlib import Path
from xml.etree import ElementTree as ET

NS = "http://schemas.microsoft.com/office/visio/2012/main"
RNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PNS = "http://schemas.openxmlformats.org/package/2006/relationships"
CTNS = "http://schemas.openxmlformats.org/package/2006/content-types"
TYPE = "http://schemas.microsoft.com/visio/2010/relationships/"
VARIANTS = ("balanced", "formula-heavy", "image-heavy", "hierarchy")
COUNTS = ("objects", "shapes", "connectors", "formulaCells", "images", "maxGroupDepth")
ET.register_namespace("", NS)
ET.register_namespace("r", RNS)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def finite_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("Nonfinite JSON number")
    return value


def parse_json(text):
    def reject_constant(value):
        raise ValueError(f"Nonfinite JSON constant: {value}")
    return json.loads(text, object_pairs_hook=unique_object, parse_float=finite_float, parse_constant=reject_constant)


def element(name, attributes=None, parent=None, ns=NS):
    node = ET.Element(f"{{{ns}}}{name}", {k: str(v) for k, v in (attributes or {}).items()})
    if parent is not None:
        parent.append(node)
    return node


def xml(root):
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def cell(parent, name, value, formula=None):
    attrs = {"N": name, "V": value}
    if formula is not None:
        attrs["F"] = formula
    return element("Cell", attrs, parent)


def relations(items):
    root = element("Relationships", ns=PNS)
    for rid, kind, target in items:
        element("Relationship", {"Id": rid, "Type": kind, "Target": target}, root, PNS)
    return xml(root)


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    pixels = b"".join(b"\x00" + bytes(c for x in range(16) for c in ((x * 17), (y * 17), ((x + y) * 8))) for y in range(16))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels, 9)) + chunk(b"IEND", b"")


def public_summary(parts):
    pages = ET.fromstring(parts["visio/pages/pages.xml"])
    counts = dict.fromkeys(COUNTS, 0)
    expected = []
    for index, page in enumerate(pages, 1):
        shapes = []
        def visit(container, parent=None, depth=0):
            if container is None:
                return
            for shape in container.findall(f"{{{NS}}}Shape"):
                sid = shape.get("ID")
                cells = {c.get("N"): float(c.get("V")) for c in shape.findall(f"{{{NS}}}Cell")}
                text = shape.find(f"{{{NS}}}Text")
                shapes.append({"id": sid, "parentID": parent, "text": "" if text is None else "".join(text.itertext()),
                               "cells": {k: v for k, v in cells.items() if k in ("PinX", "PinY", "Width", "Height", "LocPinX", "LocPinY", "Angle", "FlipX", "FlipY")}})
                connector = cells.get("ObjType") == 2 and "BeginX" in cells and "EndX" in cells
                counts["objects"] += 1
                counts["connectors" if connector else "shapes"] += 1
                counts["images"] += shape.find(f"{{{NS}}}ForeignData") is not None
                counts["formulaCells"] += sum("F" in c.attrib for c in shape.findall(f"{{{NS}}}Cell") + shape.findall(f"{{{NS}}}Section//{{{NS}}}Cell"))
                counts["maxGroupDepth"] = max(counts["maxGroupDepth"], depth)
                visit(shape.find(f"{{{NS}}}Shapes"), sid, depth + 1)
        root = ET.fromstring(parts[f"visio/pages/page{index}.xml"])
        visit(root.find(f"{{{NS}}}Shapes"))
        expected.append({"index": index, "name": page.get("Name"), "background": False, "width": 100, "height": 100, "shapes": shapes})
    return counts, {"pages": expected}


def make_fixture(path, shape_count, connector_count, page_count, variant):
    if variant not in VARIANTS or min(shape_count, page_count) < 1 or connector_count < 0 or page_count > shape_count:
        raise ValueError("Invalid fixture dimensions or variant")
    parts = {"_rels/.rels": relations([("rId1", TYPE + "document", "visio/document.xml")]),
             "visio/document.xml": xml(element("VisioDocument")),
             "visio/_rels/document.xml.rels": relations([("rId1", TYPE + "pages", "pages/pages.xml")])}
    pages = element("Pages")
    page_rels = []
    has_images = False
    for p in range(page_count):
        page = element("Page", {"ID": p, "Name": f"Synthetic {p+1}", "NameU": f"Synthetic.{p+1}"}, pages)
        sheet = element("PageSheet", parent=page)
        cell(sheet, "PageWidth", 100)
        cell(sheet, "PageHeight", 100)
        element("Rel", {f"{{{RNS}}}id": f"rId{p+1}"}, page)
        page_rels.append((f"rId{p+1}", TYPE + "page", f"page{p+1}.xml"))
        root = element("PageContents")
        shapes = element("Shapes", parent=root)
        local_shapes = shape_count // page_count + (p < shape_count % page_count)
        local_connectors = connector_count // page_count + (p < connector_count % page_count)
        chain = shapes
        page_has_images = False
        for n in range(local_shapes):
            if variant != "hierarchy" or n % 16 == 0:
                chain = shapes
            grouped = variant == "hierarchy" and n % 16 != 15 and n + 1 < local_shapes
            image = not grouped and (n % (2 if variant == "image-heavy" else 20) == 0)
            shape = element("Shape", {"ID": n+1, "NameU": f"Synthetic.{n+1}", "Type": "Group" if grouped else "Foreign" if image else "Shape"}, chain)
            x, y = (0.5, 0.25) if variant == "hierarchy" and n % 16 else (1 + (n % 50) * 1.5, 1 + ((n // 50) % 50) * 1.5)
            formulas = variant == "formula-heavy" or n % 5 == 0
            for name, value in (("PinX", x), ("PinY", y), ("Width", 1.0), ("Height", 0.5), ("LocPinX", 0.5), ("LocPinY", 0.25)):
                formula = {"Width": "GUARD(0.5+0.5)", "Height": "Width*0.5", "LocPinX": "Width*0.5", "LocPinY": "Height*0.5"}.get(name) if formulas else None
                cell(shape, name, value, formula)
            element("Text", parent=shape).text = f"Synthetic shape {p+1}.{n+1}"
            if image:
                foreign = element("ForeignData", {"ForeignType": "Bitmap", "CompressionType": "PNG"}, shape)
                element("Rel", {f"{{{RNS}}}id": "rImage"}, foreign)
                has_images = True
                page_has_images = True
            else:
                geom = element("Section", {"N": "Geometry", "IX": 0}, shape)
                for ix, (gx, gy) in enumerate(((0, 0), (1, 0), (1, .5), (0, .5), (0, 0))):
                    row = element("Row", {"T": "MoveTo" if ix == 0 else "LineTo", "IX": ix+1}, geom)
                    cell(row, "X", gx)
                    cell(row, "Y", gy)
            if grouped:
                chain = element("Shapes", parent=shape)
        connects = element("Connects", parent=root)
        roots = list(range(1, local_shapes+1, 16 if variant == "hierarchy" else 1))
        for n in range(local_connectors):
            sid = local_shapes+n+1
            shape = element("Shape", {"ID": sid, "NameU": f"Connector.{sid}", "Type": "Shape"}, shapes)
            cell(shape, "ObjType", 2)
            source, target = roots[n % len(roots)], roots[(n+1) % len(roots)]
            bx, by = 1 + ((source-1) % 50)*1.5, 1 + (((source-1)//50) % 50)*1.5
            ex, ey = 1 + ((target-1) % 50)*1.5, 1 + (((target-1)//50) % 50)*1.5
            width, height = abs(ex-bx), abs(ey-by)
            for name, value in (("BeginX", bx), ("BeginY", by), ("EndX", ex), ("EndY", ey), ("PinX", (bx+ex)/2), ("PinY", (by+ey)/2), ("Width", width), ("Height", height), ("LocPinX", width/2), ("LocPinY", height/2)):
                cell(shape, name, value)
            element("Text", parent=shape).text = f"Synthetic connector {p+1}.{n+1}"
            geom = element("Section", {"N": "Geometry", "IX": 0}, shape)
            for ix, (gx, gy) in enumerate(((bx-min(bx, ex), by-min(by, ey)), (ex-min(bx, ex), ey-min(by, ey)))):
                row = element("Row", {"T": "MoveTo" if ix == 0 else "LineTo", "IX": ix+1}, geom)
                cell(row, "X", gx)
                cell(row, "Y", gy)
            for endpoint, target in (("BeginX", source), ("EndX", target)):
                element("Connect", {"FromSheet": sid, "FromCell": endpoint, "FromPart": 9 if endpoint == "BeginX" else 12, "ToSheet": target, "ToCell": "PinX", "ToPart": 3}, connects)
        parts[f"visio/pages/page{p+1}.xml"] = xml(root)
        parts[f"visio/pages/_rels/page{p+1}.xml.rels"] = relations([("rImage", RNS + "/image", "../media/synthetic.png")] if page_has_images else [])
    parts["visio/pages/pages.xml"] = xml(pages)
    parts["visio/pages/_rels/pages.xml.rels"] = relations(page_rels)
    if has_images:
        parts["visio/media/synthetic.png"] = png()
    types = element("Types", ns=CTNS)
    for ext, kind in (("rels", "application/vnd.openxmlformats-package.relationships+xml"), ("xml", "application/xml"), ("png", "image/png")):
        element("Default", {"Extension": ext, "ContentType": kind}, types, CTNS)
    for part, kind in (("visio/document.xml", "document.main"), ("visio/pages/pages.xml", "pages")):
        element("Override", {"PartName": "/"+part, "ContentType": f"application/vnd.ms-visio.{kind}+xml"}, types, CTNS)
    for p in range(page_count):
        element("Override", {"PartName": f"/visio/pages/page{p+1}.xml", "ContentType": "application/vnd.ms-visio.page+xml"}, types, CTNS)
    parts["[Content_Types].xml"] = xml(types)
    counts, expected = public_summary(parts)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(parts.items()):
            info = zipfile.ZipInfo(name, (2000, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data, compresslevel=9)
    data = path.read_bytes()
    return {"file": path.name, "case": path.stem, "format": "vsdx", "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
            "containsNativeMetadata": False, "variant": variant, "counts": counts, "expected": expected}


def validate_corpus(folder):
    folder = Path(folder)
    if folder.is_symlink():
        raise ValueError("Fixture directory cannot be linked")
    manifest_path = folder / "manifest.json"
    if manifest_path.is_symlink():
        raise ValueError("Manifest cannot be linked")
    manifest = parse_json(manifest_path.read_text())
    if not isinstance(manifest, dict) or type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1 or type(manifest.get("benchmarkSchemaVersion")) is not int or manifest["benchmarkSchemaVersion"] != 1 or manifest.get("syntheticOnly") is not True:
        raise ValueError("A versioned synthetic benchmark manifest is required")
    if not isinstance(manifest.get("fixtures"), list) or not manifest["fixtures"]:
        raise ValueError("Missing fixtures")
    seen = set()
    for fixture in manifest["fixtures"]:
        name = fixture.get("file", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+\.vsdx", name) or name in seen:
            raise ValueError("Unsafe or duplicate fixture name")
        seen.add(name)
        path = folder / name
        if path.is_symlink() or not path.is_file() or fixture.get("containsNativeMetadata") is not False:
            raise ValueError("Regular public fixture required")
        if hashlib.sha256(path.read_bytes()).hexdigest() != fixture.get("sha256") or path.stat().st_size != fixture.get("bytes"):
            raise ValueError("Fixture hash/size mismatch")
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            names = [i.filename for i in infos]
            if len(names) != len(set(names)) or len(names) > 500 or sum(i.file_size for i in infos) > 128*1024*1024:
                raise ValueError("Invalid or oversized archive")
            allowed = re.compile(r"(?:\[Content_Types\]\.xml|_rels/\.rels|visio/(?:document\.xml|_rels/document\.xml\.rels|pages/(?:pages\.xml|page\d+\.xml|_rels/(?:pages|page\d+)\.xml\.rels)|media/synthetic\.png))")
            if not all(allowed.fullmatch(n) for n in names):
                raise ValueError("Unexpected/private archive part")
            parts = {n: archive.read(n) for n in names}
            for n, data in parts.items():
                if n.endswith((".xml", ".rels")):
                    if any(token in data.upper() for token in (b"<!DOCTYPE", b"<!ENTITY", b"URN:MACVISIO")):
                        raise ValueError("Unsafe or private XML")
                    root = ET.fromstring(data)
                    for rel in root.iter(f"{{{PNS}}}Relationship"):
                        if rel.get("TargetMode") == "External" or ":" in rel.get("Target", "") or "\\" in rel.get("Target", ""):
                            raise ValueError("External/unsafe relationship")
                        source_dir = "" if n == "_rels/.rels" else posixpath.dirname(posixpath.dirname(n))
                        target = posixpath.normpath(posixpath.join(source_dir, rel.get("Target", "")))
                        if target not in parts:
                            raise ValueError("Missing/outside relationship target")
            counts, expected = public_summary(parts)
            if counts != fixture.get("counts") or expected != fixture.get("expected"):
                raise ValueError("Authored public counts/content mismatch")
    return manifest


def generate(output, sizes=(100, 1000, 5000, 20000), variants=VARIANTS, include_spec=True):
    output = Path(output)
    if output.is_symlink() or (output.exists() and (not output.is_dir() or any(output.iterdir()))):
        raise ValueError("Output must be a new or empty regular directory")
    if not sizes or len(set(sizes)) != len(sizes) or any(not 3 <= s <= 20000 for s in sizes):
        raise ValueError("Sizes must be unique and between 3 and 20000")
    if not variants or len(set(variants)) != len(variants) or any(v not in VARIANTS for v in variants):
        raise ValueError("Invalid/duplicate variants")
    output.mkdir(parents=True, exist_ok=True)
    fixtures = []
    for size in sizes:
        for variant in variants:
            connectors = size // 3
            item = make_fixture(output / f"objects-{size}-{variant}.vsdx", size-connectors, connectors, max(1, math.ceil(size/600)), variant)
            item["targetProfile"] = "scaling"
            fixtures.append(item)
    if include_spec:
        for profile, shapes, connectors, pages in (("interaction", 1000, 500, 1), ("standard", 2000, 1000, 10), ("large", 20000, 10000, 50)):
            item = make_fixture(output / f"spec-{profile}.vsdx", shapes, connectors, pages, "balanced")
            item["targetProfile"] = profile
            fixtures.append(item)
    manifest = {"schemaVersion": 1, "benchmarkSchemaVersion": 1, "syntheticOnly": True, "generator": "generate-benchmark-corpus.py/v1",
                "scope": "Authored public synthetic inputs; no compatibility/performance acceptance is implied.", "fixtures": fixtures}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sizes", nargs="+", type=int, default=[100, 1000, 5000, 20000])
    parser.add_argument("--variants", nargs="+", choices=VARIANTS, default=list(VARIANTS))
    parser.add_argument("--no-spec", action="store_true")
    args = parser.parse_args()
    try:
        manifest = generate(args.output, args.sizes, args.variants, not args.no_spec)
        validate_corpus(args.output)
    except (OSError, ValueError, KeyError, ET.ParseError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Corpus rejected: {error}\n")
    print(f"Generated and validated {len(manifest['fixtures'])} public fixtures at {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
