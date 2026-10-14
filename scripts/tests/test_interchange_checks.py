"""Tests of comparison tooling. Fabricated runner records are not Windows evidence."""
import copy
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


public = load("compare_vsdx", "compare-vsdx.py")
windows = load("compare_windows_report", "compare-windows-report.py")


class InterchangeChecks(unittest.TestCase):
    def runner_records(self):
        page = {"index": 1, "name": "Synthetic", "background": False, "width": 10, "height": 8,
                "shapes": [{"id": "1", "parentID": None, "text": "Original", "cells": {"PinX": 2}}]}
        fixture = {"file": "synthetic.vsdx", "sha256": "test-only-hash", "expected": {"pages": [page]}}
        manifest = {"schemaVersion": 1, "fixtures": [fixture]}
        phases = {name: {"status": "passed"} for name in ("open", "inspect", "saveAs", "close", "reopen", "exportPdf", "exportSvg")}
        phases["inspect"]["pages"] = [copy.deepcopy(page)]
        phases["reopen"]["pages"] = [copy.deepcopy(page)]
        phases["reopen"]["pages"][0]["shapes"][0]["text"] = "Edited"
        phases["mutation"] = {"status": "passed", "pageIndex": 1, "shapeId": "1", "property": "text", "originalValue": "Original", "newValue": "Edited"}
        report = {"schemaVersion": 1, "status": "passed", "environment": {"visioVersion": "TEST RECORD ONLY"},
                  "files": [{"file": fixture["file"], "inputSha256": fixture["sha256"], "status": "passed", "phases": phases}]}
        return manifest, report

    def test_authored_content_and_intentional_edit_match(self):
        manifest, report = self.runner_records()
        self.assertTrue(windows.assess(manifest, report)["matched"])
        self.assertEqual(manifest["fixtures"][0]["expected"]["pages"][0]["shapes"][0]["text"], "Original")

    def test_failed_or_skipped_execution_cannot_pass_from_matching_snapshots(self):
        for change in ("overall", "fixture", "open", "version", "hash", "missing"):
            manifest, report = self.runner_records()
            if change == "overall": report["status"] = "failed"
            elif change == "fixture": report["files"][0]["status"] = "failed"
            elif change == "open": report["files"][0]["phases"]["open"]["status"] = "skipped"
            elif change == "version": report["environment"].clear()
            elif change == "hash": report["files"][0]["inputSha256"] = "different-input"
            else: report["files"].clear()
            self.assertFalse(windows.assess(manifest, report)["matched"], change)

    def test_failed_or_skipped_export_cannot_pass(self):
        for phase in ("exportPdf", "exportSvg"):
            for status in ("failed", "skipped"):
                manifest, report = self.runner_records()
                report["files"][0]["phases"][phase]["status"] = status
                paths = [item["path"] for item in windows.assess(manifest, report)["differences"]]
                self.assertIn("status", paths, f"{phase} {status}")

    def test_edit_not_persisted_and_unrelated_changes_are_detected(self):
        manifest, report = self.runner_records()
        shape = report["files"][0]["phases"]["reopen"]["pages"][0]["shapes"][0]
        shape["text"] = "Original"
        shape["cells"]["PinX"] = 9
        paths = [item["path"] for item in windows.assess(manifest, report)["differences"]]
        self.assertIn("page/1/shape/1/text", paths)
        self.assertIn("page/1/shape/1/cells/PinX", paths)

    def test_duplicate_results_and_empty_corpus_are_rejected(self):
        manifest, report = self.runner_records()
        report["files"].append(copy.deepcopy(report["files"][0]))
        with self.assertRaises(ValueError): windows.assess(manifest, report)
        with self.assertRaises(ValueError): windows.assess({"schemaVersion": 1}, report)

    def test_real_public_example_comparison_ignores_private_model(self):
        baseline = public.snapshot(ROOT / "Examples" / "Groups" / "grouped-connectors.vsdx")
        self.assertEqual(public.compare(baseline, copy.deepcopy(baseline), 1e-7), [])
        changed = copy.deepcopy(baseline)
        first = next(iter(next(iter(changed.values()))["shapes"].values()))
        first["text"] = "Public text edit"
        first["cells"]["PinX"] += 1
        differences = public.compare(baseline, changed, 1e-7)
        self.assertEqual(len(differences), 2)
        self.assertTrue(any(item["path"].endswith("/text") for item in differences))
        self.assertTrue(any(item["path"].endswith("/cells/PinX") for item in differences))

    def test_reordered_shapes_are_reported(self):
        baseline = public.snapshot(ROOT / "Examples" / "Groups" / "grouped-connectors.vsdx")
        changed = copy.deepcopy(baseline)
        page = next(iter(changed.values()))
        page["shapes"] = dict(reversed(list(page["shapes"].items())))
        differences = public.compare(baseline, changed, 1e-7)
        self.assertEqual(len(differences), 1)
        self.assertTrue(differences[0]["path"].endswith("/shapeOrder"))


if __name__ == "__main__":
    unittest.main()
