#!/usr/bin/env python3
"""Offline second-pass feasibility on the pinned, already installed MLX runtime."""
import argparse
import importlib.metadata
import json
import resource
import time
import mlx.core as mx
import soundfile as sf
from mlx_qwen3_asr import Session

p = argparse.ArgumentParser()
p.add_argument('--model', default='build/verification/qwen-q8-model')
p.add_argument('--manifest', default='build/refinement/corpus/manifest.json')
args = p.parse_args()
def emit(**data): print(json.dumps(data, ensure_ascii=False), flush=True)
start = time.perf_counter()
session = Session(model=args.model)
emit(event='loaded', seconds=time.perf_counter()-start, model=args.model,
     runtime=importlib.metadata.version('mlx-qwen3-asr'), mlx=importlib.metadata.version('mlx'),
     device=str(mx.default_device()))
for item in json.load(open(args.manifest)):
    audio, rate = sf.read(item['audio'], dtype='float32')
    assert rate == 16000 and audio.ndim == 1
    start = time.perf_counter()
    result = session.transcribe(audio, language='Chinese' if item['language']=='zh' else 'English',
                                max_new_tokens=256)
    emit(event='result', id=item['id'], reference=item['reference'], text=result.text,
         seconds=time.perf_counter()-start, audio_seconds=len(audio)/rate,
         process_peak_rss=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
         mlx_peak=mx.get_peak_memory())
