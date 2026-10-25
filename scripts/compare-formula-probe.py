#!/usr/bin/env python3
"""Compare MacVisio formula results with Visio 2019 results for the same cases and drawing.

A case agrees when both reject it (syntax/reference error or a cell error value), or both
succeed with the same value: equal text for string results, equal internal-unit numbers
(relative 1e-9) and the same dimension (number/length/angle/date/string) otherwise.
"""
from __future__ import annotations
import argparse, collections, json, math, re, sys
from pathlib import Path

LENGTH, ANGLE = set(range(48, 80)), set(range(80, 90))
VISIO_ERRORS = {39: "#DIV/0!", 47: "#VALUE!", 55: "#REF!", 61: "#NAME?", 68: "#NUM!", 74: "#N/A"}
MAC_LENGTH = {"IN", "INCH", "INCHES", "PT", "MM", "CM", "M", "FT", "YD", "DL", "DP"}
MAC_ANGLE = {"DEG", "RAD", "DA"}


def visio_dimension(case: dict) -> str:
    units = case.get("units")
    if units == 231: return "string"
    if units in LENGTH: return "length"
    if units in ANGLE: return "angle"
    if units in (40,): return "date"
    if units in range(41, 48): return "duration"
    if units in (251,): return "color"
    if units == 225: return "point"
    return "number"


def mac_dimension(case: dict) -> str:
    kind = case.get("kind")
    if kind == "quantity":
        unit = (case.get("unit") or "").upper()
        return "length" if unit in MAC_LENGTH else "angle" if unit in MAC_ANGLE else "duration" if unit == "DE" else "number"
    return {"boolean": "number", "number": "number"}.get(kind, kind or "error")


