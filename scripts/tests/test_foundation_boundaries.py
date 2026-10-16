import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("foundation_boundaries", ROOT / "scripts/check-foundation-boundaries.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class FoundationBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        for path in AUDIT.foundation_paths(self.root):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("import Foundation\n", encoding="utf-8")

    def tearDown(self):
        self.temporary.cleanup()

    def change(self, source, name="PageRuntime.swift"):
        path = next(path for path in AUDIT.foundation_paths(self.root) if path.name == name)
        path.write_text(source, encoding="utf-8")

    def test_current_repository_and_allowed_platform_imports_pass(self):
        self.assertEqual(AUDIT.audit(ROOT), [])
        self.change("import Foundation\nimport CoreGraphics\n")
        self.change("import Foundation\nimport Darwin\n", "AtomicJobOutput.swift")
        self.change("import Foundation\nimport MacVisioInfrastructure\n", "UndoPayloadBudget.swift")
        self.assertEqual(AUDIT.audit(self.root), [])

    def test_module_scope_tracks_moved_files_and_disallows_reverse_import(self):
        infrastructure = [path for path in AUDIT.foundation_paths(ROOT) if path.parent.name == "MacVisioInfrastructure"]
        self.assertEqual({path.name for path in infrastructure}, {"ResourceBudget.swift", "LifecycleJobs.swift", "AtomicJobOutput.swift"})
        for path in infrastructure:
            self.assertFalse((ROOT / "Sources/MacVisio" / path.name).exists())
        self.change("import Foundation\nimport MacVisio\n", "LifecycleJobs.swift")
        self.assertTrue(any("prohibited import MacVisio" in error for error in AUDIT.audit(self.root)))

    def test_ui_imports_include_attributes_symbols_and_conditional_branches(self):
        for source in (
            "import AppKit\n",
            "@preconcurrency import AppKit\n",
            "@_implementationOnly import class AppKit.NSView\n",
            "#if canImport(AppKit)\nimport AppKit\n#endif\n",
            "import SwiftUI\n",
            "import WebKit\n",
        ):
            with self.subTest(source=source):
                self.change(source)
                self.assertEqual(len(AUDIT.audit(self.root)), 1)

    def test_comments_multiline_and_raw_strings_cannot_create_false_imports(self):
        source = '''// import AppKit
/* import SwiftUI /* nested import WebKit */ */
let sample = "import AppKit"
let multiline = """
import AppKit
"""
let raw = #"import AppKit"#
import Foundation
'''
        self.assertEqual(AUDIT.imports(source), [("Foundation", 8)])
        self.change(source)
        self.assertEqual(AUDIT.audit(self.root), [])

    def test_missing_files_and_unexpected_imports_fail_with_location(self):
        path = AUDIT.foundation_paths(self.root)[0]
        path.unlink()
        self.change("// header\nimport Darwin\n")
        errors = AUDIT.audit(self.root)
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("missing foundation source" in error for error in errors))
        self.assertTrue(any("PageRuntime.swift:2:" in error for error in errors))

    def test_cli_nonzero_is_a_real_audit_failure(self):
        self.change("import AppKit\n")
        result = subprocess.run(
            ["python3", str(ROOT / "scripts/check-foundation-boundaries.py"), "--root", str(self.root)],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("prohibited import AppKit", result.stderr)

    def test_formatter_uses_explicit_foundation_and_state_scope_and_fix_is_opt_in(self):
        tool = self.root / "fake-swift-format"
        log = self.root / "format.json"
        tool.write_text(
            "#!/usr/bin/env python3\nimport json, os, sys\n"
            "open(os.environ['FOUNDATION_FORMAT_TEST_LOG'], 'w').write(json.dumps(sys.argv[1:]))\n"
        )
        tool.chmod(0o755)
        environment = dict(os.environ, SWIFT_FORMAT_BIN=str(tool), FOUNDATION_FORMAT_TEST_LOG=str(log))
        script = ROOT / "scripts/check-foundation-format.sh"
        expected_scope = [str(ROOT / path) for path in AUDIT.FOUNDATION_FILES + AUDIT.STATE_FORMAT_FILES]
        self.assertEqual(len(expected_scope),len(set(expected_scope)))
        self.assertIn(str(ROOT / "Sources/MacVisio/Document.swift"),expected_scope)
        for mode, command in (("--check", "lint"), ("--fix", "format")):
            with self.subTest(mode=mode):
                subprocess.run(["bash", str(script), mode], env=environment, check=True, capture_output=True)
                arguments = json.loads(log.read_text())
                self.assertEqual(arguments[0], command)
                self.assertEqual(arguments[-len(expected_scope):], expected_scope)
                self.assertEqual("--in-place" in arguments, mode == "--fix")
        listed = subprocess.check_output(["bash", str(script), "--list"], text=True).splitlines()
        self.assertEqual(listed, expected_scope)
        self.assertEqual(subprocess.run(["bash", str(script), "--unknown"], capture_output=True).returncode, 2)


if __name__ == "__main__":
    unittest.main()
