# StreamTranslate Project Context

## Product boundary

StreamTranslate is a macOS SwiftUI app for local Chinese-English meeting captions. Microphone mode listens to people near the Mac; System Audio mode captures audio playing on the Mac. Each utterance is classified as Chinese or English, transcribed locally, translated in the opposite direction, and shown in an always-on-top panel.

The current target is macOS only. `project.yml` is the XcodeGen source of truth.

## Runtime pipeline

1. `AudioCaptureService` produces 16 kHz mono `Float` samples from AVAudioEngine or ScreenCaptureKit.
2. `SpeechSegmenter` uses an adaptive energy floor, continuous-speech qualification, pre-roll, model-specific preview cadence, and short-pause finalization.
3. `WhisperTranscriptionService` runs the selected multilingual Whisper model through WhisperKit/Core ML. Automatic mode locks the language after two matching partial detections.
4. `CaptionTextStabilizer` commits only the prefix that agrees across consecutive hypotheses and keeps a small editable live edge. Finalization replaces the live text once with Whisper's exact final result for transcript accuracy.
5. `CaptionViewModel` translates throttled stable prefixes without clearing the previous translation, then translates every exact final result.
6. `FloatingCaptionView` displays bright confirmed text, a dim editable suffix, and transcript history without scrolling on every text revision.

English input maps to English original + Chinese translation. Chinese input maps to Chinese original + English translation.

## Components

- `CaptionViewModel`: main-actor state, model lifecycle, capture control, recognition/translation pipeline, caption history
- `AudioCaptureService`: microphone and system-audio capture, 16 kHz conversion
- `SpeechSegmenter`: room-noise gate and utterance boundaries
- `CaptionTextStabilizer`: monotonic partial text, editable suffix, exact final text, partial-translation cadence
- `WhisperTranscriptionService`: WhisperKit download, Core ML load, transcription, language result mapping
- `TranslationService`: Apple `TranslationSession` storage and requests for both directions
- `FloatingPanel`: resizable transparent `NSPanel`
- `FloatingCaptionView`: current bilingual caption and history scroll

## Model and latency choices

- Default ASR model: `openai_whisper-small` (**速度优先**)
- The optional `openai_whisper-large-v3-v20240930_626MB` model is exposed as **准确度优先**. It measured 1.14–4.11 seconds per pass on the target M4/16 GB Mac, so it is never selected automatically.
- Whisper Small measured 0.27–0.44 seconds per pass on the same Mac.
- Whisper Small submits the first and later source previews every 0.75 seconds. Large-v3 Turbo uses a one-second first preview and a 1.5-second later interval; the event queue coalesces stale work if inference is slower than the configured cadence.
- A two-snapshot agreement rule commits the stable prefix while keeping two English words or four Chinese characters editable.
- Partial translation is requested for the first stable prefix and then after about five English words or ten Chinese characters of growth. The previous translation remains visible while a replacement is prepared.
- Normal final decoding skips unused timestamps and allows one temperature fallback. Rolling-context decoding enables timestamps only when it needs them to isolate the current utterance.
- Small can make more recognition errors than Large v3. Keep the model choice manual and preserve Small as the default.

## Persistence and local files

- User settings: `UserDefaults`
- App log: `~/Library/Logs/StreamTranslate.log`, reset at launch
- Detailed WAV and JSONL session evidence: `~/Library/Logs/StreamTranslate/Sessions/`, only when the user enables Diagnostics
- Whisper model: `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`
- Core ML cache: `~/Library/Caches/com.jiaotangxq.StreamTranslate/`

## Verification

Run all tests with:

```bash
xcodebuild test \
  -project StreamTranslate.xcodeproj \
  -scheme StreamTranslate \
  -destination 'platform=macOS'
```

The current suite has 178 tests. `CaptionTextStabilizerTests` covers monotonic confirmation, rewrite alignment, Chinese holdback, and translation throttling. `SpeechSegmenterTests` covers steady room noise, speech above the learned noise floor, source-preview cadence, pause finalization, and maximum utterance duration.

For live automation, `touch /tmp/tc-toggle` starts or stops recording. Inspect `~/Library/Logs/StreamTranslate.log` for `Partial`, `Completed`, and `Translated` entries. Enable Diagnostics before capture when WAV/JSONL evidence is required.

## Constraints and pitfalls

- Keep audio segmentation independent from inference so a model pass cannot postpone pause detection. Re-benchmark if a pass approaches the later-preview interval.
- Do not expose raw Whisper partials as confirmed text. All live hypotheses must pass through `CaptionTextStabilizer`, while transcript history must retain the exact final recognition.
- Do not clear an existing translation while preparing its replacement; this changes layout height and makes the reading surface flash.
- Do not translate only final results; long utterances need throttled stable-prefix translation before the pause.
- Keep detailed capture diagnostics off by default. Continuous WAV and per-buffer JSONL recording can create gigabytes of data in a long meeting.
- Microphone audio includes every audible source. Energy gating suppresses steady noise but cannot separate overlapping speakers or a television from a nearby participant.
- App builds copied with a different temporary signature can trigger a new microphone permission request. Use a consistent local build identity when deploying repeatedly.
- Translation requires both Chinese→English and English→Chinese sessions to be ready before capture begins.
