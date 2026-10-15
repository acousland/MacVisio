#!/usr/bin/env python3
"""Use a repository secret without placing signing material in the checkout."""
import os
from pathlib import Path
import subprocess
import tempfile
import sys

key = os.environ.get('SPARKLE_PRIVATE_KEY')
if not key:
    raise SystemExit('SPARKLE_PRIVATE_KEY repository secret is required.')
with tempfile.TemporaryDirectory(prefix='macvisio-signing-') as directory:
    path = Path(directory) / 'update-key'
    path.write_text(key)
    path.chmod(0o600)
    environment = dict(os.environ,SPARKLE_PRIVATE_KEY_FILE=str(path))
    if len(sys.argv) > 1 and sys.argv[1] == '--verify-only':
        command = ['python3', 'scripts/verify-release.py', *sys.argv[2:]]
    else:
        command = ['scripts/package-release.sh', *sys.argv[1:]]
    subprocess.run(command,env=environment,check=True)
