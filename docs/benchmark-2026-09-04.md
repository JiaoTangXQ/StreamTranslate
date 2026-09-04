# Local ASR benchmark — Apple M4, 16 GB

Date: 2026-09-04  
Machine: Apple M4, 16 GB unified memory, macOS 26.2  
Primary input: 10.855 seconds of synthetic `Samantha` English speech, 16 kHz mono after conversion

Reference:

> Today we are testing continuous English speech recognition on an Apple silicon computer. The first subtitle should appear quickly, and the final text should remain accurate without moving backwards.

| Backend | First raw / translation-ready | End/final lag | Whole-audio inference | WER | Max RSS | Observed error |
|---|---:|---:|---:|---:|---:|---|
| Nemotron Streaming English 0.6B Q8 | 0.775 / 0.921 s realtime | 0.064 s | streaming | 0% | 1.05 GB | none |
| Apple SpeechTranscriber | 1.028 / 1.028 s realtime | 0.203 s | streaming | 3.45% | 39.0 MB in 5-minute replay | `first` normalized to `1st` |
| Whisper Small / WhisperKit | snapshot architecture | n/a | 0.505 s | 0% | 136.3 MB benchmark process | none |
| Moonshine Medium Streaming 0.1.5 | not measured realtime | 192 ms phrase-final | 4.567 s | 10.34% | not retained | repeated/rephrased the final clause |

Apple also finalized the first sentence during inserted silence and began the next result at a
new audio range. This supports using it as the continuous English backend.

### Corrected five-minute streaming replay

The same 10.855-second source was repeated 25 times with 1.2-second gaps. The benchmark's
real-time feeder uses absolute `ContinuousClock` deadlines; this avoids accumulating scheduler
drift over thousands of 100 ms chunks.

- Input duration: 300.181 s
- Wall time: 300.397 s
- First partial: 1.022 s
- End-to-final lag: 0.215 s
- Results: 1,104 volatile updates and 26 finalized ranges
- WER: 3.45%; all 25 copies were present, with `first` rendered as `1st`
- Maximum RSS: 39,043,072 bytes; peak physical footprint: 26,755,648 bytes; swaps: 0

An earlier run reported 16.170 seconds of end lag. That number was a benchmark defect: relative
100 ms sleeps accumulated scheduling drift. It is excluded from the model comparison.

Decision:

- Keep Apple SpeechTranscriber as the installation-free, low-memory default.
- Offer Nemotron as the installed lowest-latency English path on the target M4.
- Keep Whisper Small as the automatic/Chinese fallback and as the measured accuracy reference.
- Reject Moonshine Medium for the application on this evidence. Its phrase-final latency was low,
  but its local WER and compute time were worse on the same sample.
- Do not interpret Nemotron's published 560 ms label as end-to-end subtitle latency. The official
  Apple runtime is a ggml/Metal C API, not Core ML/ANE. Selection is based on the local measurements
  below and still needs validation against representative user audio.
- Do not switch to Nemotron 3.5 merely because it is newer. NVIDIA identifies it as the multilingual
  extension and recommends the English-specific model for English-only transcription.

### Nemotron local integration

The project loads the official NeMo-Speech.cpp 0.1.0 Metal C ABI dynamically and keeps the
667 MiB Q8 model outside the app bundle. The pinned runtime and model downloads are checksum
verified by `scripts/install-nemotron.sh`.

Two consecutive real-time sessions against one already-loaded engine produced:

| Session | Raw first text | Three-word translation-ready | End/final lag | WER |
|---|---:|---:|---:|---:|
| 1 | 0.775 s | 0.921 s | 0.064 s | 0% |
| 2 | 0.427 s | 0.932 s | 0.057 s | 0% |

The first raw update was only `Tod`, so the translation-ready figure is the useful comparison.
Cold model and Metal initialization was about seven seconds; warm model construction was
0.03–0.06 seconds. Maximum observed process RSS was 1,052,393,472 bytes with no swaps.

A separate five-voice macOS TTS set used Daniel (British), Karen (Australian), Moira (Irish),
Rishi (Indian), and Tessa (South African), totaling 61 reference words:

| Backend | Average raw first | Average translation-ready | Average end lag | Raw aggregate WER | Semantic-normalized WER |
|---|---:|---:|---:|---:|---:|
| Nemotron | 0.769 s | 1.284 s | 0.047 s | 3.28% | 3.28% |
| Apple | 1.019 s | 1.737 s | 0.098 s | 4.92% | 3.28% |

