#!/usr/bin/env python3
"""Summarize fixed-trace latency without conflating it with ASR accuracy."""
import json
from pathlib import Path
import statistics

root = Path('build/refinement')
def rows(path):
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

baseline = {x['id']:x for x in rows(root/'trace-baseline-summary.jsonl')}
candidate = {x['id']:x for x in rows(root/'trace-candidate-summary.jsonl')}
manifest = {x['id']:x for x in json.loads((root/'corpus/manifest.json').read_text())}
comparisons = []
for key in baseline.keys() & candidate.keys():
    old, new = baseline[key], candidate[key]
    comparisons.append(dict(id=key, kind=manifest[key]['kind'], language=manifest[key]['language'],
        baseline_first=old['first_translation'], candidate_first=new['first_translation'],
        change_seconds=new['first_translation']-old['first_translation'],
        same_final=old['captions']==new['captions'],
        baseline_changes=old['visible_translation_changes'], candidate_changes=new['visible_translation_changes']))
for row in sorted(comparisons, key=lambda x:x['id']): print(json.dumps(row, ensure_ascii=False))
if comparisons:
    print(json.dumps(dict(event='trace_summary', count=len(comparisons), expected=len(manifest),
        same_final=sum(x['same_final'] for x in comparisons),
        faster_by_over_50ms=sum(x['change_seconds'] < -.05 for x in comparisons),
        slower_by_over_50ms=sum(x['change_seconds'] > .05 for x in comparisons),
        baseline_median=statistics.median(x['baseline_first'] for x in comparisons),
        candidate_median=statistics.median(x['candidate_first'] for x in comparisons))))
for name in ['qwen-offline','whisper-small','whisper-turbo']:
    results = [x for x in rows(root/(name+'.jsonl')) if x['event']=='result']
    if results:
        print(json.dumps(dict(event='offline_summary', model=name, count=len(results),
            median_seconds=statistics.median(x['seconds'] for x in results),
            maximum_seconds=max(x['seconds'] for x in results),
            process_peak_rss=max(x['process_peak_rss'] for x in results))))
