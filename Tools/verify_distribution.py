#!/usr/bin/env python3
"""Audit the shipping bundle, including model bytes and relocatable Mach-O loads."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

EXPECTED = {
    'Qwen.gguf': 'd81d497b25508449b4bb511b343aee663405d28132d8dccfd5f29a1cceef77d3',
    'HyMT.gguf': 'dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699',
}

def audit(app):
    assert app.is_dir() and app.suffix == '.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['LSMinimumSystemVersion'] == '26.0'
    license_dir = app / 'Contents/Resources/Licenses'
    required_licenses = [
        'NOTICE.txt', 'StreamTranslate-MIT.txt', 'Apache-2.0.txt',
        'HyMT-Apache-2.0.txt', 'qwen3-asr-cpp.txt', 'ggml.txt',
        'llama-cpp-MIT.txt', 'Argmax-MIT.txt', 'Argmax-NOTICES.txt',
        'Swift-Argument-Parser-LICENSE.txt', 'BoringSSL-LICENSE.txt',
        'llama-vendor-json-hpp.txt', 'llama-vendor-cpp-httplib.txt',
        'llama-vendor-rotate-bits.txt', 'llama-vendor-sha256.txt',
        'llama-vendor-xxhash.txt', 'llama-vendor-big-integer.txt',
        'llama-vendor-nerdamer-prime.txt',
    ]
    for name in required_licenses:
        path = license_dir / name
        assert path.is_file() and path.stat().st_size > 0, f'Missing notice: {path}'
    models = []
    for name, expected in EXPECTED.items():
        path = app / 'Contents/Resources/Models' / name
        assert path.is_file() and not path.is_symlink(), path
        with path.open('rb') as handle:
            assert handle.read(4) == b'GGUF', path
            handle.seek(0)
            digest = hashlib.sha256()
            for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b''):
                digest.update(chunk)
            actual = digest.hexdigest()
        assert actual == expected, (path, actual)
        models.append({'file': name, 'bytes': path.stat().st_size, 'sha256': actual})
    binaries = []
    for path in app.rglob('*'):
        assert not path.is_symlink(), f'External/symlink dependency: {path}'
        assert path.suffix not in {'.wav', '.log', '.pem', '.p12', '.key', '.py'}, path
        if not path.is_file() or path.suffix == '.gguf':
            continue
        kind = subprocess.check_output(['file', '-b', str(path)], text=True)
        if 'Mach-O' not in kind:
            continue
        assert 'arm64' in kind, (path, kind)
        dependencies = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(' (compatibility')[0]
            assert dependency.startswith(('/System/Library/', '/usr/lib/', '@rpath/', '@loader_path/', '@executable_path/')), (path, dependency)
            if dependency.startswith(('@rpath/', '@loader_path/', '@executable_path/')):
                assert (path.parent / dependency.split('/', 1)[1]).is_file(), (path, dependency)
        loads = subprocess.check_output(['otool', '-l', str(path)], text=True)
        assert '/Users/' not in loads and '/Volumes/' not in loads, f'Build-machine load path: {path}'
        subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
        binaries.append(str(path.relative_to(app)))
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
            'models': models, 'native_binaries': binaries, 'required_notices': required_licenses,
            'signature_integrity': 'verified',
            'notarization': 'not checked; assess final DMG separately',
            'gatekeeper_trust': 'not established by this audit'}

if __name__ == '__main__':
    print(json.dumps(audit(Path(sys.argv[1])), ensure_ascii=False, indent=2))
