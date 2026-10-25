import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("compare_formula_probe", Path(__file__).resolve().parents[1] / "compare-formula-probe.py")
compare_formula_probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compare_formula_probe)
compare = compare_formula_probe.compare


class FormulaProbeComparisonTests(unittest.TestCase):
    def test_both_refusing_agrees_and_one_sided_refusal_does_not(self):
        visio = {"accepted": True, "cellError": 39, "formula": "1/0"}
        self.assertEqual(compare(visio, {"ok": False})[0], "agree")
        self.assertEqual(compare(visio, {"ok": True, "text": "0"})[0], "mac-accepts-error")
        self.assertEqual(compare({"accepted": True, "cellError": 0, "units": 32, "resultIU": 1.0, "resultStr": "1"}, {"ok": False})[0], "mac-rejects")

    def test_numbers_compare_in_internal_units_and_dimension(self):
        visio = {"accepted": True, "cellError": 0, "units": 70, "resultIU": 1.0, "resultStr": "25.4000 mm", "formula": "25.4 mm"}
        self.assertEqual(compare(visio, {"ok": True, "kind": "quantity", "unit": "MM", "internal": 1.0})[0], "agree")
        self.assertEqual(compare(visio, {"ok": True, "kind": "number", "internal": 1.0})[0], "dimension")
        self.assertEqual(compare(visio, {"ok": True, "kind": "quantity", "unit": "MM", "internal": 1.1})[0], "value")

    def test_text_measurements_allow_visio_internal_rounding(self):
        visio = {"accepted": True, "cellError": 0, "units": 70, "resultIU": 0.31116, "resultStr": "7.9 mm", "formula": "TEXTHEIGHT(TheText,1 in)"}
        self.assertEqual(compare(visio, {"ok": True, "kind": "quantity", "unit": "MM", "internal": 0.31111})[0], "agree")

    def test_colors_compare_as_rgb_not_table_index(self):
        visio = {"accepted": True, "cellError": 0, "units": 251, "resultIU": 27, "resultStr": "RGB(255, 0, 0)"}
        self.assertEqual(compare(visio, {"ok": True, "kind": "color", "color": "#FF0000FF"})[0], "agree")
        self.assertEqual(compare(visio, {"ok": True, "kind": "color", "color": "#FE0000"})[0], "value")

    def test_strings_and_points_compare_by_text(self):
        visio = {"accepted": True, "cellError": 0, "units": 225, "resultIU": 0, "resultStr": "PNT(1.0000,2.0000)"}
        self.assertEqual(compare(visio, {"ok": True, "kind": "point", "text": "PNT(1.0000,2.0000)"})[0], "agree")


if __name__ == "__main__":
    unittest.main()
