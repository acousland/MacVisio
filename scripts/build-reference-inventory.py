#!/usr/bin/env python3
"""Build the observed Visio 2019 exact-build inventory and its child backlog (WP-02-T02, WP-02-T04).

Input is the raw output of scripts/windows/Inventory-VisioReference.ps1 copied from the reference guest.
Output is docs/evidence/reference/visio-2019-inventory.json: what the installed reference exposes, how each
item relates to MacVisio, and the child backlog item that owns every item MacVisio does not yet cover.
No observed item may be dropped: each one is either implemented or assigned to exactly one child.
"""
from __future__ import annotations

import argparse
import glob
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/evidence/reference/visio-2019-inventory.json"

# Solution families for templates and stencils, matched against the content path (first match wins).
FAMILIES = [
    ("WP-25", r"ORG|TIMELN|TIMELINE|GANTT|CAL|PERT|SCHED"),
    ("WP-26", r"UML|DBMODL|DATABASE|ERD|SOFTW|PROG|DATAFLOW|DFD|COM_|WEBSITE|WEBMAP|SDL|ENTRY|MSOFT"),
    ("WP-27", r"NETW|RACK|AD_|ACTDIR|AZURE|AWS|LDAP|CISCO|NTWK|DETNET|RACKNW|SERVER|COMPUT"),
    ("WP-28", r"CAD|FLOOR|PLAN|ELEC|HVAC|PLUMB|PIPE|PROC|SITE|SECUR|FIRE|LANDSC|GARDEN|SPACE|OFFICE_|PLNT|IND|FLUID|PART|ASSEM|MECH|CIRC|SYSTM|WALL|BUILD|DOOR|FURN|APPL|BATH|KITCH|GARAGE|RESID|ROAD|METRO|DIRMAP|3DMAP|TRANSP"),
    ("WP-22", r"BPMN|EPC|SIXSIG|TQM|VALUE|XFUNC|AUDIT|ITIL|CAUSE|FISHB|FAULT|SDLC"),
    ("WP-21", r"SWIM|CONTAIN|CALLOUT"),
    ("WP-24", r"CHART|GRAPH|DATA|PIVOT|LEGEND|MARKET|DASH"),
]


def family(path: str) -> str:
    name = Path(path).name.upper()
    for owner, pattern in FAMILIES:
        if re.search(pattern, name):
            return owner
    return "WP-29"


def implemented_functions() -> set[str]:
    names: set[str] = set()
    for source in glob.glob(str(ROOT / "Sources/MacVisio/*.swift")):
        for match in re.finditer(r'case\s+((?:"[A-Z][A-Z0-9_]*"\s*,?\s*)+):', Path(source).read_text()):
            names.update(n for n in re.findall(r'"([A-Z][A-Z0-9_]*)"', match.group(1)) if len(n) > 1)
    return names


def source_text() -> str:
    return "\n".join(Path(p).read_text() for p in glob.glob(str(ROOT / "Sources/MacVisio/*.swift")))


def chunks(items: list[str], size: int) -> list[list[str]]:
    return [items[i:i + size] for i in range(0, len(items), size)]


