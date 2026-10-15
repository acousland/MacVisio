#!/usr/bin/env python3
"""Make NEW public-only VSDX validation copies from a hash-bound synthetic corpus.

Originals are never rewritten. Binary VSD needs an independent CFB stripper and
is deliberately unsupported here. This is tooling, not compatibility evidence.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import posixpath
import re
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

MAX_ZIP = 100 * 1024 * 1024
MAX_EXPANDED = 128 * 1024 * 1024
MAX_PART = 16 * 1024 * 1024


def xml(data):
    if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper(): raise ValueError('DTD/entity declarations are unsupported')
    return ET.fromstring(data)


def is_private(name):
    return name.lower().lstrip('/').startswith('macvisio/')


def read_parts(path):
    if path.stat().st_size > MAX_ZIP: raise ValueError('Package exceeds size limit')
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [e.filename for e in entries]
        if len(entries) > 10000 or len(set(names)) != len(names): raise ValueError('Too many or duplicate ZIP entries')
        if sum(e.file_size for e in entries) > MAX_EXPANDED or any(e.file_size > MAX_PART for e in entries): raise ValueError('Expanded package exceeds size limit')
        if any(name.startswith('/') or '\\' in name or '..' in name.split('/') or ':' in name for name in names): raise ValueError('Unsafe ZIP part name')
        return {name: archive.read(name) for name in names}


def strip(parts):
    removed = sorted(name for name in parts if is_private(name))
    result = {name: data for name, data in parts.items() if name not in removed}
    for name, data in list(result.items()):
        if name == '[Content_Types].xml' or name.endswith('.rels'):
            root = xml(data)
            changed = False
            for child in list(root):
                target = child.get('Target', '')
                owner_dir = posixpath.dirname(posixpath.dirname(name)) if name.endswith('.rels') else ''
                resolved = posixpath.normpath(posixpath.join(owner_dir, target)) if not target.startswith('/') else target.lstrip('/')
                if is_private(child.get('PartName', '')) or is_private(resolved) or child.get('Type', '').lower().startswith('urn:macvisio:'):
                    root.remove(child)
                    changed = True
            if changed: result[name] = ET.tostring(root, encoding='utf-8', xml_declaration=True)
    return result, removed


def prepare(source, output):
    if source.is_symlink(): raise ValueError('Linked source directory is unsupported')
    source = source.resolve(strict=True)
    output = output.absolute()
    if output.exists() or output.is_symlink(): raise ValueError('Output must be a new directory')
    if source == output or source in output.resolve().parents: raise ValueError('Output must be outside the source corpus')
    manifest_file = source / 'manifest.json'
    if manifest_file.is_symlink(): raise ValueError('Linked manifest is unsupported')
    manifest = json.loads(manifest_file.read_text(encoding='utf-8-sig'))
    if manifest.get('schemaVersion') != 1 or manifest.get('syntheticOnly') is not True: raise ValueError('Explicit schemaVersion=1 syntheticOnly=true required')
    fixtures = manifest.get('fixtures')
    if not isinstance(fixtures, list) or not fixtures: raise ValueError('Nonempty fixture list required')
    seen = set()
    prepared = []
    for entry in fixtures:
        name = entry.get('file')
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_.-]+\.vsdx', name, re.I) or name in seen: raise ValueError('Unique plain VSDX filenames required')
        seen.add(name)
        path = source / name
        if path.is_symlink() or not path.is_file(): raise ValueError('Regular fixture files required')
        if entry.get('format') != 'vsdx' or not isinstance(entry.get('expected', {}).get('pages'), list): raise ValueError('VSDX format and expected pages required')
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != entry.get('sha256'): raise ValueError('Source SHA-256 mismatch')
        parts, removed = strip(read_parts(path))
        prepared.append((entry, digest, parts, removed))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.public-validation-', dir=output.parent) as temporary:
        stage = Path(temporary) / 'corpus'
        stage.mkdir()
        for entry, digest, parts, removed in prepared:
            target = stage / entry['file']
            with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
                for name, data in sorted(parts.items()):
                    info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0)); info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, data)
            entry['validationCopyOfSha256'] = digest
            entry['removedPrivateParts'] = removed
            entry['containsNativeMetadata'] = False
            entry['sha256'] = hashlib.sha256(target.read_bytes()).hexdigest()
        manifest['validationCopy'] = True
        manifest['scope'] = 'Synthetic public-only validation copies; original corpus remains untouched'
        (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2, allow_nan=False) + '\n')
        # Rename the new owned directory only; never replace any existing destination.
        if output.exists() or output.is_symlink(): raise ValueError('Output appeared during preparation')
        os.rename(stage, output)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.fixtures, args.output)
        print(f"Prepared {len(result['fixtures'])} new public-only synthetic validation copies")
        return 0
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, ET.ParseError) as error:
        parser.exit(2, f'Preparation failed: {error}\n')

if __name__ == '__main__': raise SystemExit(main())
