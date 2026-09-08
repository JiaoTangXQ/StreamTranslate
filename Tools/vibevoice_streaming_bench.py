#!/usr/bin/env python3
"""Local, wall-clock-paced comparison; never sends audio to a remote service.

Apple uses the production service through AppleStreamingReplay. VibeVoice uses
the checkpoint's native overlapping windows and one persistent KV cache per
recording. Model load and prompt prefill are separate from subtitle latency.
"""
import argparse
import gc
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import time
import unicodedata
import wave

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")


def emit(handle, value):
    handle.write(json.dumps(value, ensure_ascii=False) + "\n")
    handle.flush()


def units(text, language):
    text = unicodedata.normalize("NFKC", text).lower()
    if language == "zh":
        return [c for c in text if c.isalnum()]
    return re.findall(r"[a-z0-9]+", text)


def distance(reference, hypothesis):
    row = list(range(len(hypothesis) + 1))
    for i, a in enumerate(reference, 1):
        following = [i]
        for j, b in enumerate(hypothesis, 1):
            following.append(min(row[j] + 1, following[-1] + 1,
                                 row[j - 1] + (a != b)))
        row = following
    return row[-1]


def normalized_units(text, language):
    # Explicit, symmetric corpus formatting aliases, declared before model runs.
    # Keep raw scores too; this is NOT a general semantic correctness scorer.
    text = unicodedata.normalize("NFKC", text).lower()
    if language == "en":
        text = re.sub(r"\bmr\.", "mister", text)
        text = re.sub(r"\b20s\b", "twenties", text)
        text = text.replace("%", " percent")
        for digit, word in [("1", "one"), ("5", "five"), ("15", "fifteen"), ("50", "fifty")]:
            text = re.sub(r"\b" + digit + r"\b", word, text)
    else:
        text = re.sub(r"1\s*%", "百分之一", text)
        for number, word in [("3.5", "三点五"), ("35", "三十五"), ("5", "五")]:
            text = re.sub(r"(?<![\d.])" + re.escape(number) + r"(?![\d.])", word, text)
    return units(text, language)


def content_only(raw):
    # Official output is newline-delimited JSON with speaker/content fields.
    # Accept partial JSON in the streaming prefix without removing speech words.
    contents = re.findall(r'"content"\s*:\s*"((?:\\.|[^"\\])*)(?:"|$)', raw)
    if contents:
        return " ".join(json.loads('"' + s + '"') for s in contents).strip()
    return re.sub(r"(?im)^\s*(?:speaker\s*)?\d+\s*:\s*", "", raw).strip()


def score(case, summary):
    if case.get("reference") is None:
        return summary
    raw_reference = units(case["reference"], case["language"])
    raw_hypothesis = units(summary["text"], case["language"])
    reference = normalized_units(case["reference"], case["language"])
    hypothesis = normalized_units(summary["text"], case["language"])
    return {**summary, "reference": case["reference"], "kind": case["kind"],
            "raw_errors": distance(raw_reference, raw_hypothesis),
            "raw_reference_units": len(raw_reference),
            "errors": distance(reference, hypothesis), "reference_units": len(reference),
            "error_rate": distance(reference, hypothesis) / max(len(reference), 1)}


def duration(path):
    with wave.open(str(path), "rb") as wav:
        return wav.getnframes() / wav.getframerate()


def load_checked(path):
    """Strictly load all ASR weights, verifying the redundant tied output head."""
    import mlx.core as mx
    from mlx_audio.stt.models.vibevoice_asr import Model, ModelConfig
    from mlx_audio.utils import apply_quantization, load_config, load_weights
    config = load_config(path)
    model = Model(ModelConfig.from_dict(config))
    weights = model.sanitize(load_weights(path))
    head = "language_model.lm_head.weight"
    if head in weights and config["decoder_config"].get("tie_word_embeddings"):
        embedding = weights["language_model.model.embed_tokens.weight"]
        assert mx.array_equal(weights[head], embedding).item(), "Tied head differs from embedding"
        del weights[head]
    apply_quantization(model, config, weights, model.model_quant_predicate)
    model.load_weights(list(weights.items()), strict=True)
    mx.eval(model.parameters())
    model.eval()
    return Model.post_load_hook(model, path)


def run_apple(case, args):
    target = args.output / (case["id"] + ".jsonl")
    command = ["/usr/bin/time", "-l", str(args.apple_binary),
               case["audio"], case["language"], case["id"]]
    started = time.monotonic()
    with target.open("w") as output, target.with_suffix(".stderr").open("w") as error:
        # A timeout must stop both /usr/bin/time and its replay child, never the
        # user's running app. Give this benchmark its own process group.
        process = subprocess.Popen(command, stdout=output, stderr=error, start_new_session=True)
        try:
            code = process.wait(timeout=duration(case["audio"]) + 90)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
        if code:
            raise subprocess.CalledProcessError(code, command)
    events = [json.loads(line) for line in target.read_text().splitlines()]
    summary = next(e for e in reversed(events) if e.get("event") == "summary")
    memory = re.search(r"(\d+)\s+maximum resident set size", target.with_suffix(".stderr").read_text())
    if memory:
        summary["process_peak_rss_bytes"] = int(memory[1])
    summary["process_wall_seconds"] = time.monotonic() - started
    return score(case, summary)


