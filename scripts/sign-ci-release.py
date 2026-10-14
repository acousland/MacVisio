#!/usr/bin/env python3
"""Use a repository secret without placing signing material in the checkout."""
import os
from pathlib import Path
import subprocess
import tempfile

key = os.environ.get('SPARKLE_PRIVATE_KEY')
if not key:
    raise SystemExit('SPARKLE_PRIVATE_KEY repository secret is required.')
with tempfile.TemporaryDirectory(prefix='macvisio-signing-') as directory:
    path = Path(directory) / 'update-key'
    path.write_text(key)
    path.chmod(0o600)
    environment = dict(os.environ,SPARKLE_PRIVATE_KEY_FILE=str(path))
    subprocess.run(['scripts/package-release.sh'],env=environment,check=True)
