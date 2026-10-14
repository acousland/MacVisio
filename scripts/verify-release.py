#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

directory = Path(sys.argv[1])
feed = ET.parse(directory / 'appcast.xml')
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
item = feed.find('./channel/item')
enclosure = item.find('enclosure')
archive = directory / Path(enclosure.get('url')).name
assert int(enclosure.get('length')) == archive.stat().st_size
assert enclosure.get(ns+'edSignature')
with zipfile.ZipFile(archive) as package:
    assert package.testzip() is None
    info = plistlib.loads(package.read('MacVisio.app/Contents/Info.plist'))
assert item.find(ns+'version').text == info['CFBundleVersion']
assert info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction']
assert info['SUPublicEDKey'] == 'AWjtiSJkcBmPtJUSkAWSuiXAhlr34FOKmGBlqVY+waA='
tools = Path('.build/artifacts/sparkle/Sparkle/bin')
signing = ['--ed-key-file',os.environ['SPARKLE_PRIVATE_KEY_FILE']] if os.environ.get('SPARKLE_PRIVATE_KEY_FILE') else ['--account','MacVisio']
subprocess.run([str(tools/'sign_update'),*signing,'--verify',str(archive),enclosure.get(ns+'edSignature')],check=True)
subprocess.run([str(tools/'sign_update'),*signing,'--verify',str(directory/'appcast.xml')],check=True)
with tempfile.TemporaryDirectory(prefix='MacVisio-release-check-') as temporary:
    subprocess.run(['ditto','-x','-k',str(archive),temporary],check=True)
    extracted = Path(temporary)/'MacVisio.app'
    subprocess.run(['codesign','--verify','--deep','--strict',str(extracted)],check=True)
    assert os.access(extracted/'Contents/MacOS/MacVisio',os.X_OK)
    assert (extracted/'Contents/Frameworks/Sparkle.framework/Versions/Current').is_symlink()
    signature = subprocess.run(['codesign','-dv','--verbose=4',str(extracted)],capture_output=True,text=True,check=True).stderr
    developer_id = 'Authority=Developer ID Application:' in signature
    notarized = False
    if developer_id:
        staple = subprocess.run(['xcrun','stapler','validate',str(extracted)],capture_output=True)
        if staple.returncode == 0:
            assessment = subprocess.run(['spctl','--assess','--type','execute','--verbose=2',str(extracted)],capture_output=True,text=True)
            notarized = assessment.returncode == 0 and 'Notarized Developer ID' in assessment.stderr
        if not notarized and os.environ.get('MACVISIO_ALLOW_UNNOTARIZED') != '1':
            raise RuntimeError('Developer ID release requires notarization; an explicit MACVISIO_ALLOW_UNNOTARIZED=1 override is available.')
report = {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
          'archive': str(archive), 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
          'bytes': archive.stat().st_size, 'zipCRCVerified': True,
          'archiveSignatureVerified': True, 'feedSignatureVerified': True, 'signedFeedRequired': True,
          'bundleSignatureVerified': True, 'executableModeVerified': True, 'frameworkSymlinksVerified': True,
          'developerIDSigned': developer_id, 'notarized': notarized,
          'notarizationOverride': developer_id and not notarized and os.environ.get('MACVISIO_ALLOW_UNNOTARIZED') == '1',
          'feedURL': info['SUFeedURL'], 'minimumMacOS': info['LSMinimumSystemVersion']}
(directory / 'release-verification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