Apple wrote `three` as `3`; after treating those as equivalent, aggregate accuracy tied.
Both systems missed `Kubernetes` in the Rishi sample (`Humanities` for Nemotron and
`Cuban eats` for Apple). Nemotron also dropped `The` in the Tessa sample. The evidence shows
about 0.45 seconds lower average translation-ready latency; it does not establish a general
accuracy advantage.

An 800 ms endpoint threshold split the primary sentence and corrupted its continuation. The
integrated threshold is 1,200 ms. A three-repeat, 35-second replay with 1.2-second gaps produced
three complete final segments with no boundary loss.

Reproduce the retained Apple/Whisper comparison:

```sh
xcodegen generate
xcodebuild -project StreamTranslate.xcodeproj \
  -scheme StreamTranslateASRBench -configuration Release \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

StreamTranslateASRBench /path/to/audio.wav \
  --reference "verbatim reference text" --realtime

StreamTranslateASRBench /path/to/audio.wav \
  --reference "verbatim reference text" --realtime \
  --repeat 25 --gap-seconds 1.2 --apple-only
```

Reproduce the installed Nemotron path:

```sh
./scripts/install-nemotron.sh

xcodebuild -project StreamTranslate.xcodeproj \
  -scheme StreamTranslateNemotronBench -configuration Release \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

StreamTranslateNemotronBench /path/to/audio.wav \
  --reference "verbatim reference text" --realtime --sessions 2
```

The `--realtime` run paces Apple input at the source audio rate. Omit it for faster accuracy-only
replay. `--apple-only` and `--whisper-only` isolate one backend. Accuracy claims still require a
representative recording of the user's real content; this synthetic sample proves local execution,
long-run pacing, and timing behavior only.

## English→Chinese translation benchmark

The installed Apple Translation assets can be benchmarked without the app UI through
`TranslationSession(installedSource:target:)`. Eight short technical subtitle sentences
were translated on the same machine.

| Backend | First result | Per-sentence range | Eight-sentence completion | Process RSS | Model storage |
|---|---:|---:|---:|---:|---:|
| Apple Translation, sequential | 114–313 ms | 35–79 ms after first request | 473–677 ms total inference | 18 MB | system asset |
| Apple Translation, batch | 90–95 ms | n/a | 316–322 ms cumulative | not separately measured | system asset |
| Hy-MT2 1.8B Q4_K_M, persistent llama.cpp | 479 ms | 259–479 ms | about 2.78 s | 2.1 GB | 1.13 GB |

Selected quality observations:

- Apple rendered `capture watchdog` as `采集看门狗`; Hy-MT2 used the less specific
  `捕获监视器`.
- Hy-MT2 rendered `drain the queue` as `清空队列`; Apple used the less natural
  `耗尽队列`.
- Apple changed `the model` to `机型` in a unified-memory sentence. Hy-MT2 retained
  `模型` but weakened `compete for the same capacity` to `共享相同的内存容量`.
- Neither backend was consistently better over this small technical set.

Decision: keep Apple Translation for both drafts and finals. Across two runs the eight-sentence
sequential set completed about 4–6 times faster than Hy-MT2 and avoided a 2.1 GB resident
process. Hy-MT2's instruction and terminology features remain useful candidates only if a
larger user-content blind test shows a repeatable quality gain.

Reproduce the Apple side:

```sh
xcodebuild -project StreamTranslate.xcodeproj \
  -scheme StreamTranslateTranslationBench -configuration Release \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

StreamTranslateTranslationBench
StreamTranslateTranslationBench --batch
StreamTranslateTranslationBench --input /path/to/one-sentence-per-line.txt
```

Hy-MT2 was evaluated with the official `tencent/Hy-MT2-1.8B-GGUF` Q4_K_M file,
llama.cpp CPU/STQ execution (`-ngl 0`), a 512-token context, and the model card's
recommended sampling parameters. The default 262,144-token context was also tried and
was rejected immediately because it raised maximum RSS to about 4.5 GB for no subtitle
benefit.

## Sources used for model decisions

- [Apple SpeechAnalyzer documentation](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple WWDC25 SpeechAnalyzer session](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Apple Translation batch API](https://developer.apple.com/documentation/translation/translationsession/translate%28batch%3A%29)
- [NVIDIA Nemotron streaming English model card](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b)
- [NVIDIA NeMo-Speech.cpp runtime](https://github.com/NVIDIA/NeMo-Speech.cpp)
- [NVIDIA NeMo-Speech.cpp 0.1.0 release](https://github.com/NVIDIA/NeMo-Speech.cpp/releases/tag/v0.1.0)
- [NVIDIA Nemotron 3.5 streaming model card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)
- [Tencent Hy-MT2 1.8B GGUF model card](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF)
- [Moonshine native runtime and models](https://github.com/moonshine-ai/moonshine)
