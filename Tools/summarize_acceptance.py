#!/usr/bin/env python3
"""Summarize paired source changes and timing, without inventing a quality score."""
import argparse
import json
from pathlib import Path
import statistics

p = argparse.ArgumentParser()
p.add_argument('labels', nargs='+')
args = p.parse_args()
root = Path('build/refinement')
for label in args.labels:
    cases = []
    for file in sorted((root / label).glob('*.jsonl')):
        rows = [json.loads(line) for line in file.read_text().splitlines()]
        summary = next((r for r in rows if r['event'] == 'summary'), None)
        if not summary:
            raise RuntimeError(f'Incomplete replay: {file}')
        key = 'english' if summary['language'] == 'en' else 'chinese'
        raw = [r['text'] for r in rows if r['event'] == 'asr' and r['final']]
        revised = [r[key] for r in summary['captions']]
        prepared = next(r for r in rows if r['event'] == 'prepared')
        pipeline = [json.loads(line) for line in (Path(prepared['evidence']) / 'pipeline.jsonl').read_text().splitlines()]
        refinements = [r['durationMilliseconds'] / 1000 for r in pipeline if r['event'] == 'translation_refined']
        case = dict(label=label, id=file.stem, first_translation=summary['first_translation'],
            last_visible_lag=summary['last_visible_lag'], language=summary['language'],
            raw_source=raw, revised_source=revised, captions=summary['captions'],
            refinement_seconds=refinements, status=summary['status'])
        cases.append(case)
        print(json.dumps(dict(event='case', **case), ensure_ascii=False))
    for language in ['en', 'zh']:
        group = [r for r in cases if r['language'] == language]
        if not group:
            continue
        latencies = [x for r in group for x in r['refinement_seconds']]
        print(json.dumps(dict(event='aggregate', label=label, language=language, cases=len(group),
            median_first_translation=statistics.median(r['first_translation'] for r in group),
            median_last_visible_lag=statistics.median(r['last_visible_lag'] for r in group),
            median_refinement_seconds=statistics.median(latencies) if latencies else None,
            refinement_requests=len(latencies)), ensure_ascii=False))
