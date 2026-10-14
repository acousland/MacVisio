#!/usr/bin/env python3
"""Sign every nested Mach-O and bundle before sealing the outer app."""
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
identity = sys.argv[2]
arguments = ['codesign','--force','--preserve-metadata=entitlements','--sign',identity]
if identity != '-':
    arguments += ['--options','runtime','--timestamp']
magic = {bytes.fromhex(value) for value in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}
for path in sorted(app.rglob('*')):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open('rb') as file:
        is_binary = file.read(4) in magic
    if is_binary:
        subprocess.run([*arguments,str(path)],check=True)
bundles = [path for path in app.rglob('*') if path.is_dir() and not path.is_symlink() and path.suffix in {'.app','.xpc','.framework'}]
for path in sorted(bundles,key=lambda path:len(path.parts),reverse=True):
    subprocess.run([*arguments,str(path)],check=True)
subprocess.run([*arguments,str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
