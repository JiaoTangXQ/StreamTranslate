#!/usr/bin/env python3
"""Convert a verified local streaming checkpoint; leave audio encoders BF16."""
import argparse
import json
from pathlib import Path
import signal

from vibevoice_streaming_bench import load_checked


def main():
    import mlx.core as mx
    from mlx_audio.convert import copy_model_files
    from mlx_audio.lm.convert import quantize_model, save_config, save_model

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.destination.exists():
        raise SystemExit("Refusing to overwrite an existing model directory")
    signal.alarm(180)
    mx.set_memory_limit(8 * 1024**3)
    mx.set_cache_limit(256 * 1024**2)
    model = load_checked(args.source)
    config = json.loads((args.source / "config.json").read_text())
    model, config = quantize_model(model, config, group_size=64, bits=4,
                                   quant_predicate=model.model_quant_predicate)
    config["model_type"] = "vibevoice_asr"
    args.destination.mkdir(parents=True)
    copy_model_files(args.source, args.destination)
    save_model(args.destination, model, donate_model=True)
    save_config(config, args.destination / "config.json")
    signal.alarm(0)
    print("Converted locally: LM affine Q4 group 64; audio encoders unchanged BF16", flush=True)


if __name__ == "__main__":
    main()
