#!/usr/bin/env python3
"""Sequential decoding/prompt contrasts using identical local numeric sources."""
from pathlib import Path
import subprocess
import sys

root = Path('build/refinement')
for size in ['7B', '1.8B']:
    model = f'/Volumes/PortableSSD/StreamTranslate-verification-20260905/Hy-MT2-{size}/Hy-MT2-{size}-Q4_K_M.gguf'
    for variant, flags in [
        ('default', []), ('hint', ['--precision-hint']),
        ('greedy', ['--temperature', '0']),
        ('greedy-hint', ['--temperature', '0', '--precision-hint']),
    ]:
        label = f'numeric-{size.lower()}-{variant}'
        with (root / (label + '.jsonl')).open('w') as output, (root / (label + '.stderr')).open('w') as errors:
            subprocess.run([sys.executable, 'Tools/refinement_hymt_bench.py', '--model', model,
                '--label', label, '--numeric-probes', '--glossary', *flags],
                stdout=output, stderr=errors, check=True, timeout=150)
        print('completed', label, flush=True)
