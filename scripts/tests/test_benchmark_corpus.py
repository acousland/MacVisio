"""Public corpus and evidence safety tests; fabricated adapters are never product evidence."""
import argparse
import copy
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


corpus = load("corpus_tests", "generate-benchmark-corpus.py")
runner = load("benchmark_runner_tests", "run-benchmark-samples.py")
windows = load("windows_runner_for_benchmark_tests", "windows/run-visio-acceptance.py")
public = load("public_comparison_for_benchmark_tests", "compare-vsdx.py")


class BenchmarkCorpusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.fixtures = self.root / "fixtures"
        self.manifest = corpus.generate(self.fixtures, (100,), include_spec=False)
        self.fixture = self.manifest["fixtures"][0]
        self.environment = {"hardware": "TEST RECORD ONLY", "os": "TEST RECORD ONLY", "appBuild": "test-only", "storage": "synthetic",
                            "cacheProcedure": "test only", "memoryBytes": 16*1024**3, "controlledHardware": False}

    def tearDown(self):
        self.temp.cleanup()

    def result(self, fixture=None, index=1, mode="performance"):
        fixture = fixture or self.fixture
        return {"schemaVersion": 1, "fixtureSha256": fixture["sha256"], "cacheCondition": "warm", "sampleIndex": index, "mode": mode,
                "cachePreparation": {"status": "passed", "method": "TEST ONLY"},
                "phases": {p: {"status": "passed", "elapsedMs": 2} for p in runner.PHASES},
                "workCounts": {**fixture["counts"], "visitedObjects": 3, "evaluatedCells": 1, "drawnObjects": 2}, "metrics": {}}

    def rewrite_manifest(self):
        (self.fixtures / "manifest.json").write_text(json.dumps(self.manifest))

    def change_archive(self, name, data):
        path = self.fixtures / self.fixture["file"]
        with zipfile.ZipFile(path) as archive:
            parts = {n: archive.read(n) for n in archive.namelist()}
        parts[name] = data
        with zipfile.ZipFile(path, "w") as archive:
            for n, value in parts.items():
                archive.writestr(n, value)
        self.fixture["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.fixture["bytes"] = path.stat().st_size
        self.rewrite_manifest()

    def test_reproducible_zip_manifest_and_independent_windows_input(self):
        second = self.root / "second"
        corpus.generate(second, (100,), include_spec=False)
        for path in self.fixtures.iterdir():
            self.assertEqual(path.read_bytes(), (second / path.name).read_bytes(), path.name)
        self.assertEqual(corpus.validate_corpus(self.fixtures), self.manifest)
        _, accepted = windows.validate_fixture_set(self.fixtures)
        self.assertEqual(len(accepted), 4)
        for fixture in accepted:
            snapshot = public.snapshot(self.fixtures / fixture["file"])
            self.assertEqual(sum(len(p["shapes"]) for p in snapshot.values()), fixture["counts"]["objects"])
            self.assertTrue(all(s["text"].startswith("Synthetic ") for p in snapshot.values() for s in p["shapes"].values()))

    def test_exact_spec_counts_and_all_scaling_sizes(self):
        folder = self.root / "full"
        manifest = corpus.generate(folder)
        self.assertEqual(len(manifest["fixtures"]), 19)
        self.assertEqual(corpus.validate_corpus(folder), manifest)
        by_name = {f["file"]: f for f in manifest["fixtures"]}
        for size in (100, 1000, 5000, 20000):
            for variant in corpus.VARIANTS:
                fixture = by_name[f"objects-{size}-{variant}.vsdx"]
                self.assertEqual(fixture["counts"]["objects"], size)
                self.assertGreater(fixture["counts"]["formulaCells"], 0)
                if variant == "hierarchy":
                    self.assertEqual(fixture["counts"]["maxGroupDepth"], 15)
        for profile, shapes, connectors, pages in (("interaction", 1000, 500, 1), ("standard", 2000, 1000, 10), ("large", 20000, 10000, 50)):
            fixture = by_name[f"spec-{profile}.vsdx"]
            self.assertEqual((fixture["counts"]["shapes"], fixture["counts"]["connectors"], len(fixture["expected"]["pages"])), (shapes, connectors, pages))
        for fixture in manifest["fixtures"]:
            if fixture["variant"] == "formula-heavy":
                self.assertEqual(fixture["counts"]["formulaCells"], 4*fixture["counts"]["shapes"])

    def test_duplicate_or_nonfinite_json_cannot_hide_failures(self):
        for text in ('{"status":"failed","status":"passed"}', '{"metric": NaN}', '{"metric": 1e9999}'):
            with self.assertRaises(ValueError): corpus.parse_json(text)
        self.assertFalse(runner.number(10**1000))

    def test_no_overwrite_or_source_document_ingestion(self):
        with self.assertRaises(ValueError):
            corpus.generate(self.fixtures)
        with self.assertRaises(ValueError):
            corpus.generate(self.root / "invalid", (0,))
        with self.assertRaises(ValueError):
            corpus.generate(self.root / "invalid", (100,), ("private",))

    def test_reject_hash_manifest_count_and_synthetic_changes(self):
        for key, value in (("syntheticOnly", False), ("schemaVersion", 2)):
            modified = copy.deepcopy(self.manifest)
            modified[key] = value
            (self.fixtures / "manifest.json").write_text(json.dumps(modified))
            with self.assertRaises(ValueError): corpus.validate_corpus(self.fixtures)
        self.rewrite_manifest()
        self.fixture["counts"]["objects"] += 1
        self.rewrite_manifest()
        with self.assertRaisesRegex(ValueError, "counts/content"): corpus.validate_corpus(self.fixtures)
        self.fixture["counts"]["objects"] -= 1
        self.fixture["sha256"] = "0"*64
        self.rewrite_manifest()
        with self.assertRaisesRegex(ValueError, "hash/size"): corpus.validate_corpus(self.fixtures)

    def test_native_metadata_rejected_even_with_updated_hash(self):
        self.change_archive("macvisio/document.json", b'{"private":"TEST"}')
        with self.assertRaisesRegex(ValueError, "private archive part"): corpus.validate_corpus(self.fixtures)

    def test_external_and_dangling_relationships_rejected(self):
        for target, mode in (("https://example.invalid/test", ' TargetMode="External"'), ("../../outside.xml", "")):
            data = f'<Relationships xmlns="{corpus.PNS}"><Relationship Id="bad" Type="test" Target="{target}"{mode}/></Relationships>'.encode()
            self.change_archive("visio/pages/_rels/page1.xml.rels", data)
            with self.assertRaises(ValueError): corpus.validate_corpus(self.fixtures)

    def test_linked_fixture_and_manifest_rejected(self):
        source = self.fixtures / self.fixture["file"]
        moved = self.root / "moved.vsdx"
        source.rename(moved)
        source.symlink_to(moved)
        with self.assertRaises(ValueError): corpus.validate_corpus(self.fixtures)
        source.unlink()
        moved.rename(source)
        manifest = self.fixtures / "manifest.json"
        manifest.rename(self.root / "manifest.json")
        manifest.symlink_to(self.root / "manifest.json")
        with self.assertRaises(ValueError): corpus.validate_corpus(self.fixtures)

    def test_missing_skipped_failed_malformed_phase_or_counts_cannot_qualify(self):
        result = self.result()
        self.assertEqual(runner.validate_result(result, self.fixture, "warm", 1, "performance"), [])
        for change in ("missing", "skipped", "failed", "malformed", "count", "zeroWork", "noCalculation", "cache", "hash", "nan", "extraFailure"):
            current = copy.deepcopy(result)
            if change == "missing": del current["phases"]["textLayout"]
            elif change in ("failed", "skipped"): current["phases"]["open"]["status"] = change
            elif change == "malformed": current["phases"] = "bad"
            elif change == "count": current["workCounts"]["objects"] -= 1
            elif change == "zeroWork": current["workCounts"]["drawnObjects"] = 0
            elif change == "noCalculation": current["workCounts"]["evaluatedCells"] = 0
            elif change == "cache": current["cachePreparation"]["status"] = "skipped"
            elif change == "hash": current["fixtureSha256"] = "bad"
            elif change == "nan": current["phases"]["draw"]["elapsedMs"] = float("nan")
            else: current["phases"]["export"] = {"status": "failed"}
            errors = runner.validate_result(current, self.fixture, "warm", 1, "performance")
            self.assertTrue(errors, change)
            assessed = runner.assess(self.fixture, [{"result": current, "errors": errors}]*30, self.environment, "warm", "performance")
            self.assertFalse(assessed["evidenceComplete"], change)

    def test_nearest_rank_p95_and_no_selected_rerun_acceptance(self):
        values = runner.aggregate(list(range(1, 31)))
        self.assertEqual(values, {"samples": 30, "p50": 15.5, "p95": 29, "max": 30})
        attempts = [{"result": self.result(index=i), "errors": []} for i in range(1, 31)]
        self.assertFalse(runner.assess(self.fixture, attempts[:29], self.environment, "warm", "performance")["evidenceComplete"])
        assessed = runner.assess(self.fixture, attempts, self.environment, "warm", "performance")
        self.assertTrue(assessed["evidenceComplete"])
        self.assertEqual(assessed["absoluteAcceptance"], "unaccepted")
        attempts[0]["errors"] = ["Intermittent failure"]
        attempts.append({"result": self.result(index=31), "errors": []})
        self.assertFalse(runner.assess(self.fixture, attempts, self.environment, "warm", "performance")["evidenceComplete"])

    def test_memory_cycles_and_recovery_require_actual_fault_assertions(self):
        memory = self.result(mode="memory")
        self.assertTrue(runner.validate_result(memory, self.fixture, "warm", 1, "memory"))
        memory["metrics"]["peakRssBytes"] = 123
        self.assertEqual(runner.validate_result(memory, self.fixture, "warm", 1, "memory"), [])
        result = self.result(mode="recovery")
        result["phases"]["recovery"] = {"status": "passed", "elapsedMs": 1}
        self.assertTrue(runner.validate_result(result, self.fixture, "warm", 1, "recovery"))
        result["fault"] = {"name": "TEST FAILURE ONLY", "injected": True, "lastValidFilePreserved": True, "checkpointRecoverable": True}
        self.assertEqual(runner.validate_result(result, self.fixture, "warm", 1, "recovery"), [])

    def test_absolute_gates_need_controlled_hardware_complete_metrics_and_30_samples(self):
        fixture = copy.deepcopy(self.fixture)
        fixture["targetProfile"] = "standard"
        fixture["counts"].update(shapes=2000, connectors=1000, objects=3000)
        fixture["expected"]["pages"] = [{}]*10
        environment = {**self.environment, "controlledHardware": True, "architecture": "AppleSilicon", "localSSD": True}
        result = self.result(fixture)
        result["metrics"].update(peakRssBytes=500000000, maxMainThreadSaveStallMs=10)
        attempts = [{"result": copy.deepcopy(result), "errors": []} for _ in range(30)]
        assessed = runner.assess(fixture, attempts, environment, "warm", "performance")
        self.assertEqual(assessed["absoluteAcceptance"], "passed")
        self.assertEqual(runner.assess(fixture, attempts, self.environment, "warm", "performance")["absoluteAcceptance"], "unaccepted")
        self.assertEqual(runner.assess(fixture, attempts[:20], environment, "warm", "memory")["absoluteAcceptance"], "unaccepted")
        for attempt in attempts[:2]: attempt["result"]["phases"]["open"]["elapsedMs"] = 3001
        self.assertEqual(runner.assess(fixture, attempts, environment, "warm", "performance")["absoluteGates"]["open"]["status"], "failed")
        attempts[0]["result"]["metrics"].pop("peakRssBytes")
        self.assertEqual(runner.assess(fixture, attempts, environment, "warm", "performance")["absoluteGates"]["peakRssBytes"]["status"], "unaccepted")

    def test_interaction_gates_need_exact_fixture_counts_and_named_trace(self):
        fixture = copy.deepcopy(self.fixture)
        fixture["targetProfile"] = "interaction"
        fixture["counts"].update(shapes=1000, connectors=500, objects=1500)
        fixture["expected"]["pages"] = [{}]
        environment = {**self.environment, "controlledHardware": True, "architecture": "AppleSilicon", "localSSD": True, "interactionTrace": "TEST ONLY: deterministic drag/pan"}
        result = self.result(fixture)
        result["activePageShapes"] = 1000
        result["metrics"].update(inputToFeedbackMs=10, frameTimeMs=10, maxMainThreadSaveStallMs=10)
        attempts = [{"result": copy.deepcopy(result), "errors": []} for _ in range(30)]
        self.assertEqual(runner.assess(fixture, attempts, environment, "warm", "performance")["absoluteAcceptance"], "passed")
        fixture["counts"]["shapes"] = 999
        self.assertEqual(runner.assess(fixture, attempts, environment, "warm", "performance")["absoluteGates"]["frameTimeMs"]["status"], "unaccepted")
        fixture["counts"]["shapes"] = 1000
        environment.pop("interactionTrace")
        self.assertEqual(runner.assess(fixture, attempts, environment, "warm", "performance")["absoluteGates"]["frameTimeMs"]["status"], "unaccepted")

    def test_adapter_end_to_end_retains_all_attempts_and_refuses_overwrite(self):
        env = self.root / "environment.json"
        env.write_text(json.dumps(self.environment))
        adapter = self.root / "fabricated-test-adapter.py"
        adapter.write_text('''import argparse,json,sys
p=argparse.ArgumentParser()
for name in ('fixture','result','cache','sample','mode'): p.add_argument('--'+name)
a=p.parse_args()
f=next(f for f in json.load(open(__import__('pathlib').Path(a.fixture).parent/'manifest.json'))['fixtures'] if f['file']==__import__('pathlib').Path(a.fixture).name)
r={"schemaVersion":1,"fixtureSha256":f['sha256'],"cacheCondition":a.cache,"sampleIndex":int(a.sample),"mode":a.mode,"cachePreparation":{"status":"passed","method":"TEST ONLY"},"phases":{n:{"status":"passed","elapsedMs":2} for n in ''' + repr(runner.PHASES) + '''},"workCounts":{**f['counts'],"visitedObjects":1,"evaluatedCells":1,"drawnObjects":1},"metrics":{}}
json.dump(r,open(a.result,'w'))
if a.sample=='2': print('RETAIN TEST FAILURE',file=sys.stderr); sys.exit(7)
''')
        args = argparse.Namespace(fixtures=self.fixtures, fixture=[self.fixture["file"]], environment=env, report=self.root / "report.json", cache="warm", mode="performance", samples=30, timeout=5)
        report = runner.run(args, [sys.executable, str(adapter)])
        self.assertEqual(report["status"], "incomplete")
        attempts = report["fixtures"][0]["attempts"]
        self.assertEqual(len(attempts), 30)
        self.assertEqual(attempts[1]["exitCode"], 7)
        self.assertIn("RETAIN TEST FAILURE", attempts[1]["stderr"])
        self.assertTrue(attempts[1]["errors"])
        self.assertTrue(all(not a["errors"] for a in attempts[2:]))
        with self.assertRaises(ValueError): runner.run(args, [sys.executable, str(adapter)])


if __name__ == "__main__":
    unittest.main()
