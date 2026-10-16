#!/usr/bin/env python3
"""Verify real candidate bytes and require retained acceptance for stable publication."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

from release_policy import (PUBLIC_KEY, bundle_platform, check_bundle_channel, require,
                            safe_local, sha256, validate_archive, validate_stable_manifest,
                            version_tuple)


def verify(directory, channel, manifest=None, candidate_only=False):
    directory = Path(directory).resolve()
    report_path = directory / 'release-verification.json'
    # A failed second verification cannot leave a stale accepted report behind.
    report_path.unlink(missing_ok=True)
    require(not candidate_only or channel == 'stable', 'Candidate-only applies to stable preparation')
    require(channel != 'stable' or manifest or candidate_only, 'Stable publication requires a manifest')
    require(not manifest or channel == 'stable', 'Development artifacts cannot use stable manifests')
    feed_path = directory / 'appcast.xml'
    require(feed_path.stat().st_size <= 1024 * 1024, 'Appcast exceeds size budget')
    feed_bytes = feed_path.read_bytes()
    feed_bytes.decode('utf-8')
    require(b'\x00' not in feed_bytes, 'Appcast must be UTF-8 XML')
    require(b'<!DOCTYPE' not in feed_bytes.upper() and b'<!ENTITY' not in feed_bytes.upper(), 'Appcast must not declare entities')
    signature_helper = str(Path(__file__).with_name('verify-update-signature.swift'))
    # Authenticate the exact feed prefix before trusting its XML/enclosure URL.
    # This uses the pinned public key independently of any private signing key.
    subprocess.run(['swift', signature_helper, '--feed', str(feed_path), PUBLIC_KEY], check=True)
    feed = ET.fromstring(feed_bytes)
    ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    items = feed.findall('./channel/item')
    require(len(items) == 1, 'Candidate appcast must contain exactly one item')
    item = items[0]
    enclosures = item.findall('enclosure')
    require(len(enclosures) == 1, 'Candidate appcast must contain exactly one enclosure')
    enclosure = enclosures[0]
    url = urllib.parse.urlparse(enclosure.get('url', ''))
    require(url.scheme == 'https' and url.netloc == 'github.com' and not url.query and not url.fragment, 'Unexpected archive URL')
    archive = safe_local(directory, Path(url.path).name)
    require(archive.stat().st_size <= 1024 * 1024 * 1024, 'Release archive exceeds size budget')
    require(int(enclosure.get('length', '-1')) == archive.stat().st_size, 'Archive length mismatch')
    signature = enclosure.get(ns + 'edSignature')
    require(signature, 'Sparkle archive signature required')
    with zipfile.ZipFile(archive) as package:
        validate_archive(package)
        require(package.testzip() is None, 'ZIP CRC mismatch')
        info = plistlib.loads(package.read('MacVisio.app/Contents/Info.plist'))
    check_bundle_channel(info, channel)
    version = info['CFBundleShortVersionString']
    require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'Invalid candidate version')
    require(item.findtext(ns + 'version') == info['CFBundleVersion'], 'Appcast build mismatch')
    require(item.findtext(ns + 'shortVersionString') == version, 'Appcast version mismatch')
    tag = 'v' + version
    if channel == 'development':
        require(re.fullmatch(r'/acousland/MacVisio/releases/download/development-v' + re.escape(version) + r'-[0-9a-f]{12}/MacVisio-' + re.escape(version) + r'\.zip', url.path), 'Development archive must use a development release URL')
        tag = url.path.split('/')[-2]
        require(info['SUFeedURL'] == f'https://github.com/acousland/MacVisio/releases/download/{tag}/appcast.xml',
                'Development bundle feed and archive release tag differ; rebuild for this revision')
    else:
        require(url.path == f'/acousland/MacVisio/releases/download/{tag}/MacVisio-{version}.zip', 'Stable archive URL mismatch')
    tools = Path('.build/artifacts/sparkle/Sparkle/bin')
    signing = ['--ed-key-file', os.environ['SPARKLE_PRIVATE_KEY_FILE']] if os.environ.get('SPARKLE_PRIVATE_KEY_FILE') else ['--account', 'MacVisio']
    subprocess.run(['swift', signature_helper, str(archive), info['SUPublicEDKey'], signature], check=True)
    subprocess.run([str(tools / 'sign_update'), *signing, '--verify', str(archive), signature], check=True)
    subprocess.run([str(tools / 'sign_update'), *signing, '--verify', str(feed_path)], check=True)
    with tempfile.TemporaryDirectory(prefix='MacVisio-release-check-') as temporary:
        subprocess.run(['ditto', '-x', '-k', str(archive), temporary], check=True)
        extracted = Path(temporary) / 'MacVisio.app'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(extracted)], check=True)
        require(os.access(extracted / 'Contents/MacOS/MacVisio', os.X_OK), 'Executable mode missing')
        require((extracted / 'Contents/Frameworks/Sparkle.framework/Versions/Current').is_symlink(), 'Sparkle framework symlink missing')
        signature_info = subprocess.run(['codesign', '-dv', '--verbose=4', str(extracted)], capture_output=True, text=True, check=True).stderr
        developer_id = 'Authority=Developer ID Application:' in signature_info
        team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', signature_info, re.M)
        hardened = bool(re.search(r'flags=.*\bruntime\b', signature_info))
        notarized = False
        if developer_id:
            staple = subprocess.run(['xcrun', 'stapler', 'validate', str(extracted)], capture_output=True)
            if staple.returncode == 0:
                assessment = subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(extracted)], capture_output=True, text=True)
                notarized = assessment.returncode == 0 and 'Notarized Developer ID' in assessment.stderr
        platform = bundle_platform(extracted)
    # The feed must advertise the true deployment floor of every bundled binary.
    minimum = max(platform['minimumMacOSByArchitecture'].values(), key=version_tuple)
    require(version_tuple(item.findtext(ns + 'minimumSystemVersion', '0')) >= version_tuple(minimum), 'Appcast advertises unsupported macOS')
    candidate = {'version': version, 'build': info['CFBundleVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
                 'sha256': sha256(archive), 'bytes': archive.stat().st_size, 'feedSHA256': sha256(feed_path),
                 'feedURL': info['SUFeedURL'], 'platform': platform}
    report = {'schemaVersion': 1, 'channel': channel, 'releaseTag': tag, 'candidate': candidate,
              'zipCRCVerified': True, 'archiveSignatureVerified': True, 'feedSignatureVerified': True,
              'feedPublicKeySignatureVerified': True,
              'bundleSignatureVerified': True, 'executableModeVerified': True, 'frameworkSymlinksVerified': True,
              'developerIDSigned': developer_id, 'teamID': team.group(1) if team else None,
              'hardenedRuntime': hardened, 'notarized': notarized, 'publicationAccepted': False}
    if channel == 'stable':
        require(developer_id and hardened and notarized, 'Stable candidate requires Developer ID, hardened runtime and notarization')
        if not candidate_only:
            accepted = validate_stable_manifest(manifest, candidate, report)
            current_commit = subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
            require(accepted['sourceCommit'] == current_commit, 'Manifest source commit differs from checked-out release source')
            report['manifestSHA256'] = sha256(manifest)
            report['sourceCommit'] = current_commit
            report['publicationAccepted'] = True
            report['qualificationExceptions'] = accepted.get('qualificationExceptions', [])
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--channel', choices=['stable', 'development'], default='development')
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--candidate-only', action='store_true')
    args = parser.parse_args()
    verify(args.directory, args.channel, args.manifest, args.candidate_only)


if __name__ == '__main__':
    main()