def run_vibevoice(case, args, model, mx):
    import numpy as np
    import soundfile as sf
    from scipy.signal import resample_poly

    audio, sample_rate = sf.read(case["audio"], dtype="float32")
    assert sample_rate == 16000 and audio.ndim == 1
    audio = resample_poly(audio, 3, 2).astype(np.float32)
    sample_rate = 24000
    chunk = model.streaming_chunk_samples
    window = model.streaming_window_samples
    assert (chunk, window) == (70400, 83200), (chunk, window)
    seconds = len(audio) / sample_rate
    if seconds > 480:
        raise ValueError("Released checkpoint context is limited to 480 seconds")
    signal.alarm(90)
    prefill = time.monotonic()
    state = model.init_streaming_state()
    prefill_seconds = time.monotonic() - prefill
    started = time.monotonic()
    first = prefix = None
    text_chunks = []
    compute_seconds = 0
    max_backlog = 0
    max_chunk_compute = 0
    count = 0
    signal.alarm(int(seconds + 90))
    try:
        with (args.output / (case["id"] + ".jsonl")).open("w") as output:
            for offset in range(0, len(audio), chunk):
                end = min(offset + window, len(audio))
                available_at = end / sample_rate
                # No inference sees this window before the last sample arrives.
                time.sleep(max(0, started + available_at - time.monotonic()))
                data = np.pad(audio[offset:end], (0, window - end + offset))
                compute_start = time.monotonic()
                before_tokens = state["generation_tokens"]
                features = model.encode_speech(mx.array(data)[None, :])
                raw, state = model.streaming_generate_step(features, state,
                    max_new_tokens=256, temperature=0.0)
                elapsed = time.monotonic() - started
                compute = time.monotonic() - compute_start
                compute_seconds += compute
                max_chunk_compute = max(max_chunk_compute, compute)
                backlog = elapsed - available_at
                max_backlog = max(max_backlog, backlog)
                text_chunks.append(raw)
                text = content_only("".join(text_chunks))
                speech_units = units(text, case["language"])
                if speech_units and first is None:
                    first = elapsed
                if prefix is None and len(speech_units) >= (4 if case["language"] == "zh" else 3):
                    prefix = elapsed
                generated = state["generation_tokens"] - before_tokens
                count += 1
                emit(output, {"event": "chunk", "id": case["id"], "index": count,
                    "audio_available_seconds": available_at, "wall_seconds": elapsed,
                    "compute_seconds": compute, "backlog_seconds": backlog,
                    "raw": raw, "text_so_far": text, "generated_tokens": generated,
                    "mlx_active_bytes": mx.get_active_memory(), "mlx_peak_bytes": mx.get_peak_memory()})
                if generated >= 256:
                    raise RuntimeError("Token budget exhausted; refusing to score truncated result")
                if backlog > 20:
                    raise RuntimeError(f"Cannot keep up: {backlog:.1f}s processing backlog")
                mx.clear_cache()
            elapsed = time.monotonic() - started
            summary = score(case, {"event": "summary", "id": case["id"],
                "model": args.backend, "language": case["language"], "audio_seconds": seconds,
                "prefill_seconds": prefill_seconds, "first_seconds": first if first is not None else -1,
                "prefix_ready_seconds": prefix if prefix is not None else -1,
                "wall_seconds": elapsed, "end_lag_seconds": elapsed - seconds,
                "compute_seconds": compute_seconds, "compute_rtf": compute_seconds / seconds,
                "max_backlog_seconds": max_backlog, "max_chunk_compute_seconds": max_chunk_compute,
                "chunks": count, "mlx_peak_bytes": mx.get_peak_memory(),
                "process_peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                "text": content_only("".join(text_chunks)), "raw": "".join(text_chunks)})
            emit(output, summary)
        return summary
    finally:
        signal.alarm(0)
        del state
        gc.collect()
        mx.clear_cache()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", required=True, choices=["apple", "vibevoice-q4", "vibevoice-bf16"])
    parser.add_argument("--manifest", type=Path, default=Path("build/refinement/corpus/manifest.json"))
    parser.add_argument("--ids", nargs="*")
    parser.add_argument("--model-path", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--apple-binary", type=Path, default=Path("build/vibevoice-comparison-2026-09-08/AppleStreamingReplay"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    cases = json.loads(args.manifest.read_text())
    if args.ids:
        wanted = set(args.ids)
        cases = [case for case in cases if case["id"] in wanted]
        assert {case["id"] for case in cases} == wanted
    mx = model = None
    if args.backend != "apple":
        import mlx.core as mx
        mx.set_memory_limit(8 * 1024**3)
        mx.set_cache_limit(256 * 1024**2)
        signal.alarm(120)
        started = time.monotonic()
        model = load_checked(args.model_path)
        signal.alarm(0)
        print(json.dumps({"event": "loaded", "load_seconds": time.monotonic() - started,
                          "mlx_active_bytes": mx.get_active_memory()}), flush=True)
        assert model.is_streaming_model
    with (args.output / "results.jsonl").open("w") as results:
        for case in cases:
            print("Testing " + args.backend + " " + case["id"], flush=True)
            result = run_apple(case, args) if args.backend == "apple" else run_vibevoice(case, args, model, mx)
            emit(results, result)
            print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
