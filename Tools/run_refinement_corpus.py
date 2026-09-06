#!/usr/bin/env python3
"""Sequential runs: never benchmark competing recognizers/translators together."""
import argparse
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('phase', choices=['recognize', 'trace'])
p.add_argument('--binary', required=True)
p.add_argument('--label', required=True)
p.add_argument('--ids', nargs='*')
p.add_argument('--accurate', action='store_true')
p.add_argument('--manifest', default='build/refinement/corpus/manifest.json')
p.add_argument('--review', action='store_true')
p.add_argument('--refine', action='store_true')
p.add_argument('--refine-model')
p.add_argument('--nemotron', action='store_true')
args = p.parse_args()
root = Path('build/refinement')
out = root / args.label
out.mkdir(parents=True, exist_ok=True)
manifest = json.loads(Path(args.manifest).read_text())
for item in manifest:
    if args.ids and item['id'] not in args.ids: continue
    source = item['audio'] if args.phase == 'recognize' else str(root/'recognition'/f"{item['id']}.jsonl")
    with (out/f"{item['id']}.jsonl").open('w') as stdout, (out/f"{item['id']}.stderr").open('w') as stderr:
        command = [args.binary, source, item['language']]
        if args.accurate: command += ['1', '--accurate']
        if args.review: command += ['--review']
        if args.refine: command += ['--refine']
        if args.refine_model: command += ['--refine-model', args.refine_model]
        if args.nemotron: command += ['--nemotron']
        result = subprocess.run(command, stdout=stdout,
                                stderr=stderr, timeout=150)
    if result.returncode:
        raise RuntimeError(f"{item['id']} failed: {result.returncode}")
    rows = [json.loads(line) for line in (out/f"{item['id']}.jsonl").read_text().splitlines()]
    summary = next(row for row in reversed(rows) if row['event'] == 'summary')
    print(json.dumps(dict(id=item['id'], **summary), ensure_ascii=False), flush=True)
