"""Paired source WER/CER within the same recognition replay, not a broad score."""
import argparse
import difflib
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('logs', nargs='+')
parser.add_argument('--id', default='en-technical')
parser.add_argument('--repeats', type=int, default=3)
args = parser.parse_args()
item = next(x for x in json.loads(Path('build/refinement/corpus/manifest.json').read_text()) if x['id'] == args.id)

def units(text):
    if item['language'] == 'zh':
        return [c for c in text.lower() if c.isalnum()]
    return re.findall(r'\w+', text.lower())

def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, value in enumerate(a):
        row = [i + 1]
        for j, target in enumerate(b):
            row.append(min(row[-1] + 1, previous[j + 1] + 1, previous[j] + (value != target)))
        previous = row
    return previous[-1]

reference = units(' '.join([item['reference']] * args.repeats))
key = 'chinese' if item['language'] == 'zh' else 'english'
for filename in args.logs:
    rows = [json.loads(line) for line in Path(filename).read_text().splitlines()]
    summary = next(x for x in rows if x['event'] == 'summary')
    raw = [x['text'] for x in rows if x['event'] == 'asr' and x['final']]
    revised = [x[key] for x in summary['captions']]
    raw_errors, revised_errors = distance(reference, units(' '.join(raw))), distance(reference, units(' '.join(revised)))
    changes = [{'before': a, 'after': b} for a, b in zip(raw, revised) if a != b]
    print(json.dumps(dict(log=filename, fixture=args.id, repeats=args.repeats,
        metric='CER' if key == 'chinese' else 'WER', reference_units=len(reference),
        raw_errors=raw_errors, revised_errors=revised_errors,
        raw_rate=raw_errors/len(reference), revised_rate=revised_errors/len(reference),
        raw_captions=len(raw), revised_captions=len(revised), changes=changes,
        first_translation=summary['first_translation'], final_visible_lag=summary['last_visible_lag']), ensure_ascii=False))
