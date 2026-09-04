# StreamTranslate Project Context

## Product boundary

StreamTranslate is a local macOS SwiftUI app for English↔Chinese live captions. Microphone mode captures nearby speech; System Audio mode captures audio playing on the Mac. The target deployment machine is Apple M4 with 16 GB unified memory and macOS 26.2.

The project is local-first. `project.yml` is the XcodeGen source of truth. Development versions are committed to the local Git repository; no remote push is part of the current work.

## Runtime pipelines

`AudioCaptureService` produces ordered 16 kHz mono `CapturedAudioChunk` values. Microphone input uses AVAudioEngine conversion. System Audio uses ScreenCaptureKit and interprets each CMSampleBuffer through its Core Media audio format and AudioBufferList. Both capture paths have a three-second callback watchdog and recreate their capture object after a stall.

Recognition has three explicit backends:

1. Fixed English defaults to `AppleStreamingTranscriptionService`. SpeechAnalyzer and SpeechTranscriber retain streaming state and receive each new chunk once. Volatile and final results retain their audio sample ranges. Apple model retention is `.whileInUse` so switching backends can release its model resources.
2. Optional fixed-English `NemotronStreamingTranscriptionService` loads the pinned NeMo-Speech.cpp 0.1.0 C ABI at runtime and runs `nemotron-speech-streaming-en-0.6b` Q8 on the Metal GPU. The app does not bundle its 667 MiB model. Assets are installed under Application Support by a checksum-verifying script. Built-in non-VAD endpointing uses 1,200 ms; 800 ms was rejected after it split a test utterance and corrupted its continuation.
3. Automatic or Chinese recognition uses `WhisperTranscriptionService` through WhisperKit/Core ML. `SpeechSegmenter` supplies pre-roll, adaptive energy gating, short-pause endpointing, preview cadence, and maximum utterance bounds. The event queue discards stale partial work.

All recognition paths feed `CaptionTextStabilizer`. A prefix becomes visibly frozen only after agreement from independent audio evidence; two English words or four Chinese characters remain editable. Draft translation may start earlier from the current hypothesis with the same tail removed. This improves first-Chinese latency without weakening the visible monotonic-prefix rule.

`PartialTranslationQueue` retains only the newest request. It waits 30 ms to merge an Apple subword callback burst and refuses requests for a segment after that segment becomes final. A final event cancels obsolete draft work.

Final source text is appended to history immediately with a stable UUID. `CaptionViewModel` groups pending final translations by direction, calls `TranslationSession.translate(batch:)` with that UUID as `clientIdentifier`, and updates only the matching caption. Old or out-of-order responses cannot replace a newer caption.

## Component ownership

- `CaptionViewModel`: main-actor lifecycle, capture coordination, backend choice, partial/final scheduling, caption history
- `AudioCaptureService`: AVAudioEngine/ScreenCaptureKit capture, normalization, callback health, recovery
- `AppleStreamingTranscriptionService`: continuous US-English SpeechAnalyzer input and volatile/final result mapping
- `NemotronStreamingTranscriptionService` and `NemotronBridge`: optional continuous English Metal inference and safe C ABI ownership
- `SpeechSegmenter`: Whisper-only energy/VAD-style boundary logic and rolling preview events
- `CaptionTextStabilizer`: frozen prefix, editable suffix, conservative translation prefix, translation cadence
- `WhisperTranscriptionService`: optional Whisper model download/load and snapshot transcription
- `TranslationService`: Apple Translation sessions, single requests, identified batch responses
- `MeetingSessionLogger`: WAV/capture/pipeline evidence, runtime physical footprint, bounded retention
- `FloatingCaptionView` and `FloatingPanel`: current bilingual caption, history, stable layout

## Model decisions on the target Mac

