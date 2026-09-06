#!/usr/bin/env python3
"""Download a public community GGUF comparison, pinned to publisher LFS hash.

Not an official Google quantization. Does not accept gated license dialogs or
use account credentials. Only this artifact is downloaded to the external SSD.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import time

revision = '7c938465a870d8624bcfa98a8e4a3510053c19a8'
expected = '7f7357c14abd9da4eb200b38b05da502cd6e10d7e1d403fbc9f78c19f3209b72'
size = 2489909312
name = 'translategemma-4b-it-Q4_K_M.gguf'
root = Path('/Volumes/PortableSSD/StreamTranslate-verification-20260905/TranslateGemma-4B')
root.mkdir(parents=True, exist_ok=True)
destination, partial = root / name, root / (name + '.partial')
url = f'https://huggingface.co/bullerwins/translategemma-4b-it-GGUF/resolve/{revision}/{name}?download=true'
start = time.monotonic()
if not destination.exists():
    subprocess.run(['curl', '--location', '--fail', '--retry', '4', '--retry-delay', '2',
        '--connect-timeout', '20', '--max-time', '1800', '--continue-at', '-',
        '--output', str(partial), url], check=True)
    candidate = partial
else:
    candidate = destination
digest = hashlib.sha256()
with candidate.open('rb') as stream:
    for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
        digest.update(block)
if candidate.stat().st_size != size or digest.hexdigest() != expected:
    raise RuntimeError('Size or SHA256 mismatch; comparison artifact not accepted')
if candidate == partial:
    partial.rename(destination)
print(json.dumps(dict(path=str(destination), size=size, sha256=expected, revision=revision,
    publisher='bullerwins', base_model='google/translategemma-4b-it', seconds=time.monotonic()-start)), flush=True)
