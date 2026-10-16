"""Policy fixtures and one real signed development feed; no release acceptance."""
import copy
import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import warnings
from unittest.mock import patch
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import release_policy as policy

spec = importlib.util.spec_from_file_location('verify_release', SCRIPTS / 'verify-release.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

# Exact public bytes produced by pinned Sparkle 2.10 for the local development
# candidate 0.23.3-e16604f368d2. Retained inline so CI needs no signing key/network.
# This feed was verified with the pinned public key before adding parser tests.
SPARKLE_210_FEED = b'''<?xml version="1.0" standalone="yes"?><!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires re-signing this file with generate_appcast or sign_update! The signed signature will be embedded at the end of this file.
--><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>MacVisio</title>
        <item>
            <title>0.23.3</title>
            <pubDate>Fri, 16 Oct 2026 10:28:03 +1100</pubDate>
            <link>https://github.com/acousland/MacVisio</link>
            <sparkle:version>28</sparkle:version>
            <sparkle:shortVersionString>0.23.3</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/acousland/MacVisio/releases/download/development-v0.23.3-e16604f368d2/MacVisio-0.23.3.zip" length="18214188" type="application/octet-stream" sparkle:edSignature="39d3gC4A/ZyLVg/dF9CNOMH56gougcds12ukYWN21379cKclDREYZI678BcFjx+3ZCSCuPwa3m8GMcUral+TDg=="></enclosure>
        </item>
    </channel>
</rss><!-- sparkle-signatures:
edSignature: hHQ4UL/qTC0XOMTcpMUpgf3eD/c4v1XpLK1aTiFSkr6nBYQf1ekAG5Z1S763vi574yRVK/k5sIv5zVTi9W1gBQ==
length: 1136
-->
'''


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.info = {'CFBundleIdentifier': 'com.macvisio.editor', 'CFBundleShortVersionString': '1.2.3',
                     'CFBundleVersion': '42', 'LSMinimumSystemVersion': '13.0',
                     'MacVisioReleaseChannel': 'stable', 'SUFeedURL': policy.STABLE_FEED,
                     'SUPublicEDKey': policy.PUBLIC_KEY, 'SURequireSignedFeed': True,
                     'SUVerifyUpdateBeforeExtraction': True, 'SUEnableAutomaticChecks': True}
        self.platform = {'architectures': ['arm64'], 'minimumMacOSByArchitecture': {'arm64': '27.0'},
                         'binaries': [{'path': 'Contents/MacOS/MacVisio', 'sha256': 'c' * 64,
                                       'minimumMacOSByArchitecture': {'arm64': '27.0'}}]}
        self.candidate = {'version': '1.2.3', 'build': '42', 'sha256': 'a' * 64,
                          'feedSHA256': 'b' * 64, 'bytes': 100, 'platform': self.platform,
                          'feedURL': policy.STABLE_FEED, 'bundleIdentifier': 'com.macvisio.editor'}
        self.observations = {key: True for key in ('archiveSignatureVerified', 'feedSignatureVerified', 'bundleSignatureVerified', 'developerIDSigned', 'notarized', 'hardenedRuntime')}
        self.observations['teamID'] = 'ABCD123456'

    def manifest_fixture(self):
        """Build transient simulated evidence to test the validator, not real journeys."""
        artifact = self.root / 'simulated-run.txt'
        artifact.write_text('SIMULATED TEST DATA ONLY')
        acceptance = {}
        for gate, checks in policy.GATES.items():
            record = {'gate': gate, 'status': 'accepted', 'candidateSHA256': self.candidate['sha256'],
                      'reviewer': 'synthetic-test', 'recordedAt': '2026-10-16T00:00:00Z',
                      'platforms': [{'architecture': 'arm64', 'macOS': '27.0'}],
                      'checks': {key: 'passed' for key in checks},
                      'artifacts': [{'path': artifact.name, 'sha256': policy.sha256(artifact)}]}
            path = self.root / f'{gate}.json'
            path.write_text(json.dumps(record))
            acceptance[gate] = {'path': path.name, 'sha256': policy.sha256(path)}
        manifest = {'schemaVersion': 1, 'channel': 'stable', 'candidate': copy.deepcopy(self.candidate),
                    'sourceCommit': 'd' * 40, 'teamID': 'ABCD123456', 'acceptance': acceptance}
        path = self.root / 'manifest.json'
        path.write_text(json.dumps(manifest))
        return path, manifest

    def check_manifest(self, path, observations=None):
        return policy.validate_stable_manifest(path, self.candidate, observations or self.observations)

    def test_exact_candidate_and_retained_evidence_are_accepted_by_policy(self):
        path, manifest = self.manifest_fixture()
        self.assertEqual(self.check_manifest(path), manifest)

    def test_every_actual_signature_control_is_required_despite_environment(self):
        path, _ = self.manifest_fixture()
        with patch.dict(os.environ, {'MACVISIO_ALLOW_UNNOTARIZED': '1', 'MACVISIO_RELEASE_CHANNEL': 'development'}):
            for field in ('archiveSignatureVerified', 'feedSignatureVerified', 'bundleSignatureVerified', 'developerIDSigned', 'notarized', 'hardenedRuntime'):
                with self.subTest(field=field), self.assertRaises(ValueError):
                    observations = dict(self.observations, **{field: False})
                    self.check_manifest(path, observations)

    def test_candidate_archive_feed_platform_build_and_team_cannot_be_swapped(self):
        for field, value in [('sha256', 'e' * 64), ('feedSHA256', 'e' * 64), ('build', '43'),
                             ('platform', dict(self.platform, architectures=['x86_64'])), ('feedURL', policy.DEVELOPMENT_FEED_PREFIX)]:
            path, manifest = self.manifest_fixture()
            manifest['candidate'][field] = value
            path.write_text(json.dumps(manifest))
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check_manifest(path)
        path, manifest = self.manifest_fixture()
        manifest['teamID'] = 'OTHER12345'
        path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            self.check_manifest(path)

    def test_missing_gate_or_retained_artifacts_blocks_acceptance(self):
        for mutation in ('missingGate', 'noArtifacts', 'unaccepted', 'wrongCandidate', 'wrongPlatform', 'failedCheck'):
            path, manifest = self.manifest_fixture()
            if mutation == 'missingGate':
                del manifest['acceptance']['installedUpdate']
            else:
                record_path = self.root / 'installedUpdate.json'
                record = json.loads(record_path.read_text())
                if mutation == 'noArtifacts': record['artifacts'] = []
                if mutation == 'unaccepted': record['status'] = 'unaccepted'
                if mutation == 'wrongCandidate': record['candidateSHA256'] = '0' * 64
                if mutation == 'wrongPlatform': record['platforms'] = [{'architecture': 'arm64', 'macOS': '26.0'}]
                if mutation == 'failedCheck': record['checks']['invalid-signature'] = 'failed'
                record_path.write_text(json.dumps(record))
                manifest['acceptance']['installedUpdate']['sha256'] = policy.sha256(record_path)
            path.write_text(json.dumps(manifest))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.check_manifest(path)

    def test_changed_evidence_bytes_are_rejected(self):
        path, _ = self.manifest_fixture()
        (self.root / 'security.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'digest'):
            self.check_manifest(path)
        path, _ = self.manifest_fixture()
        (self.root / 'simulated-run.txt').write_text('modified')
        with self.assertRaisesRegex(ValueError, 'digest'):
            self.check_manifest(path)

    def test_evidence_traversal_and_symlinks_outside_root_are_rejected(self):
        (self.root / 'inside').write_text('test')
        (self.root / 'outside-link').symlink_to(SCRIPTS / 'release_policy.py')
        for name in ('../inside', '/etc/passwd', 'a\\b', 'outside-link'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                policy.safe_local(self.root, name)

    def test_oversized_manifest_rejected_before_json_parse(self):
        path = self.root / 'big.json'
        with path.open('wb') as stream:
            stream.truncate(1024 * 1024 + 1)
        with self.assertRaisesRegex(ValueError, 'exceeds'):
            policy.load_json(path)

    def test_development_build_cannot_use_stable_feed_or_channel(self):
        app = self.root / 'MacVisio.app'
        (app / 'Contents').mkdir(parents=True)
        plist = app / 'Contents/Info.plist'
        plist.write_bytes(plistlib.dumps(self.info))
        policy.configure_bundle(app, 'development')
        info = plistlib.loads(plist.read_bytes())
        policy.check_bundle_channel(info, 'development')
        self.assertFalse(info['SUEnableAutomaticChecks'])
        with self.assertRaises(ValueError): policy.check_bundle_channel(info, 'stable')
        info['SUFeedURL'] = policy.STABLE_FEED
        with self.assertRaises(ValueError): policy.check_bundle_channel(info, 'development')

    def test_default_support_report_excludes_secrets_preferences_paths_and_drawing_text(self):
        app = self.root / 'MacVisio.app'
        (app / 'Contents').mkdir(parents=True)
        self.info.update({'drawingText': 'secret diagram text', 'credential': 'token', 'recentFile': '/Users/private/client.vsdx'})
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        with patch.dict(os.environ, {'SPARKLE_PRIVATE_KEY': 'private key material'}):
            report = json.dumps(policy.support_report(app))
        for secret in ('secret diagram text', 'credential', '/Users/private', 'private key material', 'SUPublicEDKey'):
            self.assertNotIn(secret, report)

    def test_macho_floor_parser_uses_build_and_legacy_commands(self):
        self.assertEqual(policy.parse_macos_minimum('cmd LC_BUILD_VERSION\n platform 1\n minos 27.0\n sdk 27.1'), '27.0')
        self.assertEqual(policy.parse_macos_minimum('cmd LC_VERSION_MIN_MACOSX\n version 13.0\n sdk 14.0'), '13.0')
        with self.assertRaises(ValueError): policy.parse_macos_minimum('cmd LC_BUILD_VERSION\n platform 2\n minos 17.0')

    def test_platform_inventory_intersects_all_binary_architectures_and_raises_floor(self):
        app = self.root / 'MacVisio.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Helpers').mkdir()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        (app / 'Contents/MacOS/MacVisio').write_bytes(bytes.fromhex('cffaedfe') + b'app')
        (app / 'Contents/Helpers/reader').write_bytes(bytes.fromhex('cffaedfe') + b'helper')
        def run(command, **kwargs):
            helper = command[-1].endswith('reader')
            output = ('arm64' if helper else 'arm64 x86_64') if command[0] == 'lipo' else 'cmd LC_BUILD_VERSION\n platform 1\n minos ' + ('27.0' if helper else '13.0')
            return subprocess.CompletedProcess(command, 0, stdout=output)
        inventory = policy.bundle_platform(app, run=run)
        self.assertEqual(inventory['architectures'], ['arm64'])
        self.assertEqual(inventory['minimumMacOSByArchitecture'], {'arm64': '27.0'})
        self.assertEqual(len(inventory['binaries']), 2)

    def archive(self, entries):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as package:
            package.writestr('MacVisio.app/Contents/Info.plist', plistlib.dumps(self.info))
            with warnings.catch_warnings():
                warnings.simplefilter('ignore', UserWarning)
                for entry, content in entries: package.writestr(entry, content)
        buffer.seek(0)
        return zipfile.ZipFile(buffer)

    def test_release_archive_rejects_traversal_ambiguity_and_duplicate_entries(self):
        for name in ('../outside', '/outside', 'MacVisio.app/../../outside', 'MacVisio.app/a/./b',
                     'MacVisio.app/a//b', 'MacVisio.app/a\\b', 'outside', 'MacVisio.app/Contents/Info.plist'):
            with self.subTest(name=name), self.archive([(name, b'test')]) as package, self.assertRaises(ValueError):
                policy.validate_archive(package)

    def test_release_archive_preserves_safe_framework_symlink_and_blocks_escape(self):
        for target, accepted in [('B', True), ('/etc', False), ('../../../../etc', False)]:
            link = zipfile.ZipInfo('MacVisio.app/Contents/Frameworks/Sparkle.framework/Versions/Current')
            link.external_attr = 0o120777 << 16
            with self.subTest(target=target), self.archive([(link, target)]) as package:
                if accepted: policy.validate_archive(package)
                else:
                    with self.assertRaises(ValueError): policy.validate_archive(package)

    def test_release_archive_blocks_write_through_symlink(self):
        link = zipfile.ZipInfo('MacVisio.app/Contents/link')
        link.external_attr = 0o120777 << 16
        with self.archive([(link, 'Other'), ('MacVisio.app/Contents/link/data', b'x')]) as package:
            with self.assertRaises(ValueError): policy.validate_archive(package)

    def test_release_archive_bounds_declared_uncompressed_size_before_extraction(self):
        with self.archive([('MacVisio.app/file', b'x')]) as package:
            package.infolist()[-1].file_size = 513 * 1024 * 1024
            with self.assertRaisesRegex(ValueError, 'too large'): policy.validate_archive(package)

    def test_stable_verifier_requires_manifest_before_reading_candidate_and_removes_stale_report(self):
        report = self.root / 'release-verification.json'
        report.write_text('{"publicationAccepted":true}')
        with patch.dict(os.environ, {'MACVISIO_ALLOW_UNNOTARIZED': '1'}):
            with self.assertRaisesRegex(ValueError, 'requires a manifest'):
                verifier.verify(self.root, 'stable')
        self.assertFalse(report.exists())

    def test_development_verifier_rejects_stable_manifest_and_candidate_only(self):
        with self.assertRaises(ValueError): verifier.verify(self.root, 'development', self.root / 'manifest.json')
        with self.assertRaises(ValueError): verifier.verify(self.root, 'development', candidate_only=True)

    def test_packager_defaults_to_development_and_stable_fails_without_manifest(self):
        result = subprocess.run(['bash', str(SCRIPTS / 'package-release.sh'), '--channel', 'stable'], capture_output=True, text=True,
                                env=dict(os.environ, MACVISIO_ALLOW_UNNOTARIZED='1'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires --manifest', result.stderr)

    def verifier_fixture(self, developer_id=True, notarized=True):
        archive = self.root / 'MacVisio-1.2.3.zip'
        with self.archive([]) as package:
            archive.write_bytes(package.fp.getvalue())
        (self.root / 'appcast.xml').write_text(
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
            '<sparkle:version>42</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>'
            '<sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>'
            f'<enclosure url="https://github.com/acousland/MacVisio/releases/download/v1.2.3/{archive.name}" length="{archive.stat().st_size}" sparkle:edSignature="synthetic"/>'
            '</item></channel></rss>')
        self.candidate.update({'sha256': policy.sha256(archive), 'bytes': archive.stat().st_size,
                               'feedSHA256': policy.sha256(self.root / 'appcast.xml')})
        def run(command, **kwargs):
            stderr = ''
            if command[0] == 'ditto':
                app = Path(command[-1]) / 'MacVisio.app'
                (app / 'Contents/MacOS').mkdir(parents=True)
                executable = app / 'Contents/MacOS/MacVisio'
                executable.write_bytes(b'simulated')
                executable.chmod(0o755)
                versions = app / 'Contents/Frameworks/Sparkle.framework/Versions'
                (versions / 'B').mkdir(parents=True)
                (versions / 'Current').symlink_to('B')
            elif command[:2] == ['codesign', '-dv']:
                stderr = 'Authority=Developer ID Application: Synthetic\nTeamIdentifier=ABCD123456\nCodeDirectory flags=0x10000(runtime)\n' if developer_id else 'Signature=adhoc\n'
            elif command[0] == 'spctl':
                stderr = 'source=Notarized Developer ID' if notarized else 'rejected'
            elif command[:3] == ['git', 'rev-parse', 'HEAD']:
                return subprocess.CompletedProcess(command, 0, stdout='d' * 40 + '\n', stderr='')
            return subprocess.CompletedProcess(command, 0, stdout='', stderr=stderr)
        return run

    def test_verifier_uses_observed_apple_signature_not_manifest_or_environment(self):
        for developer_id, notarized in [(False, False), (True, False)]:
            run = self.verifier_fixture(developer_id, notarized)
            manifest_path, _ = self.manifest_fixture()
            with self.subTest(developer_id=developer_id, notarized=notarized), \
                    patch.dict(os.environ, {'MACVISIO_ALLOW_UNNOTARIZED': '1'}), \
                    patch.object(verifier.subprocess, 'run', side_effect=run), \
                    patch.object(verifier, 'bundle_platform', return_value=self.platform), \
                    self.assertRaisesRegex(ValueError, 'Developer ID, hardened runtime and notarization'):
                verifier.verify(self.root, 'stable', manifest_path)
            self.assertFalse((self.root / 'release-verification.json').exists())

    def test_candidate_only_verification_never_accepts_publication_and_final_gate_requires_evidence(self):
        run = self.verifier_fixture()
        with patch.object(verifier.subprocess, 'run', side_effect=run), \
                patch.object(verifier, 'bundle_platform', return_value=self.platform), patch('builtins.print'):
            report = verifier.verify(self.root, 'stable', candidate_only=True)
            self.assertFalse(report['publicationAccepted'])
            path, _ = self.manifest_fixture()
            report = verifier.verify(self.root, 'stable', path)
            self.assertTrue(report['publicationAccepted'])
            self.assertEqual(report['manifestSHA256'], policy.sha256(path))
            (self.root / 'simulated-run.txt').unlink()
            with self.assertRaises(ValueError): verifier.verify(self.root, 'stable', path)
            self.assertFalse((self.root / 'release-verification.json').exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'CryptoKit verifier is a macOS release tool')
    def test_public_key_verifier_accepts_rfc8032_vector_and_rejects_changed_archive(self):
        # RFC 8032 section 7.1, test 1: public, non-secret empty-message vector.
        public = base64.b64encode(bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')).decode()
        signature = base64.b64encode(bytes.fromhex('e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')).decode()
        archive = self.root / 'archive'
        archive.write_bytes(b'')
        command = ['swift', str(SCRIPTS / 'verify-update-signature.swift'), str(archive), public, signature]
        valid = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        archive.write_bytes(b'changed')
        changed = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(changed.returncode, 0)
        self.assertIn('does not match', changed.stderr)

    def check_feed(self, data, public_key=policy.PUBLIC_KEY):
        path = self.root / 'signed-feed.xml'
        path.write_bytes(data)
        return subprocess.run(['swift', str(SCRIPTS / 'verify-update-signature.swift'), '--feed', str(path), public_key],
                              capture_output=True, text=True)

    @unittest.skipUnless(sys.platform == 'darwin', 'CryptoKit verifier is a macOS release tool')
    def test_pinned_public_key_accepts_real_sparkle210_feed_and_exact_signed_boundary(self):
        self.assertEqual(len(SPARKLE_210_FEED), 1280)
        self.assertEqual(SPARKLE_210_FEED.index(b'<!-- sparkle-signatures:'), 1136)
        self.assertEqual(SPARKLE_210_FEED[:1136][-6:], b'</rss>')
        result = self.check_feed(SPARKLE_210_FEED)
        self.assertEqual(result.returncode, 0, result.stderr)
        wrong_key = base64.b64encode(bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')).decode()
        result = self.check_feed(SPARKLE_210_FEED, wrong_key)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match the pinned public key', result.stderr)

    @unittest.skipUnless(sys.platform == 'darwin', 'CryptoKit verifier is a macOS release tool')
    def test_signed_feed_rejects_tamper_duplicate_footer_wrong_length_and_unsigned_trailing_content(self):
        original = SPARKLE_210_FEED
        footer = original[1136:]
        mutations = {
            'changed-signed-version': original.replace(b'<sparkle:version>28', b'<sparkle:version>29'),
            'changed-signature': original.replace(b'edSignature: hHQ4', b'edSignature: AHQ4'),
            'short-length': original.replace(b'length: 1136', b'length: 1135'),
            'long-length': original.replace(b'length: 1136', b'length: 1137'),
            'zero-length': original.replace(b'length: 1136', b'length: 0'),
            'overflow-length': original.replace(b'length: 1136', b'length: 9999999999999999999999999999999'),
            'noncanonical-length': original.replace(b'length: 1136', b'length: 01136'),
            'duplicate-length': original.replace(b'length: 1136', b'length: 1136\nlength: 1136'),
            'duplicate-signature': original.replace(b'length: 1136', b'edSignature: ' + b'A' * 86 + b'==\nlength: 1136'),
            'duplicate-footer': original + footer,
            'duplicate-token-in-prefix': b'<!-- SPARKLE-SIGNATURES -->' + original,
            'unsigned-xml-before-footer': original[:1136] + b'<item>unsigned</item>' + footer,
            'unsigned-xml-with-adjusted-length': (original[:1136] + b'<item>unsigned</item>' + footer).replace(b'length: 1136', b'length: 1157'),
            'unsigned-xml-after-footer': original + b'<item>unsigned</item>',
            'unsigned-comment-after-footer': original + b'<!-- unsigned -->',
            'trailing-extra-newline': original + b'\n',
            'trailing-space': original + b' ',
            'no-final-format-newline': original[:-1],
            'missing-footer': original[:1136],
            'noncanonical-marker': original.replace(b'<!-- sparkle-signatures:', b'<!--sparkle-signatures:'),
            'crlf-footer': original[:1136] + footer.replace(b'\n', b'\r\n'),
            'invalid-base64': original.replace(b'edSignature: hHQ4', b'edSignature: ?HQ4'),
            'invalid-utf8': b'\xff' + original,
            'embedded-nul': original[:100] + b'\x00' + original[100:],
        }
        for case, data in mutations.items():
            with self.subTest(case=case):
                result = self.check_feed(data)
                self.assertNotEqual(result.returncode, 0, case)

    @unittest.skipUnless(sys.platform == 'darwin', 'CryptoKit verifier is a macOS release tool')
    def test_signed_feed_read_is_bounded_before_footer_parsing(self):
        result = self.check_feed(SPARKLE_210_FEED + b'x' * (1024 * 1024))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exceeds the 1 MiB limit', result.stderr)

    def test_feed_public_key_failure_stops_before_xml_and_private_signer(self):
        # The XML is deliberately malformed: public-key verification must happen
        # before parsing it or consulting any private signing key/account.
        (self.root / 'appcast.xml').write_bytes(b'<unsigned broken xml')
        expected = ['swift', str(SCRIPTS / 'verify-update-signature.swift'), '--feed', str((self.root / 'appcast.xml').resolve()), policy.PUBLIC_KEY]
        with patch.object(verifier.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, expected)) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                verifier.verify(self.root, 'stable', candidate_only=True)
        run.assert_called_once_with(expected, check=True)
        self.assertFalse((self.root / 'release-verification.json').exists())


if __name__ == '__main__':
    unittest.main()
