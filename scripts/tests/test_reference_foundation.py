"""Synthetic tooling records only; no test here is evidence of Visio compatibility."""
import copy
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

inventory = load('reference_inventory', 'scripts/windows/inspect-reference-environment.py')
checks = load('interchange_checks', 'scripts/tests/test_interchange_checks.py')

class ReferenceInventoryTests(unittest.TestCase):
    def record(self):
        return {'errors': [], 'registryViews': [{'registryView': 'Registry32', 'visioClsid': None}, {'registryView': 'Registry64', 'visioClsid': None}], 'visioExecutables': [], 'relevantProcesses': []}

    def test_absent_reference_is_complete_inventory_but_never_accepted(self):
        value = inventory.assess(self.record())
        self.assertTrue(value['inventoryComplete'])
        self.assertEqual(value['state'], 'needs_input')
        self.assertFalse(value['accepted'])

    def test_executable_and_registration_never_prove_license_or_roundtrip(self):
        record = self.record()
        record['registryViews'][0]['visioClsid'] = 'TEST-ONLY'
        record['visioExecutables'] = [{'productVersion': 'TEST-ONLY'}]
        value = inventory.assess(record)
        self.assertEqual(value['state'], 'installed_unaccepted')
        self.assertFalse(value['accepted'])
        self.assertTrue(any('license' in item for item in value['prerequisites']))

    def test_busy_or_partial_inspection_remains_visible(self):
        record = self.record()
        record['relevantProcesses'] = [{'name': 'VISIO', 'id': 42}]
        record['registryViews'].pop()
        record['errors'] = [{'phase': 'Registry64'}]
        value = inventory.assess(record)
        self.assertTrue(value['sessionBusy'])
        self.assertFalse(value['inventoryComplete'])
        self.assertFalse(value['accepted'])

class SemanticSnapshotTests(unittest.TestCase):
    def records(self):
        manifest, report = checks.InterchangeChecks().runner_records()
        shape = manifest['fixtures'][0]['expected']['pages'][0]['shapes'][0]
        extra = {'masterID': '7', 'formulas': {'Width': 'GUARD(2 in)'}, 'data': {'Prop.Asset': 'Synthetic asset'}}
        shape.update(extra)
        connections = [{'fromShape': '2', 'fromCell': 'BeginX', 'toShape': '1', 'toCell': 'PinX'}]
        manifest['fixtures'][0]['expected']['pages'][0]['connects'] = connections
        masters = [{'id': '7', 'name': 'Synthetic', 'shapeCount': 1}]
        manifest['fixtures'][0]['expected']['masters'] = masters
        for phase in ('inspect', 'reopen'):
            target = report['files'][0]['phases'][phase]
            target['pages'][0]['shapes'][0].update(copy.deepcopy(extra))
            target['pages'][0]['connects'] = copy.deepcopy(connections)
            target['masters'] = copy.deepcopy(masters)
        return manifest, report

    def test_optional_public_semantics_match_without_mutating_authored_expectations(self):
        manifest, report = self.records()
        before = copy.deepcopy(manifest)
        self.assertTrue(checks.windows.assess(manifest, report)['matched'])
        self.assertEqual(manifest, before)

    def test_changed_formula_master_data_or_glue_fails(self):
        for field in ('masterID', 'formulas', 'data', 'connects', 'masters'):
            with self.subTest(field=field):
                manifest, report = self.records()
                phase = report['files'][0]['phases']['reopen']
                if field == 'masters': phase['masters'] = []
                elif field == 'connects': phase['pages'][0]['connects'] = []
                else: phase['pages'][0]['shapes'][0].pop(field)
                self.assertFalse(checks.windows.assess(manifest, report)['matched'])

    def test_semantic_match_cannot_override_phase_failure(self):
        for phase in ('inspect', 'mutation', 'reopen', 'exportPdf', 'exportSvg'):
            manifest, report = self.records()
            report['files'][0]['phases'][phase]['status'] = 'failed'
            self.assertFalse(checks.windows.assess(manifest, report)['matched'])


class PublicValidationCopyTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.copy_tool = load('public_copy', 'scripts/prepare-public-validation-copy.py')
        self.runner = load('windows_host', 'scripts/windows/run-visio-acceptance.py')

    def corpus(self, private=True, claimed=False):
        import zipfile, hashlib, json
        parts = {'[Content_Types].xml': b'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/macvisio/document.json" ContentType="application/json"/></Types>',
                 '_rels/.rels': b'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="native" Type="urn:macvisio:relationships:diagram" Target="macvisio/document.json"/></Relationships>',
                 'visio/pages/page1.xml': b'<PageContents xmlns="http://schemas.microsoft.com/office/visio/2012/main"><Shapes/></PageContents>',
                 'visio/media/macvisio-public.png': b'public-image-bytes'}
        if private: parts['macvisio/document.json'] = b'{"TEST-ONLY":"native model"}'
        path = self.source / 'synthetic.vsdx'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, data in parts.items(): archive.writestr(name, data)
        manifest = {'schemaVersion': 1, 'syntheticOnly': True, 'fixtures': [{'file': path.name, 'format': 'vsdx', 'containsNativeMetadata': claimed, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'expected': {'pages': []}}]}
        (self.source / 'manifest.json').write_text(json.dumps(manifest))
        return path

    def test_false_native_flag_cannot_stage_actual_private_part_or_relationship(self):
        for has_part in (True, False):
            self.corpus(private=has_part)
            with self.assertRaises(ValueError): self.runner.validate_fixture_set(self.source)

    def test_strips_only_new_copy_and_preserves_public_image_and_source_hash(self):
        import hashlib, zipfile
        path = self.corpus(claimed=True)
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        output = self.root / 'validation'
        result = self.copy_tool.prepare(self.source, output)
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
        self.assertEqual(result['fixtures'][0]['validationCopyOfSha256'], before)
        self.runner.validate_fixture_set(output)
        with zipfile.ZipFile(output / path.name) as archive:
            self.assertNotIn('macvisio/document.json', archive.namelist())
            self.assertEqual(archive.read('visio/media/macvisio-public.png'), b'public-image-bytes')
        with self.assertRaises(ValueError): self.copy_tool.prepare(self.source, output)

    def test_confidential_or_hash_changed_source_is_rejected(self):
        import json
        path = self.corpus()
        with path.open('ab') as handle: handle.write(b'changed')
        with self.assertRaisesRegex(ValueError, 'SHA-256'): self.copy_tool.prepare(self.source, self.root / 'bad-hash')
        manifest_file = self.source / 'manifest.json'
        manifest = json.loads(manifest_file.read_text());manifest['syntheticOnly'] = False
        manifest_file.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'syntheticOnly'): self.copy_tool.prepare(self.source, self.root / 'private')

    def test_existing_or_linked_destination_and_linked_source_are_rejected(self):
        self.corpus()
        with self.assertRaises(ValueError): self.copy_tool.prepare(self.source, self.source)
        linked = self.root / 'link'; linked.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError): self.copy_tool.prepare(linked, self.root / 'copy')

if __name__ == '__main__': unittest.main()
