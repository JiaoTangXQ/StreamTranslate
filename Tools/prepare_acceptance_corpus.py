#!/usr/bin/env python3
"""Additional local acceptance contrasts, separate from prompt-development data.

Synthetic speech is not a substitute for noisy human conversation. Keep text,
voice and hashes so comparisons are repeatable and limitations remain explicit.
"""
import hashlib
import json
from pathlib import Path
import subprocess

out = Path('build/refinement/acceptance-corpus')
out.mkdir(parents=True, exist_ok=True)
contrasts = [
    ('en-condition', 'en', 'Samantha',
     'We have not approved the release yet. Restart only if both checks pass. If either check fails, keep the old version running.'),
    ('en-fraction', 'en', 'Daniel',
     'The patch reduced latency by a third, not to a third. The success rate rose from ninety five percent to ninety eight percent.'),
    ('en-attribution', 'en', 'Samantha',
     'Maria did not say the backup had failed. She said we had not verified it yet. I used to think the update was safe. I no longer do.'),
    ('zh-condition', 'zh', 'Tingting',
     '我们还没有批准发布。只有两项检查都通过，才能重启。只要有一项失败，就继续运行旧版本。'),
    ('zh-fraction', 'zh', 'Tingting',
     '这个补丁把延迟降低了三分之一，不是降低到三分之一。成功率从百分之九十五提高到百分之九十八。'),
    ('zh-attribution', 'zh', 'Tingting',
     '她并没有说备份失败了。她说的是，我们还没有验证备份。我以前觉得这次更新很安全，现在不这么认为了。'),
]
manifest = []
for identifier, language, voice, reference in contrasts:
    raw, wav = out / (identifier + '.aiff'), out / (identifier + '.wav')
    if not raw.exists():
        subprocess.run(['say', '-v', voice, '-r', '175', '-o', str(raw), reference], check=True)
    if not wav.exists():
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(raw),
                        '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', str(wav)], check=True)
    manifest.append(dict(id=identifier, language=language, speaker=voice, reference=reference,
        audio=str(wav), kind='synthetic-acceptance', source='macOS say; authored local contrast',
        sha256=hashlib.sha256(wav.read_bytes()).hexdigest()))
(out / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(dict(items=len(manifest), manifest=str(out / 'manifest.json'))))