- Default English ASR: Apple SpeechTranscriber. A corrected 10.855-second real-time replay first produced text at 1.024 seconds and finalized 0.201 seconds after input ended. A 300.181-second replay finished in 300.397 seconds with 39.0 MB maximum RSS and no swaps. WER was 3.45% on the synthetic content (`first`→`1st`).
- Lowest-latency installed English option: Nemotron Streaming English 0.6B Q8 through NeMo-Speech.cpp 0.1.0. Two consecutive in-process real-time runs produced a three-word translation-ready prefix at 0.921 and 0.932 seconds, finalized 0.064 and 0.057 seconds after the input ended, and had 0% WER on the primary synthetic sentence. A five-voice set produced a 1.284-second average translation-ready prefix versus Apple's 1.737 seconds. Semantic-normalized aggregate WER tied Apple at 3.28%; this supports a latency improvement, not a general accuracy claim. Maximum observed process RSS was about 1.05 GB and cold model/Metal initialization was about seven seconds.
- Whisper Small remains the multilingual fallback and comparison backend. The 10.855-second sample took 0.505 seconds as a whole-utterance pass and had 0% WER, but its snapshot architecture cannot keep computation constant as a live utterance grows.
- Whisper Large-v3 Turbo remains manual. It is not loaded alongside Apple Speech by default.
- Moonshine Medium Streaming was rejected after local testing: 34.361-second model load, 4.567-second processing for 10.462 seconds of audio, and 10.34% WER with a repeated ending.
- Hy-MT2 1.8B Q4_K_M was rejected as the default final translator. With a 512-token context it used about 2.1 GB RSS and completed the local technical set in about 2.78 seconds. Apple Translation completed the same set in 0.473–0.677 seconds across two runs with about 18 MB process RSS. Quality was mixed across the examples, so the extra resident model was not justified.
- Nemotron is optional and selected on the target Mac after local comparison. Apple remains the project default because it requires no separate 667 MiB model and used far less memory. NVIDIA's 560 ms label is a model operating point, not the measured subtitle latency. The official 0.1.0 runtime uses ggml/Metal on Apple Silicon, not Core ML/ANE.
- Nemotron 3.5 ASR Streaming is not selected for this English-only product path. NVIDIA describes it as the multilingual extension and explicitly recommends the English-specific model for English-only transcription. A model swap needs target-audio evidence, not recency alone.

Detailed measurements live in `docs/benchmark-2026-09-04.md`.

## Metrics and replay

`StreamTranslateASRBench` replays any audio file through Apple streaming ASR and Whisper Small, supports real-time pacing, and reports first result, final lag, wall time, and WER when a reference is supplied.

`StreamTranslateTranslationBench` runs the installed Apple English→Chinese session sequentially or through the batch API. It accepts a one-sentence-per-line input file and prints every source/result pair plus first/p50/p95/max latency.

`StreamTranslateNemotronBench` replays audio through the installed optional backend, reports first raw and three-word translation-ready results, endpoint lag, WER, and can run repeated sessions against one loaded engine to test lifecycle handoff.

When Diagnostics is enabled, each app session writes:

- `source-audio.wav`: exact normalized source used by recognition
- `capture.jsonl`: sequence numbers, timestamps, source gaps, and recovery events
- `pipeline.jsonl`: backend, partial/final ranges, recognition/translation stages, errors, and five-second physical-footprint samples

`Tools/analyze_session.py` reports capture gaps, first/p50/p95 stage latency, operation duration, raw partial churn, deletions, peak memory, and errors.

## Verification commands

```bash
xcodegen generate
xcodebuild test \
  -project StreamTranslate.xcodeproj \
  -scheme StreamTranslate \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

The current suite has 193 tests.

```bash
xcodebuild -project StreamTranslate.xcodeproj \
  -scheme StreamTranslateASRBench \
  -configuration Release \
  -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO

xcodebuild -project StreamTranslate.xcodeproj \
  -scheme StreamTranslateTranslationBench \
  -configuration Release \
  -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO

xcodebuild -project StreamTranslate.xcodeproj \
  -scheme StreamTranslateNemotronBench \
  -configuration Release \
  -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO
```

For controlled live automation, `touch /tmp/tc-toggle` starts or stops recording. Full System Audio testing still requires the user-granted Screen Recording permission for the exact installed app identity.

## Constraints

- Do not resubmit previously processed audio to the Apple backend.
- Do not expose a raw partial as frozen text.
- Do not wait for translation before committing final source text.
- Do not identify captions by array position or completion order; use their UUID.
- Do not clear an existing translation while its replacement is in flight.
- Do not apply Whisper microphone sensitivity to Apple Speech; it does not use `SpeechSegmenter`.
- Do not keep Apple Speech and Whisper loaded together unless a measured optional review mode justifies the memory.
- Do not claim Nemotron uses the Neural Engine or improves general English accuracy; the integrated official runtime is Metal-based and target-audio accuracy evidence is still required.
- Do not add a 1.8B/7B translation model based only on public benchmarks. Compare representative user content against Apple Translation on the target Mac.
- Keep Diagnostics off in normal use because continuous WAV/JSONL output consumes disk.
- Use `scripts/install-local.sh` for repeated local deployment so privacy permissions remain attached to a consistent signing identity.
