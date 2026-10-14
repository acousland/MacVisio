#!/usr/bin/env python3
"""Embed the pinned Sparkle framework with its symlinks and licenses intact."""
from pathlib import Path
import re
import shutil
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent.parent
artifact = root / '.build/artifacts/sparkle/Sparkle'
framework = next(artifact.glob('Sparkle.xcframework/macos-*/Sparkle.framework'))
target = app / 'Contents/Frameworks/Sparkle.framework'
if target.exists():
    shutil.rmtree(target)
shutil.copytree(framework, target, symlinks=True)
licenses = app / 'Contents/Resources/Licenses'
licenses.mkdir(parents=True, exist_ok=True)
shutil.copyfile(artifact / 'LICENSE', licenses / 'Sparkle-LICENSE')
binary = app / 'Contents/MacOS/MacVisio'
commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
for path in re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset', commands):
    if path.startswith('/') and ('.build/' in path or '/artifacts/' in path):
        subprocess.run(['install_name_tool', '-delete_rpath', path, str(binary)], check=True)
print('Embedded Sparkle 2.10.0')