def compare(visio: dict, mac: dict) -> tuple[str, str]:
    rejected = not visio.get("accepted") or (visio.get("cellError") or 0) != 0
    if rejected:
        reason = VISIO_ERRORS.get(visio.get("cellError"), "rejected") if visio.get("accepted") else "formula rejected"
        return ("agree", reason) if not mac.get("ok") else ("mac-accepts-error", f"Visio {reason}; MacVisio {mac.get('text')!r}")
    if not mac.get("ok"):
        return "mac-rejects", f"Visio {visio.get('resultStr')!r}; MacVisio error: {mac.get('error')}"
    vdim, mdim = visio_dimension(visio), mac_dimension(mac)
    if vdim == "color":
        match = re.fullmatch(r"RGB\((\d+), (\d+), (\d+)\)", visio.get("resultStr") or "")
        expected = "#%02X%02X%02X" % tuple(int(g) for g in match.groups()) if match else visio.get("resultStr")
        actual = (mac.get("color") or "")[:7].upper() if mac.get("kind") == "color" else None
        return ("agree", "") if actual == expected else ("value" if actual else "dimension", f"Visio color {expected}; MacVisio {mac.get('kind')} {mac.get('color') or mac.get('text')!r}")
    if mac.get("kind") == "string" and re.match(r"(POLYLINE|NURBS)\(", visio.get("resultStr") or ""):
        # Composite geometry values: Visio reports them with numeric units but a canonical text form.
        return ("agree", "") if mac.get("text") == visio.get("resultStr") else ("value", f"Visio {visio.get('resultStr')!r}; MacVisio {mac.get('text')!r}")
    if vdim in ("string", "point"):
        return ("agree", "") if mac.get("text") == visio.get("resultStr") else ("value", f"Visio {visio.get('resultStr')!r}; MacVisio {mac.get('text')!r}")
    expected, actual = visio.get("resultIU"), mac.get("internal")
    if actual is None:
        return "dimension", f"Visio {vdim} {visio.get('resultStr')!r}; MacVisio {mdim} {mac.get('text')!r}"
    # Visio keeps text measurements in its own internal rounding (about 0.004 pt).
    tolerance = 1e-4 if re.search(r"TEXTWIDTH|TEXTHEIGHT", visio.get("formula") or "") else 1e-12
    if not math.isclose(expected, actual, rel_tol=1e-9, abs_tol=tolerance):
        return "value", f"Visio {expected!r} ({visio.get('resultStr')!r}); MacVisio {actual!r} ({mac.get('text')!r})"
    if vdim != mdim:
        return "dimension", f"Visio {vdim} ({visio.get('resultStr')!r}); MacVisio {mdim} ({mac.get('text')!r})"
    return "agree", ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--visio", type=Path, required=True)
    parser.add_argument("--macvisio", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--dispositions", type=Path, default=Path(__file__).resolve().parents[1] / "docs/evidence/reference/formulas/dispositions.json")
    args = parser.parse_args()
    visio = {c["id"]: c for c in json.loads(args.visio.read_text(encoding="utf-8-sig"))["cases"]}
    mac = {c["id"]: c for c in json.loads(args.macvisio.read_text(encoding="utf-8"))["cases"]}
    rows, families = [], collections.defaultdict(collections.Counter)
    for case_id, reference in visio.items():
        verdict, detail = compare(reference, mac.get(case_id, {"ok": False, "error": "missing"}))
        family = case_id.rsplit("-", 1)[0]
        families[family][verdict] += 1
        rows.append({"id": case_id, "formula": reference["formula"], "verdict": verdict, "detail": detail})
    visio_fields = {f["id"]: f for f in json.loads(args.visio.read_text(encoding="utf-8-sig")).get("fields") or []}
    mac_fields = {f["id"]: f for f in json.loads(args.macvisio.read_text(encoding="utf-8")).get("fields") or []}
    for field_id, reference in visio_fields.items():
        actual = mac_fields.get(field_id, {"error": "missing"})
        expected = None if reference.get("error") else (reference.get("text") or "").replace("\r\n", "\n")
        verdict = "agree" if (expected is None and actual.get("error")) or (expected is not None and actual.get("text") == expected) else "field"
        families["FIELD:" + field_id.split("-")[0]][verdict] += 1
        rows.append({"id": field_id, "formula": "field", "verdict": verdict,
                     "detail": "" if verdict == "agree" else f"Visio {expected!r}; MacVisio {actual.get('text', actual.get('error'))!r}"})
    dispositions = json.loads(args.dispositions.read_text(encoding="utf-8")) if args.dispositions.exists() else {"cases": {}, "prefixes": {}}
    def disposition(case_id):
        if case_id in dispositions["cases"]: return dispositions["cases"][case_id]
        # East Asian codes are 40-63, 66-73 and 76-81; a prefix such as FIELDCODE-date-4 covers 40-49.
        number = case_id.rsplit("-", 1)[-1]
        if case_id.startswith("FIELDCODE") and number.isdigit() and not (40 <= int(number) <= 81) or number in ("64", "65", "74", "75", "77"):
            return None
        return next((reason for prefix, reason in dispositions["prefixes"].items() if case_id.startswith(prefix)), None)
    for row in rows:
        if row["verdict"] != "agree" and row["id"] in dispositions.get("open", {}):
            row["verdict"], row["detail"] = "open", row["detail"] + " | " + dispositions["open"][row["id"]]
        elif row["verdict"] != "agree" and (reason := disposition(row["id"])):
            row["verdict"], row["detail"] = "disposed", row["detail"] + " | " + reason
    families = collections.defaultdict(collections.Counter)
    for row in rows:
        families[("FIELD:" if row["formula"] == "field" else "") + row["id"].rsplit("-", 1)[0]][row["verdict"]] += 1
    totals = collections.Counter(r["verdict"] for r in rows)
    report = {"schemaVersion": 1, "visioVersion": json.loads(args.visio.read_text(encoding="utf-8-sig")).get("visioVersion"),
              "cases": len(rows), "totals": dict(totals),
              "families": {k: dict(v) for k, v in sorted(families.items())},
              "agreeingFamilies": sorted(k for k, v in families.items() if set(v) == {"agree"}),
              "disposed": [r for r in rows if r["verdict"] == "disposed"],
              "open": [r for r in rows if r["verdict"] == "open"],
              "disagreements": [r for r in rows if r["verdict"] not in ("agree", "disposed", "open")], "rows": rows}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"cases": len(rows), **dict(totals), "families": len(families), "agreeingFamilies": len(report["agreeingFamilies"])}))
    # Open gaps are recorded, visible failures; anything else unexpected fails the run.
    return 0 if totals.keys() <= {"agree", "disposed", "open"} else 1


if __name__ == "__main__":
    sys.exit(main())