def build(raw: Path) -> dict:
    load = lambda name: json.loads((raw / name).read_text(encoding="utf-8-sig"))
    app, typelib, content, integrations, fonts = load("application.json"), load("typelib.json"), load("content.json"), \
        load("integrations.json"), load("fonts.json")
    functions = json.loads((raw.parent / "functions-clean.json").read_text()) if (raw.parent / "functions-clean.json").exists() \
        else load("functions.json")
    implemented, sources = implemented_functions(), source_text()
    children: list[dict] = []

    taken: set[str] = set()

    def child(owner, category, key, title, members, acceptance):
        identifier, suffix = f"{owner}-REF-{key}", 2
        while identifier in taken:  # distinct names can normalise alike (e.g. _Timeline.exe, TIMELINE.EXE)
            identifier, suffix = f"{owner}-REF-{key}-{suffix}", suffix + 1
        taken.add(identifier)
        item = {"id": identifier, "parent": owner, "category": category, "title": title,
                "members": members, "state": "planned", "reference_build": app["fileVersion"], "acceptance": acceptance}
        children.append(item)
        return item["id"]

    # Functions: one child per Visio function MacVisio lacks; names Visio rejects are flagged for review.
    function_rows = []
    for entry in sorted(functions, key=lambda f: f["name"]):
        name, recognized = entry["name"], entry["state"] == "recognized"
        if recognized and name in implemented:
            state, owner = "implemented", None
        elif recognized:
            state = "uncovered"
            owner = child("WP-15", "functions", f"FN-{name}", f"Implement ShapeSheet function {name}", [name],
                          "Typed result, context, error and reference behaviour match Visio 2019; formula round-trips unchanged.")
        else:
            state, owner = ("macvisio_only" if name in implemented else "not_in_reference"), None
        function_rows.append({"name": name, "reference": "recognized" if recognized else "not_recognized", "macvisio": state, "child": owner})
    extras = [f["name"] for f in function_rows if f["macvisio"] == "macvisio_only"]
    if extras:
        child("WP-15", "functions", "FN-NOT-IN-VISIO", "Review functions MacVisio accepts but Visio 2019 rejects", extras,
              "Formulas MacVisio writes must stay valid in Visio 2019: reject, translate or confine these names.")

    # Cells, sections and rows from the type-library constants; a literal cell name in source counts as handled.
    enums = typelib["enums"]
    def names(enum, prefix):
        return sorted({m.split("=")[0] for m in enums.get(enum, [])})
    cells = names("VisCellIndices", "vis")
    cell_rows, uncovered_cells = [], []
    for constant in cells:
        bare = re.sub(r"^vis(XForm|XForm1D|Line|Fill|Char|Para|Tab|Text|Doc|Page|Obj|Glue|Prot|Style|Misc|Event|Layout|Print|Ruler|Grid|Comp|Geom)?", "", constant)
        handled = bool(bare) and f'"{bare}"' in sources
        cell_rows.append({"constant": constant, "macvisio": "referenced_in_source" if handled else "uncovered"})
        if not handled:
            uncovered_cells.append(constant)
    for index, group in enumerate(chunks(uncovered_cells, 25), 1):
        child("WP-15", "cells", f"CELLS-{index:02d}", f"ShapeSheet cells group {index}", group,
              "Each cell reads, calculates, edits and round-trips with Visio 2019 semantics or is shown as preserved-only.")

    commands = names("VisUICmds", "visCmd")
    for index, group in enumerate(chunks(commands, 40), 1):
        child("WP-10", "commands", f"CMDS-{index:02d}", f"Visio command identifiers group {index}", group,
              "Each command has a native MacVisio equivalent with matching outcome, or an explicit unsupported state.")

    # Co-classes carry no members themselves; their members live on the matching IV<name> dispatch interface.
    by_name = {i["name"]: i for i in typelib["interfaces"]}
    for interface in typelib["interfaces"]:
        if interface["name"].startswith("IV") and interface["name"][2:] in by_name:
            continue
        members = interface["members"] or by_name.get("IV" + interface["name"], {}).get("members", [])
        if not members:
            continue
        child("WP-31", "apis", f"API-{interface['name']}", f"Automation object {interface['name']}", members,
              "Members are available to translated automation with Visio 2019 outcomes, or reported unsupported.")
    for interface in typelib["events"]:
        child("WP-31", "events", f"EVT-{interface['name']}", f"Automation events {interface['name']}", interface["members"],
              "Events fire in Visio 2019 order with equivalent arguments for supported automation.")

    def content_key(path):
        parts = Path(path).parts
        return "-".join(p.upper() for p in parts[:-1] + (Path(path).stem,))
    for template in content["templates"]:
        child(family(template["file"]), "templates", "TPL-" + content_key(template["file"]),
              f"Template {template['file']}", [template["file"]],
              "Creating from this template yields the Visio 2019 pages, styles, stencils and behaviour.")
    for stencil in content["stencils"]:
        child(family(stencil["file"]), "masters", "STN-" + content_key(stencil["file"]),
              f"Stencil {stencil['file']} ({len(stencil['masters'])} masters)", stencil["masters"],
              "Each master drops, behaves (data, controls, connections) and round-trips as in Visio 2019.")

    for flt in integrations["filters"]:
        ext = flt["extension"].lstrip(".").lower()
        owner = "WP-20" if ext in {"vsdx", "vsdm", "vssx", "vssm", "vstx", "vstm"} else "WP-30"
        child(owner, "filters", f"FLT-{ext.upper()}", f"File format .{ext} ({flt['progId']})", [flt["extension"]],
              "Open and save preserve public semantics against Visio 2019 in both directions.")
    for addon in integrations["addons"]:
        key = re.sub(r"[^A-Za-z0-9]+", "-", addon["name"]).strip("-").upper()
        owner = "WP-33" if re.search(r"web|link|report|rpt|export|import|project", addon["name"], re.I) else "WP-32"
        child(owner, "integrations", f"ADDON-{key}", f"Add-on {addon['name']}", [addon["name"]],
              "Equivalent native workflow with Visio 2019 outcomes, or an explicit unsupported/blocked decision.")
    drivers = sorted(set(integrations.get("odbcDrivers64", [])) | set(integrations.get("odbcDrivers32", [])))
    if drivers:
        child("WP-23", "integrations", "ODBC", "Data sources reachable through the reference's ODBC drivers", drivers,
              "Each data source links, refreshes and reconciles as in Visio 2019, or has a recorded macOS prerequisite.")

    counted = [m for c in children for m in c["members"]]
    return {
        "schema_version": 1,
        "kind": "observed_exact_build_inventory",
        "reference": app,
        "automation": {"x86": app.get("automationClient"), "arm64": "verified" if (raw / "automation64.json").exists() else "not run"},
        "fonts": fonts["required"],
        "probes": integrations.get("probes"),
        "rights_management_client": integrations.get("rightsManagement"),
        "office_applications_for_ole": integrations.get("officeApplications"),
        "counts": {
            "functions_observed": len(function_rows), "functions_recognized": sum(1 for f in function_rows if f["reference"] == "recognized"),
            "functions_implemented": sum(1 for f in function_rows if f["macvisio"] == "implemented"),
            "cells": len(cells), "cells_uncovered": len(uncovered_cells), "sections": len(names("VisSectionIndices", "")),
            "rows": len(names("VisRowIndices", "")), "commands": len(commands), "interfaces": len(typelib["interfaces"]),
            "event_interfaces": len(typelib["events"]), "templates": len(content["templates"]), "stencils": len(content["stencils"]),
            "masters": sum(len(s["masters"]) for s in content["stencils"]), "filters": len(integrations["filters"]),
            "addons": len(integrations["addons"]), "odbc_drivers": len(drivers), "children": len(children), "child_members": len(counted),
        },
        "functions": function_rows,
        "cells": cell_rows,
        "children": children,
    }


def validate(inventory: dict) -> list[str]:
    errors = []
    ids = [c["id"] for c in inventory["children"]]
    if len(ids) != len(set(ids)):
        errors.append("duplicate child IDs")
    for row in inventory["functions"]:
        if row["reference"] == "recognized" and row["macvisio"] != "implemented" and not row["child"]:
            errors.append(f"function {row['name']} has no child")
    child_cells = {m for c in inventory["children"] if c["category"] == "cells" for m in c["members"]}
    for row in inventory["cells"]:
        if row["macvisio"] == "uncovered" and row["constant"] not in child_cells:
            errors.append(f"cell {row['constant']} has no child")
    for child in inventory["children"]:
        if not child["members"] and child["category"] != "masters":
            errors.append(f"{child['id']} has no members")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, default=ROOT / "build/M0-inventory/raw/inventory")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    inventory = build(args.raw) if args.write else json.loads(OUTPUT.read_text())
    errors = validate(inventory)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    if args.write:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(json.dumps(inventory, indent=1, ensure_ascii=False) + "\n")
    print(json.dumps(inventory["counts"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
