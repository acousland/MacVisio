#!/usr/bin/env python3
"""Compare the host matrix (WP-15-T02-C003, WP-15-T03): the same formula evaluated by Visio 2019 and by
MacVisio's document calculation in a shape User cell, a page User cell, a Geometry row, a control handle and
a text field of the same probe drawing.

A case agrees when both reject it (Visio refuses the formula or reports a cell error; MacVisio reports a
calculation issue or keeps no value), or both produce the same value: equal internal-unit numbers (relative
1e-9), equal colors, equal strings, or for a text field the same displayed text.
"""
from __future__ import annotations
import argparse, collections, json, math, re, sys
from pathlib import Path


def number(text):
    try:
        value = float(text)
        return value if math.isfinite(value) else None
    except (TypeError, ValueError):
        return None


def color(text: str | None) -> str | None:
    if not text: return None
    match = re.fullmatch(r"RGB\((\d+), ?(\d+), ?(\d+)\)", text)
    if match: return "#%02X%02X%02X" % tuple(int(g) for g in match.groups())
    match = re.fullmatch(r"#?([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?", text)
    return "#" + match.group(1).upper() if match else None


def compare(visio: dict, mac: dict) -> tuple[str, str]:
    mac_failed = bool(mac.get("error") or mac.get("issues"))
    if visio.get("host") == "field":
        expected, actual = visio.get("text"), mac.get("value")
        if not visio.get("accepted"):
            return ("agree", "formula rejected") if mac_failed else ("mac-accepts-error", f"Visio rejects; MacVisio shows {actual!r}")
        return ("agree", "") if expected == actual else ("value", f"Visio shows {expected!r}; MacVisio {actual!r}" + (f" ({mac.get('issues') or mac.get('error')})" if mac_failed else ""))
    rejected = not visio.get("accepted") or (visio.get("cellError") or 0) != 0
    if rejected:
        return ("agree", "rejected") if mac_failed else ("mac-accepts-error", f"Visio error {visio.get('cellError')}; MacVisio {mac.get('value')!r}")
    if mac_failed:
        return "mac-rejects", f"Visio {visio.get('resultStr')!r}; MacVisio {mac.get('issues') or mac.get('error')}"
    expected_color, actual_color = color(visio.get("resultStr")), color(mac.get("value"))
    if visio.get("units") == 251 or expected_color and actual_color:
        return ("agree", "") if expected_color == actual_color else ("value", f"Visio {visio.get('resultStr')!r}; MacVisio {mac.get('value')!r}")
    actual = number(mac.get("value"))
    if visio.get("units") == 231 or actual is None:
        expected = visio.get("resultStr")
        return ("agree", "") if mac.get("value") == expected else ("value", f"Visio {expected!r}; MacVisio {mac.get('value')!r}")
    expected = visio.get("resultIU")
    if expected is None or not math.isclose(expected, actual, rel_tol=1e-9, abs_tol=1e-12):
        return "value", f"Visio {expected!r} ({visio.get('resultStr')!r}); MacVisio {actual!r}"
    return "agree", ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--visio", type=Path, required=True)
    parser.add_argument("--macvisio", type=Path, required=True)
    parser.add_argument("--dispositions", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    visio = {c["id"]: c for c in json.loads(args.visio.read_text(encoding="utf-8-sig")).get("hostCases") or []}
    mac = {c["id"]: c for c in json.loads(args.macvisio.read_text())["hostCases"]}
    dispositions = json.loads(args.dispositions.read_text()) if args.dispositions and args.dispositions.exists() else {}
    rows, totals = [], collections.Counter()
    by_function = collections.defaultdict(collections.Counter)
    for case_id, v in visio.items():
        m = mac.get(case_id, {"error": "missing"})
        verdict, detail = compare(v, m)
        if verdict != "agree" and case_id in dispositions:
            verdict, detail = "disposed", dispositions[case_id]
        function = case_id.split("-")[1]
        totals[verdict] += 1; by_function[function][verdict] += 1
        rows.append({"id": case_id, "host": v.get("host"), "formula": v.get("formula"), "verdict": verdict, "detail": detail,
                     "visio": {k: v.get(k) for k in ("accepted", "cellError", "resultIU", "resultStr", "units", "text")}, "macvisio": m})
    open_rows = [r for r in rows if r["verdict"] not in ("agree", "disposed")]
    report = {"schemaVersion": 1, "cases": len(rows), "totals": dict(totals), "open": len(open_rows),
              "functions": {f: dict(c) for f, c in sorted(by_function.items())}, "disagreements": open_rows, "rows": rows}
    args.report.write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n")
    print(json.dumps({"cases": len(rows), **dict(totals)}))
    return 1 if open_rows else 0


if __name__ == "__main__":
    sys.exit(main())
