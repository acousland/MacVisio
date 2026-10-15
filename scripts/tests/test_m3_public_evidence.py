"""Mutation tests for M3's independent public-content preservation oracle."""
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

SCRIPT = Path(__file__).resolve().parents[1] / "m3-public-evidence.py"
SPEC = importlib.util.spec_from_file_location("m3_public", SCRIPT)
m3 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m3)


class M3PublicEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.original = self.root / "original.vsdx"
        self.changed = self.root / "changed.vsdx"
        self.parts = m3.authored_parts()
        m3.write_package(self.parts, self.original)

    def compare(self):
        m3.write_package(self.parts, self.changed)
        return m3.differences(m3.snapshot(self.original), m3.snapshot(self.changed))

    def test_authored_fixture_is_reproducible_public_and_harness_ready(self):
        first = self.root / "first"
        second = self.root / "second"
        a = m3.generate(first)
        b = m3.generate(second)
        self.assertEqual(a, b)
        self.assertEqual((first / "m3-intelligent.vsdx").read_bytes(), (second / "m3-intelligent.vsdx").read_bytes())
        self.assertTrue(a["syntheticOnly"])
        self.assertFalse(a["fixtures"][0]["containsNativeMetadata"])
        self.assertEqual(len(a["fixtures"][0]["expected"]["pages"]), 2)
        self.assertFalse(any("macvisio" in name for name in self.parts))
        for name, data in self.parts.items():
            if name.endswith((".xml", ".rels")):
                ET.fromstring(data)
        with self.assertRaisesRegex(ValueError, "empty directory"):
            m3.generate(first)

    def test_no_edit_package_preserves_all_public_content(self):
        self.assertEqual(self.compare(), [])

    def test_xml_prefix_attributes_formatting_and_relationship_order_are_not_losses(self):
        for name, data in list(self.parts.items()):
            if not name.endswith((".xml", ".rels")):
                continue
            root = ET.fromstring(data)
            for element in root.iter():
                element.attrib = dict(reversed(list(element.attrib.items())))
            if name.endswith(".rels") or name == "[Content_Types].xml":
                root[:] = list(reversed(list(root)))
            self.parts[name] = ET.tostring(root, encoding="utf-16" if name == "visio/document.xml" else "utf-8", xml_declaration=True)
        self.assertEqual(self.compare(), [])

    def test_same_display_name_does_not_merge_distinct_master_and_style_ids(self):
        root = ET.fromstring(self.parts["visio/masters/masters.xml"])
        self.assertEqual([m.get("Name") for m in root], ["Same display"] * 2)
        self.assertEqual([m.get("ID") for m in root], ["7", "8"])
        root.remove(root[1])
        self.parts["visio/masters/masters.xml"] = ET.tostring(root)
        self.assertTrue(any("masters~1masters.xml" in change["path"] for change in self.compare()))

    def test_detects_each_intelligent_semantic_loss(self):
        mutations = [
            ("visio/pages/page1.xml", 'F="GUARD(2 in)"', 'F="2 in"'),
            ("visio/pages/page1.xml", 'F="Sheet.10!Width+Sheet.20!Width"', 'F="5"'),
            ("visio/pages/page1.xml", '<cp IX="1"/>東京', '東京'),
            ("visio/pages/page1.xml", 'FromCell="BeginX"', 'FromCell="EndX"'),
            ("visio/pages/page1.xml", 'Master="7"', 'Master="8"'),
            ("visio/masters/master1.xml", 'F="Height/2"', 'F="Height/3"'),
            ("visio/masters/master1.xml", 'N="DirX" V="1"', 'N="DirX" V="0"'),
            ("visio/masters/master1.xml", 'T="LineTo" IX="3"', 'T="MoveTo" IX="3"'),
            ("visio/document.xml", 'NameU="Green"', 'NameU="Blue"'),
            ("visio/theme/theme1.xml", 'val="13579B"', 'val="2468AC"'),
            ("visio/pages/pages.xml", 'BackPage="1"', 'BackPage="0"'),
            ("visio/pages/pages.xml", 'N="PageScale" V="0.02"', 'N="PageScale" V="1"'),
            ("visio/pages/pages.xml", 'N="Print" V="0"', 'N="Print" V="1"'),
        ]
        original = m3.authored_parts()
        for name, before, after in mutations:
            with self.subTest(part=name, before=before):
                self.parts = dict(original)
                self.assertIn(before.encode(), self.parts[name])
                self.parts[name] = self.parts[name].replace(before.encode(), after.encode(), 1)
                changes = self.compare()
                self.assertTrue(changes)
                self.assertTrue(all(change["path"].startswith("/" + name.replace("/", "~1")) for change in changes))

    def test_opaque_and_unknown_public_content_remains_in_oracle(self):
        self.parts["synthetic/opaque.bin"] += b"changed"
        self.assertEqual(len(self.compare()), 2)
        self.parts = m3.authored_parts()
        self.parts["synthetic/extension.json"] = b'{"public":true}'
        self.assertEqual(len(self.compare()), 1)

    def test_native_payload_and_its_registration_do_not_mask_public_loss(self):
        self.parts[m3.PRIVATE_PART] = b'{"ignored":"private cache"}'
        self.parts["macvisio/metadata/segment0.mvmeta"] = b"private segment"
        rel = ET.fromstring(self.parts["_rels/.rels"])
        ET.SubElement(rel, "{" + m3.R + "}Relationship", Id="native", Type=m3.PRIVATE_REL, Target=m3.PRIVATE_PART)
        self.parts["_rels/.rels"] = ET.tostring(rel)
        types = ET.fromstring(self.parts["[Content_Types].xml"])
        ET.SubElement(types, "{" + m3.C + "}Default", Extension="json", ContentType="application/json")
        ET.SubElement(types, "{" + m3.C + "}Default", Extension="mvmeta", ContentType="application/octet-stream")
        self.parts["[Content_Types].xml"] = ET.tostring(types)
        self.assertEqual(self.compare(), [])
        self.parts["visio/pages/page1.xml"] = self.parts["visio/pages/page1.xml"].replace(b"Local override", b"Data loss")
        self.assertTrue(self.compare())

    def test_unknown_content_in_metadata_directory_is_not_discarded(self):
        for name in ["macvisio/metadata/public.xml", "macvisio/metadata/segment01.mvmeta", "macvisio/metadata/segment9223372036854775808.mvmeta"]:
            with self.subTest(name=name):
                self.parts = m3.authored_parts()
                self.parts[name] = b"<public/>" if name.endswith(".xml") else b"public"
                self.assertTrue(self.compare())

    def test_rejects_duplicate_unsafe_and_entity_package_parts(self):
        self.parts["../escape.xml"] = b"<escape/>"
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            self.compare()
        self.parts = m3.authored_parts()
        self.parts["visio/pages/page1.xml"] = b'<!DOCTYPE x [<!ENTITY e "a">]><x>&e;</x>'
        with self.assertRaisesRegex(ValueError, "DTD/entity"):
            self.compare()
        self.parts["visio/pages/page1.xml"] = '<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE x [<!ENTITY e "a">]><x>&e;</x>'.encode("utf-16")
        with self.assertRaisesRegex(ValueError, "DTD/entity"):
            self.compare()
        with zipfile.ZipFile(self.changed, "w") as archive:
            archive.writestr("duplicate", b"a")
            with self.assertWarns(UserWarning):
                archive.writestr("duplicate", b"b")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            m3.snapshot(self.changed)


if __name__ == "__main__":
    unittest.main()
