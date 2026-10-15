"""Adapter refusal checks; these mocks are not product benchmark samples."""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("benchmark_adapter_tests", ROOT / "scripts/profile-benchmark-adapter.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class BenchmarkAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.folder = self.root / "fixtures"
        manifest = adapter.corpus.generate(self.folder, (3,), variants=("balanced",), include_spec=False)
        self.fixture = self.folder / manifest["fixtures"][0]["file"]

    def tearDown(self):
        self.temporary.cleanup()

    def args(self, **changes):
        values = dict(app=Path("/must-not-launch"), fixture=self.fixture, result=self.root / "result.json",
                      cache="warm", sample=1, mode="performance", timeout=2)
        values.update(changes)
        return argparse.Namespace(**values)

    def unsupported(self, **changes):
        args = self.args(**changes)
        with patch.object(adapter.subprocess, "run", side_effect=AssertionError("must not launch")):
            self.assertFalse(adapter.run(args))
        report = json.loads(args.result.read_text())
        self.assertEqual(report["phases"]["driver"]["status"], "failed")
        self.assertEqual(report["phases"]["open"]["status"], "not_observed")

    def test_cold_does_not_claim_cache_eviction_or_launch(self):
        self.unsupported(cache="cold")

    def test_memory_does_not_claim_cycles_or_launch(self):
        self.unsupported(mode="memory")

    def test_recovery_does_not_claim_fault_injection_or_launch(self):
        self.unsupported(mode="recovery")

    def test_linked_fixture_is_refused_before_resolution(self):
        linked = self.root / "linked.vsdx"
        linked.symlink_to(self.fixture)
        with patch.object(adapter.subprocess, "run", side_effect=AssertionError("must not launch")):
            with self.assertRaisesRegex(ValueError, "Fixture cannot be linked"):
                adapter.run(self.args(fixture=linked))

    def test_linked_original_corpus_is_refused_before_resolution(self):
        linked = self.root / "linked-folder"
        linked.symlink_to(self.folder, target_is_directory=True)
        args = self.args(fixture=linked / self.fixture.name)
        with patch.object(adapter.subprocess, "run", side_effect=AssertionError("must not launch")):
            self.assertFalse(adapter.run(args))
        report = json.loads(args.result.read_text())
        self.assertIn("Fixture directory cannot be linked", report["phases"]["driver"]["reason"])

    def test_prior_evidence_is_preserved(self):
        args = self.args()
        args.result.write_text("previous evidence")
        with self.assertRaises(ValueError):
            adapter.run(args)
        self.assertEqual(args.result.read_text(), "previous evidence")


if __name__ == "__main__":
    unittest.main()
