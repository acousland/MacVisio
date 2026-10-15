#!/usr/bin/env python3
"""Author and compare public synthetic M3 content without using MacVisio's model.

This is a preservation check, not a ShapeSheet evaluator, renderer, or Visio
compatibility verdict. Formula meaning and reference-application behavior need
independent acceptance evidence. No real/user drawings are generated or copied.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

V = "http://schemas.microsoft.com/office/visio/2012/main"
R = "http://schemas.openxmlformats.org/package/2006/relationships"
O = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
T = "http://schemas.microsoft.com/visio/2010/relationships/"
C = "http://schemas.openxmlformats.org/package/2006/content-types"
PRIVATE_REL = "urn:macvisio:relationships:diagram"
PRIVATE_PART = "macvisio/document.json"


def is_private_part(name: str) -> bool:
    match = re.fullmatch(r"macvisio/metadata/segment(0|[1-9][0-9]{0,18})\.mvmeta", name)
    return name == PRIVATE_PART or (match is not None and int(match[1]) <= 9223372036854775807)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def xml(text: str) -> bytes:
    return ('<?xml version="1.0" encoding="UTF-8"?>' + text).encode()


def rels(entries: list[tuple[str, str, str]]) -> bytes:
    root = ET.Element("Relationships", xmlns=R)
    for identifier, kind, target in entries:
        ET.SubElement(root, "Relationship", Id=identifier, Type=kind, Target=target)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def authored_parts() -> dict[str, bytes]:
    """Exact source XML is the oracle; it does not call an application serializer."""
    document = f'''<VisioDocument xmlns="{V}"><Colors><ColorEntry IX="24" RGB="#13579B"/></Colors>
      <FaceNames><FaceName ID="0" NameU="Arial"/></FaceNames><StyleSheets>
      <StyleSheet ID="0" NameU="No Style"/>
      <StyleSheet ID="4" Name="Shared display" NameU="Blue"><Cell N="LineColor" V="24"/><Cell N="FillForegnd" V="#E8F0FE"/></StyleSheet>
      <StyleSheet ID="5" Name="Shared display" NameU="Green"><Cell N="LineColor" V="#008000"/></StyleSheet>
      </StyleSheets><DocumentSheet NameU="TheDoc"><Section N="User"><Row N="Revision"><Cell N="Value" V="1"/></Row></Section></DocumentSheet></VisioDocument>'''
    masters = f'''<Masters xmlns="{V}" xmlns:r="{O}">
      <Master ID="7" Name="Same display" NameU="Intelligent.Blue"><Rel r:id="m7"/></Master>
      <Master ID="8" Name="Same display" NameU="Intelligent.Green"><Rel r:id="m8"/></Master></Masters>'''
    master = f'''<MasterContents xmlns="{V}"><PageSheet><Cell N="PageWidth" V="2"/><Cell N="PageHeight" V="1"/></PageSheet><Shapes>
      <Shape ID="1" NameU="Body" LineStyle="4" FillStyle="4"><Cell N="PinX" V="1"/><Cell N="PinY" V="0.5"/>
      <Cell N="Width" V="2"/><Cell N="Height" V="1"/><Cell N="LocPinX" V="1" F="Width/2"/><Cell N="LocPinY" V="0.5" F="Height/2"/>
      <Section N="User"><Row N="Span"><Cell N="Value" V="2" F="Width"/></Row></Section>
      <Section N="Property"><Row N="Owner"><Cell N="Label" V="Owner"/><Cell N="Value" V="Synthetic"/></Row></Section>
      <Section N="Connection"><Row N="Out" IX="0"><Cell N="X" V="2" F="Width"/><Cell N="Y" V="0.5" F="Height/2"/><Cell N="DirX" V="1"/><Cell N="DirY" V="0"/><Cell N="Type" V="0"/></Row></Section>
      <Section N="Control"><Row N="Handle" IX="0"><Cell N="X" V="1" F="Width/2"/><Cell N="Y" V="0.5" F="Height/2"/><Cell N="XCon" V="0"/><Cell N="YCon" V="0"/></Row></Section>
      <Section N="Geometry" IX="0"><Row T="MoveTo" IX="1"><Cell N="X" V="0"/><Cell N="Y" V="0"/></Row><Row T="LineTo" IX="2"><Cell N="X" V="2" F="Width"/><Cell N="Y" V="0"/></Row><Row T="LineTo" IX="3"><Cell N="X" V="2" F="Width"/><Cell N="Y" V="1" F="Height"/></Row><Row T="LineTo" IX="4"><Cell N="X" V="0"/><Cell N="Y" V="1" F="Height"/></Row><Row T="LineTo" IX="5"><Cell N="X" V="0"/><Cell N="Y" V="0"/></Row></Section><Text>Master body</Text></Shape></Shapes></MasterContents>'''
    foreground = f'''<PageContents xmlns="{V}"><Shapes>
      <Shape ID="10" Master="7" NameU="Instance.Blue"><Cell N="PinX" V="2"/><Cell N="PinY" V="6"/><Cell N="Width" V="2" F="GUARD(2 in)"/>
      <Section N="Character"><Row IX="0"><Cell N="Font" V="0"/><Cell N="Size" V="0.166666666666667"/></Row><Row IX="1"><Cell N="Style" V="1"/></Row></Section>
      <Section N="Paragraph"><Row IX="0"><Cell N="HorzAlign" V="0"/><Cell N="IndFirst" V="0.1"/><Cell N="SpAfter" V="0.05"/></Row></Section>
      <Text><cp IX="0"/>Café 東京 🙂<cp IX="1"/> bold\nSecond paragraph</Text></Shape>
      <Shape ID="20" Master="8" NameU="Instance.Green"><Cell N="PinX" V="6"/><Cell N="PinY" V="6"/><Cell N="Width" V="3" F="Sheet.10!Width+1 in"/><Text>Local override</Text></Shape>
      <Shape ID="30" NameU="Intelligent.Connector" LineStyle="5"><Cell N="OneD" V="1"/><Cell N="BeginX" V="3"/><Cell N="BeginY" V="6"/><Cell N="EndX" V="4.5"/><Cell N="EndY" V="6"/><Cell N="EndArrow" V="4"/>
      <Section N="User"><Row N="Weight"><Cell N="Value" V="5" F="Sheet.10!Width+Sheet.20!Width"/></Row></Section>
      <Section N="Character"><Row IX="0"><Cell N="Size" V="0.138888888888889"/></Row><Row IX="1"><Cell N="Style" V="2"/></Row></Section><Text><cp IX="0"/>Link <cp IX="1"/>東京</Text></Shape>
      </Shapes><Connects><Connect FromSheet="30" FromCell="BeginX" FromPart="9" ToSheet="10" ToCell="Connections.Out.X" ToPart="100"/><Connect FromSheet="30" FromCell="EndX" FromPart="12" ToSheet="20" ToCell="PinX" ToPart="3"/></Connects></PageContents>'''
    pages = f'''<Pages xmlns="{V}" xmlns:r="{O}"><Page ID="0" Name="Intelligent foreground" NameU="Foreground" BackPage="1"><PageSheet>
      <Cell N="PageWidth" V="8"/><Cell N="PageHeight" V="10"/><Cell N="PageScale" V="1"/><Cell N="DrawingScale" V="1"/>
      <Section N="Layer"><Row IX="0"><Cell N="Name" V="Guides"/><Cell N="Visible" V="1"/><Cell N="Print" V="0"/><Cell N="Snap" V="1"/><Cell N="Glue" V="0"/></Row></Section></PageSheet><Rel r:id="p0"/></Page>
      <Page ID="1" Name="Background scale" NameU="Background" Background="1"><PageSheet><Cell N="PageWidth" V="8"/><Cell N="PageHeight" V="10"/><Cell N="PageScale" V="0.02"/><Cell N="DrawingScale" V="1"/></PageSheet><Rel r:id="p1"/></Page></Pages>'''
    background = f'''<PageContents xmlns="{V}"><Shapes><Shape ID="1"><Cell N="PinX" V="4"/><Cell N="PinY" V="1"/><Cell N="Width" V="2"/><Cell N="Height" V="0.5"/><Cell N="LocPinX" V="1"/><Cell N="LocPinY" V="0.25"/><Text>Public background</Text></Shape></Shapes></PageContents>'''
    colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "20334F"), ("lt2", "E8F0FE"),
              ("accent1", "13579B"), ("accent2", "008000"), ("accent3", "AA6600"), ("accent4", "804080"),
              ("accent5", "008080"), ("accent6", "CC3333"), ("hlink", "0000FF"), ("folHlink", "800080")]
    color_scheme = "".join(f'<a:{slot}><a:srgbClr val="{value}"/></a:{slot}>' for slot, value in colors)
    fonts = '<a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/>'
    fill = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
    lines = "".join(f'<a:ln w="{width}">{fill}<a:prstDash val="solid"/></a:ln>' for width in [9525, 25400, 38100])
    effects = '<a:effectStyle><a:effectLst/></a:effectStyle>' * 3
    theme = f'''<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Synthetic M3"><a:themeElements>
      <a:clrScheme name="Synthetic">{color_scheme}</a:clrScheme>
      <a:fontScheme name="Synthetic"><a:majorFont>{fonts}</a:majorFont><a:minorFont>{fonts}</a:minorFont></a:fontScheme>
      <a:fmtScheme name="Synthetic"><a:fillStyleLst>{fill * 3}</a:fillStyleLst><a:lnStyleLst>{lines}</a:lnStyleLst>
      <a:effectStyleLst>{effects}</a:effectStyleLst><a:bgFillStyleLst>{fill * 3}</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>'''
    parts = {
        "_rels/.rels": rels([("document", T + "document", "visio/document.xml")]),
        "visio/document.xml": xml(document),
        "visio/_rels/document.xml.rels": rels([("pages", T + "pages", "pages/pages.xml"), ("masters", T + "masters", "masters/masters.xml"), ("theme", O + "/theme", "theme/theme1.xml")]),
        "visio/pages/pages.xml": xml(pages),
        "visio/pages/_rels/pages.xml.rels": rels([("p0", T + "page", "page1.xml"), ("p1", T + "page", "page2.xml")]),
        "visio/pages/page1.xml": xml(foreground), "visio/pages/page2.xml": xml(background),
        "visio/masters/masters.xml": xml(masters),
        "visio/masters/_rels/masters.xml.rels": rels([("m7", T + "master", "master1.xml"), ("m8", T + "master", "master2.xml")]),
        "visio/masters/master1.xml": xml(master),
        "visio/masters/master2.xml": xml(master.replace('LineStyle="4"', 'LineStyle="5"').replace("Master body", "Second master")),
        "visio/theme/theme1.xml": xml(theme),
        "synthetic/opaque.bin": b"Public synthetic opaque payload\x00\x01\x02",
    }
    types = ET.Element("Types", xmlns=C)
    for extension, kind in [("rels", "application/vnd.openxmlformats-package.relationships+xml"), ("xml", "application/xml"), ("bin", "application/octet-stream")]:
        ET.SubElement(types, "Default", Extension=extension, ContentType=kind)
    for name, kind in [("document.xml", "drawing.main"), ("pages/pages.xml", "pages"), ("pages/page1.xml", "page"), ("pages/page2.xml", "page"), ("masters/masters.xml", "masters"), ("masters/master1.xml", "master"), ("masters/master2.xml", "master")]:
        ET.SubElement(types, "Override", PartName="/visio/" + name, ContentType="application/vnd.ms-visio." + kind + "+xml")
    ET.SubElement(types, "Override", PartName="/visio/theme/theme1.xml", ContentType="application/vnd.openxmlformats-officedocument.theme+xml")
    parts["[Content_Types].xml"] = ET.tostring(types, encoding="utf-8", xml_declaration=True)
    return parts


def write_package(parts: dict[str, bytes], path: Path) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(parts.items()):
            entry = zipfile.ZipInfo(name, date_time=(2026, 10, 16, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)


def generate(directory: Path) -> dict:
    directory.mkdir(parents=True, exist_ok=True)
    if any(directory.iterdir()):
        raise ValueError("Fixture generation requires an empty directory")
    path = directory / "m3-intelligent.vsdx"
    write_package(authored_parts(), path)
    manifest = {"schemaVersion": 1, "syntheticOnly": True,
                "scope": "M3 authored public content; reference/render/behavior acceptance pending",
                "fixtures": [{"file": path.name, "case": "m3-intelligent", "format": "vsdx", "sha256": digest(path.read_bytes()),
                              "bytes": path.stat().st_size, "containsNativeMetadata": False,
                              "expected": {"pages": [
                                  {"index": 1, "name": "Intelligent foreground", "background": False, "width": 8, "height": 10, "shapes": [
                                      {"id": "10", "parentID": None, "text": "Café 東京 🙂 bold\nSecond paragraph", "cells": {"PinX": 2, "PinY": 6, "Width": 2, "Height": 1}},
                                      {"id": "20", "parentID": None, "text": "Local override", "cells": {"PinX": 6, "PinY": 6, "Width": 3, "Height": 1}},
                                      {"id": "30", "parentID": None, "text": "Link 東京", "cells": {"BeginX": 3, "BeginY": 6, "EndX": 4.5, "EndY": 6}}]},
                                  {"index": 2, "name": "Background scale", "background": True, "width": 8, "height": 10, "shapes": [
                                      {"id": "1", "parentID": None, "text": "Public background", "cells": {"PinX": 4, "PinY": 1, "Width": 2, "Height": 0.5}}]}]}}]}
    (directory / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return manifest


def read_parts(path: Path) -> dict[str, bytes]:
    if path.stat().st_size > 100 * 1024 * 1024:
        raise ValueError("Package exceeds supported size")
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(entries) > 10000 or len(names) != len(set(names)):
            raise ValueError("Too many or duplicate ZIP members")
        if sum(e.file_size for e in entries) > 128 * 1024 * 1024 or any(e.file_size > 16 * 1024 * 1024 for e in entries):
            raise ValueError("Expanded package exceeds supported size")
        if any(name.startswith("/") or "\\" in name or ":" in name or posixpath.normpath(name) != name or name.startswith("../") for name in names):
            raise ValueError("Unsafe package part name")
        return {name: archive.read(name) for name in names}


def snapshot(path: Path) -> dict:
    parts = read_parts(path)
    # Exclude only the recognized native payload family, retaining other public
    # JSON/relationships and all opaque content. Never evaluate formulas here.
    private = {name for name in parts if is_private_part(name)}
    result = {}
    for name, data in sorted(parts.items()):
        if name in private:
            continue
        if not (name.endswith(".xml") or name.endswith(".rels")):
            result[name] = {"sha256": digest(data), "bytes": len(data)}
            continue
        if b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
            raise ValueError("DTD/entity declarations are unsupported")
        root = ET.fromstring(data)
        if root.tag == "{" + R + "}Relationships":
            for child in list(root):
                if child.get("Type") == PRIVATE_REL:
                    root.remove(child)
            root[:] = sorted(root, key=lambda child: child.get("Id", ""))
        if root.tag == "{" + C + "}Types":
            unused_native_extensions = {extension for extension in ["json", "mvmeta"]
                                        if not any(p.endswith("." + extension) and p not in private for p in parts)}
            for child in list(root):
                if child.get("PartName", "").lstrip("/") in private or child.get("Extension") in unused_native_extensions:
                    root.remove(child)
            root[:] = sorted(root, key=lambda child: (child.tag, child.get("Extension", ""), child.get("PartName", "")))

        def element(node: ET.Element, in_text: bool = False) -> dict:
            parent_in_text = in_text
            in_text = parent_in_text or node.tag == "{" + V + "}Text"
            return {"tag": node.tag, "attributes": dict(sorted(node.attrib.items())),
                    "text": node.text if in_text or (node.text or "").strip() else None,
                    "tail": node.tail if parent_in_text or (node.tail or "").strip() else None,
                    "children": [element(child, in_text) for child in node]}

        result[name] = element(root)
    return result


def differences(before, after, path: str = "") -> list[dict]:
    if type(before) is not type(after):
        return [{"path": path, "expected": before, "actual": after}]
    if isinstance(before, dict):
        output = []
        for key in sorted(before.keys() | after.keys()):
            pointer = path + "/" + str(key).replace("~", "~0").replace("/", "~1")
            if key not in before or key not in after:
                output.append({"path": pointer, "expected": before.get(key), "actual": after.get(key)})
            else:
                output.extend(differences(before[key], after[key], pointer))
        return output
    if isinstance(before, list):
        output = []
        for i in range(max(len(before), len(after))):
            if i >= len(before) or i >= len(after):
                output.append({"path": path + "/" + str(i), "expected": before[i] if i < len(before) else None, "actual": after[i] if i < len(after) else None})
            else:
                output.extend(differences(before[i], after[i], path + "/" + str(i)))
        return output
    return [] if before == after else [{"path": path, "expected": before, "actual": after}]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    generate_parser = commands.add_parser("generate")
    generate_parser.add_argument("directory", type=Path)
    snapshot_parser = commands.add_parser("snapshot")
    snapshot_parser.add_argument("package", type=Path)
    compare_parser = commands.add_parser("compare")
    compare_parser.add_argument("before", type=Path)
    compare_parser.add_argument("after", type=Path)
    args = parser.parse_args()
    if args.command == "generate":
        output = generate(args.directory)
    elif args.command == "snapshot":
        output = snapshot(args.package)
    else:
        changes = differences(snapshot(args.before), snapshot(args.after))
        output = {"schemaVersion": 1, "scope": "Public content preservation only; behavior/render/reference acceptance separate", "status": "equal" if not changes else "changed", "differences": changes}
    print(json.dumps(output, ensure_ascii=False, indent=2))
    return 1 if args.command == "compare" and changes else 0


if __name__ == "__main__":
    raise SystemExit(main())
