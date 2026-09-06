#!/usr/bin/env python3
"""Summarize real draft requests versus legacy decisions on the same ASR trace."""
from pathlib import Path
import json
import statistics
import sys

for filename in sys.argv[1:]:
    trace = [json.loads(line) for line in Path(filename).read_text().splitlines()]
    prepared = next(r for r in trace if r['event'] == 'prepared')
    summary = next(r for r in trace if r['event'] == 'summary')
    evidence = Path(prepared['evidence']) / 'pipeline.jsonl'
    pipeline = [json.loads(line) for line in evidence.read_text().splitlines()]
    old = [r for r in trace if r['event'] == 'legacy_request']
    new = [r for r in pipeline if r['event'] == 'partial_translation_started']

    def gaps(rows, segment_key, time_key):
        last = {}
        values = []
        for row in rows:
            segment = row[segment_key]
            if segment in last:
                values.append(row[time_key] - last[segment])
            last[segment] = row[time_key]
        return dict(count=len(rows), within_segment_gaps=len(values),
                    median_gap_seconds=statistics.median(values) if values else None,
                    max_gap_seconds=max(values) if values else None)

    print(json.dumps(dict(file=filename,
                          legacy_decisions=gaps(old, 'start_sample', 'elapsed'),
                          new_actual_calls=gaps(new, 'segmentID', 'timestamp'),
                          caveat='Request interval, NOT per-prefix latency or an old-app end-to-end benchmark.',
                          replay=summary), ensure_ascii=False))
