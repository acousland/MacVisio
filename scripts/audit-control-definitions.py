#!/usr/bin/env python3
"""Inventory public Control rows and formula dependencies in installer libraries."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('report', type=Path)
args = parser.parse_args()
ns = '{http://schemas.microsoft.com/office/visio/2012/main}'
counts, functions, bad = Counter(), Counter(), []
for path in sorted(args.directory.iterdir()):
    if path.suffix.lower() not in {'.vssx', '.vstx'}:
        continue
    with zipfile.ZipFile(path) as package:
        for part in package.namelist():
            if not part.endswith('.xml') or not part.startswith(('visio/masters/master', 'visio/pages/page')):
                continue
            for section in ET.fromstring(package.read(part)).iter(ns + 'Section'):
                if section.get('N') != 'Control':
                    continue
                counts['sections'] += 1
                for row in section:
                    if row.tag != ns + 'Row':
                        continue
                    counts['rows'] += 1
                    name = row.get('N', '')
                    if '.' in name or '!' in name:
                        bad.append([path.name, part, name])
                    for cell in row:
                        if cell.tag != ns + 'Cell':
                            continue
                        counts['cells'] += 1
                        functions.update(f.upper() for f in re.findall(r'\b([A-Za-z_][A-Za-z_0-9]*)\s*\(', cell.get('F', '')))
report = {'rawControlSections': counts['sections'], 'rawControlRows': counts['rows'],
          'rawControlCells': counts['cells'], 'rejectedNames': bad,
          'formulaFunctionOccurrences': dict(functions.most_common()),
          'scope': 'Raw XML across installer pages and masters, including unused template masters; not a behavior audit',
          'windowsValidated': False}
args.report.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: v for k, v in report.items() if k != 'formulaFunctionOccurrences'}, indent=2))
