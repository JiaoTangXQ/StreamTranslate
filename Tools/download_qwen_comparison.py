"""Fetch the pinned larger ASR candidate to the external verification disk."""
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

revision = '7278e1e70fe206f11671096ffdd38061171dd6e5'
destination = Path('/Volumes/PortableSSD/StreamTranslate-verification-20260905/Qwen3-ASR-1.7B')
clean = Path('build/refinement/qwen-1.7b-model')
destination.mkdir(parents=True, exist_ok=True)
clean.mkdir(parents=True, exist_ok=True)
api = f'https://huggingface.co/api/models/Qwen/Qwen3-ASR-1.7B/tree/{revision}?recursive=false'
with urllib.request.urlopen(api, timeout=30) as response:
    files = json.load(response)
for item in files:
    name = item['path']
    if name.startswith('.') or item.get('type') != 'file':
        continue
    target = destination / name
    if not target.exists():
        partial = destination / (name + '.partial')
        expected = item.get('lfs', {}).get('oid')
        url = f'https://huggingface.co/Qwen/Qwen3-ASR-1.7B/resolve/{revision}/{name}'
        # Official Qwen mirror is faster from this Mac. Never trust mutable
        # "master" alone: its bytes must match the pinned HF LFS SHA256 below.
        if expected and name.endswith('.safetensors'):
            url = f'https://modelscope.cn/models/Qwen/Qwen3-ASR-1.7B/resolve/master/{name}'
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--connect-timeout', '20',
            '--continue-at', '-', '--output', str(partial),
            url], check=True)
        assert partial.stat().st_size == item['size'], name
        if expected:
            digest = hashlib.sha256()
            with partial.open('rb') as handle:
                for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b''):
                    digest.update(chunk)
            assert digest.hexdigest() == expected, name
        partial.rename(target)
    assert target.stat().st_size == item['size'], name
    link = clean / name
    if not link.exists():
        link.symlink_to(target)
    print(json.dumps({'file': name, 'bytes': item['size'], 'revision': revision}), flush=True)
