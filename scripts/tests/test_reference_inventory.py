import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("inventory", ROOT / "scripts/build-reference-inventory.py")
inventory = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(inventory)


class ReferenceInventoryTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / "docs/evidence/reference/visio-2019-inventory.json").read_text())

    def test_committed_inventory_has_no_dropped_items(self):
        self.assertEqual(inventory.validate(self.data), [])

    def test_validator_rejects_an_uncovered_function_without_child(self):
        broken = json.loads(json.dumps(self.data))
        row = next(r for r in broken["functions"] if r["child"])
        row["child"] = None
        self.assertTrue(any(row["name"] in e for e in inventory.validate(broken)))

    def test_backlog_counts_match_inventory_children(self):
        backlog = json.loads((ROOT / "docs/development-backlog.json").read_text())
        self.assertEqual(sum(backlog["reference_inventory"]["children_by_work_package"].values()), len(self.data["children"]))


if __name__ == "__main__":
    unittest.main()
