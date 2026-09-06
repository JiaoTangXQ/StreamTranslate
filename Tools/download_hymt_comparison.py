"""Fetch one official 7B Q4 candidate; validate against a pinned HF revision."""
import hashlib
import json
from pathlib import Path
import subprocess

revision = 'ab8472660ac61fac25f1af43fac2599d52a8a775'
expected = '9f96256500f3fc1ab4d64336b58f52a949a95ad7516b0c229476eef782f9f77b'
size = 4624648896
root = Path('/Volumes/PortableSSD/StreamTranslate-verification-20260905/Hy-MT2-7B')
root.mkdir(parents=True, exist_ok=True)
target = root / 'Hy-MT2-7B-Q4_K_M.gguf'
partial = root / (target.name + '.partial')
if not target.exists():
    subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--connect-timeout', '20',
                    '--continue-at', '-', '--output', str(partial),
                    'https://modelscope.cn/models/Tencent-Hunyuan/Hy-MT2-7B-GGUF/resolve/master/' + target.name], check=True)
    assert partial.stat().st_size == size
    check = partial
else:
    check = target
digest = hashlib.sha256()
with check.open('rb') as handle:
    for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b''):
        digest.update(chunk)
assert digest.hexdigest() == expected
if check == partial:
    partial.rename(target)
print(json.dumps({'model': str(target), 'sha256': expected, 'revision': revision, 'bytes': size}))
