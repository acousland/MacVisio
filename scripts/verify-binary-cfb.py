#!/usr/bin/env python3
"""Independent CFB structure validation; requires development-only olefile 0.47."""
import json
import pathlib
import struct
import olefile

root = pathlib.Path(__file__).resolve().parent.parent
paths = sorted((root / 'Examples').glob('*.vsd'))
assert len(paths) == 5, 'Generate the five examples before verification'
for path in paths:
    with olefile.OleFileIO(path, raise_defects=olefile.DEFECT_INCORRECT) as file:
        assert not file.parsing_issues, (path, file.parsing_issues)
        assert file.root.clsid == '00021A14-0000-0000-C000-000000000046', path
        public = file.openstream('VisioDocument').read()
        assert public.startswith(b'Visio (TM) Drawing\r\n\0') and public[26] == 11
        assert struct.unpack_from('<I', public, 28)[0] == len(public)
        assert file.openstream('VisioInformation').read() == bytes.fromhex('FEFF000004000200') + bytes(20)
        seen = set()
        def tree(sid, lower=None, upper=None, parent_red=False):
            if sid == 0xFFFFFFFF:
                return 1
            assert sid not in seen
            seen.add(sid)
            entry = file.direntries[sid]
            key = (len(entry.name.encode('utf-16le')), entry.name.upper())
            assert lower is None or lower < key
            assert upper is None or key < upper
            assert entry.color in (0, 1) and not (parent_red and entry.color == 0)
            left = tree(entry.sid_left, lower, key, entry.color == 0)
            right = tree(entry.sid_right, key, upper, entry.color == 0)
            assert left == right, (path, entry.name, left, right)
            return left + entry.color
        assert file.direntries[file.root.sid_child].color == 1
        tree(file.root.sid_child)
report = {'independentCFBParser': 'olefile ' + olefile.__version__, 'filesVerified': len(paths),
          'directoryRedBlackTreesVerified': True, 'publicVisioHeadersVerified': True,
          'windowsVisioValidated': False}
(root / 'build/binary-cfb-verification.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
