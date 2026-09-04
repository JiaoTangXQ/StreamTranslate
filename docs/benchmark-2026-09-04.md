# Local ASR benchmark — Apple M4, 16 GB

Date: 2026-09-04  
Machine: Apple M4, 16 GB unified memory, macOS 26.2  
Input: 10.462 seconds of synthetic `Samantha` English speech, 16 kHz mono after conversion

Reference:

> Today we are testing continuous English speech recognition on an Apple silicon computer. The first subtitle should appear quickly, and the final text should remain accurate without moving backwards.

| Backend | First partial | End/final lag | Whole-audio inference | WER | Observed error |
|---|---:|---:|---:|---:|---|
| Apple SpeechTranscriber | 1.084 s realtime | 0.680 s | 0.557 s unpaced | 3.45% | `first` normalized to `1st` |
| Whisper Small / WhisperKit | snapshot architecture | n/a | 0.465–0.519 s | 0% | none |
| Moonshine Medium Streaming 0.1.5 | not measured realtime | 192 ms phrase-final | 4.567 s | 10.34% | repeated/rephrased the final clause |

Apple also finalized the first sentence during a 1.8 second inserted silence and began the
next result at a new audio range. This supports using it as the continuous English backend.

Decision:

- Use Apple SpeechTranscriber for continuous English partials and endpoint finalization.
- Keep Whisper Small as the automatic/Chinese fallback and as the measured accuracy reference.
- Reject Moonshine Medium for the application on this evidence. Its phrase-final latency was low,
  but its local WER and compute time were worse on the same sample.
- Do not add Nemotron yet. Its official Apple runtime is a new ggml/Metal C API, and the published
  560 ms figure is model chunk context rather than measured end-to-end subtitle latency.

Reproduce the retained Apple/Whisper comparison:

```sh
xcodegen generate
xcodebuild -project StreamTranslate.xcodeproj \
  -scheme StreamTranslateASRBench -configuration Release \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

StreamTranslateASRBench /path/to/audio.wav \
  --reference "verbatim reference text" --realtime
```

The `--realtime` run paces Apple input at the source audio rate. Omit it for faster accuracy-only
replay. Accuracy claims still require a representative recording of the user's real content;
this synthetic sample proves the local execution path and timing behavior only.
