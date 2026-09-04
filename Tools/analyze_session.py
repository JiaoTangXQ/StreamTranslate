#!/usr/bin/env python3
"""Summarize one StreamTranslate diagnostic session from its JSONL evidence."""

from __future__ import annotations

import argparse
import bisect
import json
import math
from collections import defaultdict
from pathlib import Path
from typing import Any


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    result: list[dict[str, Any]] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError as error:
            raise SystemExit(f"{path}:{number}: invalid JSON: {error}") from error
    return result


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1)
    return ordered[index]


def summary(values: list[float]) -> dict[str, float | int | None]:
    return {
        "count": len(values),
        "p50_ms": round(percentile(values, 0.50), 1) if values else None,
        "p95_ms": round(percentile(values, 0.95), 1) if values else None,
        "max_ms": round(max(values), 1) if values else None,
    }


def common_prefix_words(left: str, right: str) -> int:
    a = left.lower().split()
    b = right.lower().split()
    count = 0
    while count < len(a) and count < len(b) and a[count] == b[count]:
        count += 1
    return count


def analyze(session: Path) -> dict[str, Any]:
    capture = read_jsonl(session / "capture.jsonl")
    pipeline = read_jsonl(session / "pipeline.jsonl")
    chunks = [event for event in capture if event.get("event") == "audio_chunk"]
    chunk_ends = [int(event["endSample"]) for event in chunks]

    def capture_lag_ms(event: dict[str, Any]) -> float | None:
        end_sample = event.get("endSample")
        if end_sample is None or not chunks:
            return None
        index = bisect.bisect_left(chunk_ends, int(end_sample))
        if index >= len(chunks):
            index = len(chunks) - 1
        return max(0.0, (float(event["timestamp"]) - float(chunks[index]["timestamp"])) * 1000)

    stage_lags: dict[str, list[float]] = defaultdict(list)
    operation_times: dict[str, list[float]] = defaultdict(list)
    partials: dict[int, list[str]] = defaultdict(list)
    for event in pipeline:
        name = str(event.get("event", ""))
        lag = capture_lag_ms(event)
        if lag is not None:
            stage_lags[name].append(lag)
        duration = event.get("durationMilliseconds")
        if isinstance(duration, (int, float)):
            operation_times[name].append(float(duration))
        if name == "partial_recognized" and event.get("sourceText"):
            partials[int(event.get("segmentID", 0))].append(str(event["sourceText"]))

    rewrites = 0
    visible_deletions = 0
    for hypotheses in partials.values():
        for previous, current in zip(hypotheses, hypotheses[1:]):
            previous_words = previous.split()
            current_words = current.split()
            prefix = common_prefix_words(previous, current)
            if prefix < min(len(previous_words), len(current_words)):
                rewrites += 1
            if len(current_words) < len(previous_words):
                visible_deletions += len(previous_words) - len(current_words)

    runtime = [
        int(event["physicalFootprintBytes"])
        for event in pipeline
        if event.get("event") == "runtime_sample"
        and isinstance(event.get("physicalFootprintBytes"), int)
    ]
    source_gaps = [
        float(event["sourceGapSeconds"])
        for event in chunks
        if isinstance(event.get("sourceGapSeconds"), (int, float))
        and float(event["sourceGapSeconds"]) > 0.05
    ]
    backend = next(
        (
            event.get("detail")
            for event in pipeline
            if event.get("event") == "recognition_backend"
        ),
        None,
    )
    return {
        "session": str(session),
        "backend": backend,
        "audio": {
            "chunks": len(chunks),
            "seconds": round((chunk_ends[-1] if chunk_ends else 0) / 16_000, 3),
            "sequence_gaps": sum(int(event.get("sequenceGap", 0)) for event in chunks),
            "source_gaps_over_50ms": len(source_gaps),
            "largest_source_gap_ms": round(max(source_gaps) * 1000, 1) if source_gaps else 0,
        },
        "capture_to_stage": {name: summary(values) for name, values in sorted(stage_lags.items())},
        "operation_time": {
            name: summary(values) for name, values in sorted(operation_times.items())
        },
        "partial_churn": {
            "segments": len(partials),
            "rewrites": rewrites,
            "deleted_words": visible_deletions,
        },
        "memory": {
            "samples": len(runtime),
            "peak_mib": round(max(runtime) / 1_048_576, 1) if runtime else None,
        },
        "errors": [
            {"event": event.get("event"), "error": event.get("error")}
            for event in pipeline
            if event.get("error")
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("session", type=Path)
    parser.add_argument("--compact", action="store_true")
    arguments = parser.parse_args()
    report = analyze(arguments.session)
    print(json.dumps(report, ensure_ascii=False, indent=None if arguments.compact else 2))


if __name__ == "__main__":
    main()
