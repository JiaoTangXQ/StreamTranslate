#!/usr/bin/env python3
"""Small, deterministic local corpus; public recordings + authored TTS contrasts.

Downloads selected files only, never a complete speech dataset. References and
audio hashes are retained. This is a development set, not a broad accuracy claim.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

OUT = Path('build/refinement/corpus')
OUT.mkdir(parents=True, exist_ok=True)
manifest = []

def fetch(url):
    with urllib.request.urlopen(url, timeout=45) as response:
        return response.read()

def add(identifier, language, reference, source, raw_path, kind, speaker):
    wav = OUT / (identifier + '.wav')
    subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(raw_path),
                    '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', str(wav)], check=True)
    manifest.append(dict(id=identifier, language=language, reference=reference,
        source=source, audio=str(wav), kind=kind, speaker=speaker,
        sha256=hashlib.sha256(wav.read_bytes()).hexdigest()))
    print('prepared', identifier, flush=True)

root = 'https://huggingface.co/datasets/AISHELL/AISHELL-3'
revision = json.loads(fetch('https://huggingface.co/api/datasets/AISHELL/AISHELL-3'))['sha']
content = fetch(f'{root}/resolve/{revision}/test/content.txt').decode('utf-8')
references = {}
for line in content.splitlines():
    pieces = line.split()
    if len(pieces) > 2:
        references[Path(pieces[0]).stem] = ''.join(pieces[1::2])
for speaker in ['SSB0005', 'SSB0009', 'SSB0011', 'SSB0012']:
    files = json.loads(fetch(f'https://huggingface.co/api/datasets/AISHELL/AISHELL-3/tree/{revision}/test/wav/{speaker}'))
    path = sorted(f['path'] for f in files if f['path'].endswith('.wav'))[0]
    identifier = Path(path).stem
    raw = OUT / (identifier + '-source.wav')
    url = f'{root}/resolve/{revision}/{path}'
    if not raw.exists(): raw.write_bytes(fetch(url))
    add(identifier, 'zh', references[identifier], url, raw, 'human-read', speaker)

for offset in [0, 18, 50, 65]:
    api = ('https://datasets-server.huggingface.co/rows?dataset=hf-internal-testing%2Flibrispeech_asr_dummy'
           f'&config=clean&split=validation&offset={offset}&length=1')
    row = json.loads(fetch(api))['rows'][0]['row']
    identifier = 'libri-' + row['id']
    raw = OUT / (identifier + '.flac')
    if not raw.exists(): raw.write_bytes(fetch(row['audio'][0]['src']))
    add(identifier, 'en', row['text'], api, raw, 'human-read', str(row['speaker_id']))

contrasts = [
    ('zh-negation', 'zh', 'Tingting', '备份完成之前，不要重启服务器。如果错误率超过百分之一，就回滚，否则继续发布。'),
    ('zh-technical', 'zh', 'Tingting', '我们已经排除了内存泄漏，问题出在缓存淘汰策略。模型权重没有变大，但键值缓存还在增长。'),
    ('zh-number', 'zh', 'Tingting', '会议将在五分钟后开始，不是五点开始。预算是三点五万元，不是三十五万元。'),
    ('en-negation', 'en', 'Samantha', 'Do not restart the server until the backup has finished. If the error rate exceeds one percent, roll back; otherwise continue the rollout.'),
    ('en-technical', 'en', 'Daniel', 'We ruled out a memory leak. It was a cache eviction problem. The model weights stay the same size, but the key value cache keeps growing.'),
    ('en-number', 'en', 'Samantha', 'The meeting starts in five minutes, not at five o clock. Revenue fell by fifteen percent, not fifty percent.'),
]
for identifier, language, voice, reference in contrasts:
    raw = OUT / (identifier + '.aiff')
    if not raw.exists():
        subprocess.run(['say', '-v', voice, '-r', '175', '-o', str(raw), reference], check=True)
    add(identifier, language, reference, 'macOS say; authored development contrast', raw, 'synthetic', voice)

(OUT/'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print('manifest:', len(manifest), 'items')
