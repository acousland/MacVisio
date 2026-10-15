"""Structural guard tests. Fabricated evidence records are never qualification runs."""
import copy
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('evidence_ledger', ROOT / 'scripts/build-evidence-ledger.py')
ledger_tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger_tools)


class EvidenceLedgerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.baseline = ledger_tools.make_ledger(ROOT)
        cls.inventory = ledger_tools.make_inventory(ROOT, cls.baseline)

    def setUp(self):
        self.ledger = copy.deepcopy(self.baseline)
        self.items = copy.deepcopy(self.inventory)

    def errors(self):
        return ledger_tools.validate(ROOT, self.ledger, self.items)

    def test_canonical_generation_reconciles_all_ids_states_and_denominators(self):
        self.assertEqual(self.errors(), [])
        self.assertEqual(len(self.ledger['requirements']), 154)
        self.assertEqual(sum(r['scope'] != 'X' for r in self.ledger['requirements']), 148)
        self.assertEqual(sum(r['scope'] == 'X' for r in self.ledger['requirements']), 6)
        self.assertEqual(self.ledger, ledger_tools.make_ledger(ROOT))
        self.assertEqual(self.items, ledger_tools.make_inventory(ROOT, self.baseline))

    def test_missing_duplicate_or_changed_requirement_ids_fail(self):
        for mode in ('missing', 'duplicate', 'changed'):
            with self.subTest(mode=mode):
                self.ledger = copy.deepcopy(self.baseline)
                if mode == 'missing':
                    self.ledger['requirements'].pop()
                elif mode == 'duplicate':
                    self.ledger['requirements'].append(copy.deepcopy(self.ledger['requirements'][0]))
                else:
                    self.ledger['requirements'][0]['id'] = 'MV-UX-999'
                self.assertTrue(self.errors())

    def test_canonical_status_and_source_hash_cannot_be_promoted(self):
        self.ledger['requirements'][1]['snapshot']['status'] = 'Implemented'
        self.assertTrue(any('snapshot' in error for error in self.errors()))
        self.ledger = copy.deepcopy(self.baseline)
        self.ledger['source_hashes']['docs/FEATURE-STATUS.md'] = 'wrong'
        self.assertTrue(any('hash' in error for error in self.errors()))

    def test_snapshot_implemented_does_not_make_any_dimension_pass(self):
        for requirement in self.ledger['requirements']:
            self.assertEqual(requirement['acceptance_state'], 'unaccepted')
            self.assertEqual(set(requirement['evidence']), set(ledger_tools.DIMENSIONS))
            self.assertTrue(all(e['state'] == 'unverified' for e in requirement['evidence'].values()))

    def test_acceptance_requires_all_five_dimensions_and_exact_build(self):
        requirement = self.ledger['requirements'][0]
        requirement['acceptance_state'] = 'accepted'
        self.assertTrue(any('five independently' in error for error in self.errors()))
        self.assertTrue(any('exact-build' in error for error in self.errors()))
        requirement['evidence'].pop('behavior')
        self.assertTrue(any('five evidence dimensions' in error for error in self.errors()))

    def test_parser_success_cannot_qualify_full_compatibility(self):
        requirement = self.ledger['requirements'][0]
        artifact = {'path': 'docs/library-import-summary.json', 'sha256': ledger_tools.digest(ROOT / 'docs/library-import-summary.json'),
                    'kind': 'parser', 'outcome': 'passed', 'exact_build': '16.0.TEST', 'synthetic': True}
        requirement['evidence']['preservation'] = {'state': 'passed', 'artifacts': [artifact]}
        self.assertTrue(any('parser/source/local-test' in error for error in self.errors()))
        # Relabeling the descriptor does not turn a parser result into a workflow report.
        artifact['kind'] = 'reference_workflow'
        self.assertTrue(any('underlying artifact' in error for error in self.errors()))

    def test_pass_requires_hashed_artifacts(self):
        self.ledger['requirements'][0]['evidence']['editing'] = {'state': 'passed', 'artifacts': []}
        self.assertTrue(any('requires artifacts' in error for error in self.errors()))
        self.ledger['requirements'][0]['evidence']['editing']['artifacts'] = [{'path': 'docs/FEATURE-STATUS.md', 'sha256': 'wrong'}]
        self.assertTrue(any('hash mismatch' in error for error in self.errors()))

    def test_interchange_requires_both_directions_and_public_metadata_removed(self):
        self.ledger['requirements'][0]['evidence']['interchange'] = {'state': 'passed', 'artifacts': [
            {'path': 'docs/library-import-summary.json', 'sha256': ledger_tools.digest(ROOT / 'docs/library-import-summary.json'),
             'kind': 'reference_workflow', 'exact_build': 'TEST', 'outcome': 'passed', 'synthetic': True}]}
        self.assertTrue(any('bidirectional public-content' in error for error in self.errors()))

    def test_broken_fixture_and_unsafe_links_fail(self):
        for path in ('does-not-exist.vsdx', '../private.vsdx', '/tmp/private.vsdx'):
            with self.subTest(path=path):
                self.ledger['requirements'][0]['fixture'] = {'state': 'assigned', 'path': path}
                self.assertTrue(any('broken/unsafe' in error for error in self.errors()))

    def test_unresolved_fixture_requires_recorded_prerequisite(self):
        self.ledger['requirements'][0]['fixture'] = {'state': 'unresolved', 'path': None}
        self.assertTrue(any('unresolved prerequisite' in error for error in self.errors()))

    def test_scope_exclusion_requires_explicit_approved_decision(self):
        self.ledger['requirements'][0]['applicability']['state'] = 'excluded'
        self.assertTrue(any('approved scope decision' in error for error in self.errors()))
        self.assertEqual(self.ledger['requirements'][0]['scope'], 'N')

    def test_every_inventory_entry_has_child_owner_check_or_prerequisite(self):
        children = {c['inventory_id']: c for c in self.items['workflow_children']}
        self.assertEqual(len(children), self.items['entry_count'])
        self.assertEqual(set(self.items['category_counts']), set(ledger_tools.CATEGORIES))
        for entry in self.items['entries']:
            self.assertEqual(children[entry['id']]['requirement_ids'], entry['requirement_ids'])
            self.assertTrue(entry['owner'])
            self.assertTrue(entry['source_check']['anchor'])
            self.assertTrue(entry['qualification']['prerequisite'])
            self.assertIsNone(entry['reference_build'])
            self.assertEqual(entry['fixture']['state'], 'unresolved')

    def test_unknown_catalog_remainder_is_required_per_category(self):
        unknowns = [e for e in self.items['entries'] if e['observation'] == 'unresolved']
        self.assertEqual({e['category'] for e in unknowns}, set(ledger_tools.CATEGORIES))
        self.items['entries'].remove(unknowns[0])
        self.assertTrue(any('missing unknown remainder' in error for error in self.errors()))

    def test_missing_child_changed_mapping_or_false_complete_fail(self):
        self.items['workflow_children'].pop()
        self.assertTrue(any('workflow_children' in error for error in self.errors()))
        self.items = copy.deepcopy(self.inventory)
        self.items['entries'][0]['requirement_ids'] = ['MV-SOL-16']
        self.assertTrue(any('requirement_ids' in error for error in self.errors()))
        self.items = copy.deepcopy(self.inventory)
        self.items['catalog_complete'] = True
        self.assertTrue(any('cannot be complete' in error for error in self.errors()))

    def test_historical_installer_counts_are_not_runtime_evidence(self):
        historical = self.items['historical_library_observation']
        self.assertEqual(historical['installer_build'], '16.0.10730.20102')
        self.assertFalse(historical['windows_validated'])
        self.assertIsNone(self.items['reference_exact_build'])
        masters = [e for e in self.items['entries'] if e['category'] == 'masters']
        self.assertEqual(len(masters), 1)
        self.assertEqual(masters[0]['observation'], 'unresolved')

    def test_t02_is_decomposed_before_execution(self):
        self.assertEqual(len(self.items['decomposition']), 7)
        self.assertTrue(all(c['size'] == 'S' and c['qualification_prerequisite'] for c in self.items['decomposition']))

    def test_matching_normalized_reports_require_fixture_and_exact_build_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(ROOT / 'docs', root / 'docs')
            shutil.copytree(ROOT / 'Sources/MacVisio', root / 'Sources/MacVisio')
            record = self.ledger['requirements'][0]
            record['acceptance_state'] = 'accepted'
            fixture = root / 'docs/evidence/test-fixture.json'
            fixture.write_text('{"synthetic": true, "test_only": true}')
            record['fixture'] = {'state': 'assigned', 'path': 'docs/evidence/test-fixture.json'}
            self.ledger['reference'].update({'state': 'verified', 'exact_build': 'TEST ONLY'})
            for dimension in ledger_tools.DIMENSIONS:
                path = 'docs/evidence/test-' + dimension + '.json'
                report = {'schema_version': 1, 'kind': 'reference_workflow', 'subject_id': record['id'],
                          'dimension': dimension, 'exact_build': 'TEST ONLY', 'outcome': 'passed',
                          'run_id': 'TEST-ONLY-NOT-ACTUAL-EVIDENCE', 'synthetic': True,
                          'private_metadata_removed': True, 'bidirectional': True,
                          'checks': [{'id': 'TEST', 'outcome': 'passed', 'expected': 'test', 'observed': 'test'}]}
                (root / path).write_text(json.dumps(report))
                descriptor = dict(report, path=path, sha256=ledger_tools.digest(root / path))
                record['evidence'][dimension] = {'state': 'passed', 'artifacts': [descriptor]}
            self.assertEqual(ledger_tools.validate(root, self.ledger, self.items), [])
            self.ledger['reference']['exact_build'] = 'DIFFERENT TEST BUILD'
            self.assertTrue(any('exact-build mismatch' in e for e in ledger_tools.validate(root, self.ledger, self.items)))

    def test_regeneration_preserves_recorded_evidence_and_refuses_discard(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            # Copy repository inputs. No guest, user drawing, or build artifact is read.
            for directory in ('docs', 'Sources/MacVisio'):
                shutil.copytree(ROOT / directory, root / directory)
            first, inventory = ledger_tools.write_documents(root)
            first['requirements'][0]['evidence']['behavior']['state'] = 'failed'
            first['requirements'][0]['evidence']['behavior']['reason'] = 'TEST RECORD ONLY'
            (root / ledger_tools.LEDGER).write_text(json.dumps(first))
            again, _ = ledger_tools.write_documents(root)
            self.assertEqual(again['requirements'][0]['evidence']['behavior']['state'], 'failed')
            again['requirements'].append({'id': 'TEST-DO-NOT-DISCARD'})
            (root / ledger_tools.LEDGER).write_text(json.dumps(again))
            with self.assertRaisesRegex(ValueError, 'discard records'):
                ledger_tools.write_documents(root)


if __name__ == '__main__':
    unittest.main()
