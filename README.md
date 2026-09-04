# StreamTranslate

StreamTranslate is a local macOS subtitle overlay for English↔Chinese meetings and media. Its default English path uses Apple's continuous on-device speech transcriber. An optional Nemotron Metal backend lowers English subtitle latency on the tested M4. Chinese and automatic-language modes remain available through WhisperKit.

## Current behavior

- English speech → streaming English transcript → simplified or Taiwan traditional Chinese
- Apple SpeechAnalyzer and optional Nemotron both process each audio chunk once and preserve recognizer state across long utterances
- A confirmed prefix stays fixed while only the dim live edge may change
- A conservative prefix starts draft translation before the whole sentence is final
- Final source text enters transcript history immediately; translation updates the same caption ID later
- Final translations use Apple Translation's identified batch API, so slow or out-of-order responses cannot overwrite another caption
- Stopping native streaming recognition closes the audio stream and waits for final words and queued translations before ending the session
- Whisper Small and Large-v3 Turbo remain selectable for Chinese, automatic language detection, and comparison
- Microphone and ScreenCaptureKit watchdogs rebuild stalled capture after about three seconds
- Audio, speech recognition, and translation stay on the Mac

Network access is needed only when macOS installs missing Apple language assets, WhisperKit downloads an optional Whisper model, or the explicit Nemotron installer downloads its pinned runtime and model.

## Requirements

- Apple Silicon Mac running macOS 26.0 or later
- Xcode 26.0 or later for source builds
- Microphone permission for nearby speech
- Screen Recording permission for System Audio mode
- English and Chinese Apple Translation language assets
- About 700 MB free space per optional Whisper model and compiled Core ML cache
- About 1 GB free disk space and about 1.05 GB process RSS for optional Nemotron

The tested machine is an Apple M4 with 16 GB unified memory on macOS 26.2. The default Apple Speech + Apple Translation path avoids keeping an additional 1.8B translation model resident.

## Build and run

```bash
brew install xcodegen
cd /path/to/StreamTranslate
xcodegen generate
xcodebuild build \
  -project StreamTranslate.xcodeproj \
  -scheme StreamTranslate \
  -destination 'platform=macOS' \
  -configuration Debug
```

Open the built app from Xcode or run:

```bash
open ~/Library/Developer/Xcode/DerivedData/StreamTranslate-*/Build/Products/Debug/StreamTranslate.app
```

For repeated local installation into `/Applications`, use the stable local signing identity so macOS does not treat each build as a new privacy principal:

```bash
./scripts/install-local.sh
```

## Recommended English→Chinese settings

1. Select **System Audio** for calls or media playing on the Mac; select **Microphone** for nearby speakers.
2. Keep recognition language on **English**.
3. On the tested M4, select **最低延迟（本机安装） / Nemotron Streaming English** after installing it. Keep **英译中流式 / Apple Speech English** when minimizing memory or avoiding an optional model installation.
4. Add names, product names, abbreviations, and technical terms to **Vocabulary**, separated by commas or new lines.
5. Start from the menu bar or press `Cmd+Shift+T`.

The microphone sensitivity picker applies only to the Whisper path. Apple Speech and Nemotron consume a continuous stream and perform their own phrase finalization.

Install the pinned official NeMo-Speech.cpp Metal runtime and English Q8 model:

```bash
./scripts/install-nemotron.sh
```

The installer supports Apple Silicon only, verifies both SHA-256 checksums, and stores assets under `~/Library/Application Support/StreamTranslate/Nemotron`. The runtime uses the M4 GPU through Metal; it does not use Core ML or the Neural Engine. The measured cold preload was about seven seconds. The app keeps Apple Speech as the installation-free default and reports a direct installation error if Nemotron assets are absent.

Use **Whisper Small** for automatic/Chinese recognition or an English accuracy comparison. Use **Large-v3 Turbo** only when its higher per-pass latency is acceptable. Selecting automatic or Chinese mode switches away from the English-only Apple backend.

## Data flow

```text
Microphone / System Audio → 16 kHz mono chunks
    ├─ fixed English + Nemotron model
    │    → NeMo-Speech.cpp Metal streaming state
    │    → partial/final English results
    ├─ fixed English + Apple model
    │    → SpeechAnalyzer streaming state
    │    → volatile/final English ranges
    └─ automatic or Chinese + Whisper model
         → adaptive endpointing
         → coalesced snapshot recognition
    → frozen prefix + editable suffix
    → latest-only draft translation
    → ID-matched batch final translation
    → floating subtitles + transcript history
```

For a first partial, translation may use all but the last two English words. This prefix is not displayed as frozen until independent audio evidence confirms it. A 30 ms debounce merges groups of subword hypotheses emitted in one callback burst.

## Verification

Run the unit and integration suite:

```bash
xcodegen generate
xcodebuild test \
  -project StreamTranslate.xcodeproj \
  -scheme StreamTranslate \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

The current suite contains 193 tests.

Build the replayable ASR benchmark:

```bash
xcodebuild -project StreamTranslate.xcodeproj \
  -scheme StreamTranslateASRBench \
  -configuration Release \
  -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO

StreamTranslateASRBench /path/to/audio.wav \
  --reference "verbatim English reference" --realtime

# Long-run Apple-only replay
StreamTranslateASRBench /path/to/audio.wav \
  --reference "verbatim English reference" --realtime \
  --repeat 25 --gap-seconds 1.2 --apple-only
```

Build and run the optional Nemotron benchmark after installation:

```bash
xcodebuild -project StreamTranslate.xcodeproj \
  -scheme StreamTranslateNemotronBench \
  -configuration Release \
  -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO

StreamTranslateNemotronBench /path/to/audio.wav \
  --reference "verbatim English reference" --realtime --sessions 2
```

Build and run the installed Apple Translation benchmark:

```bash
xcodebuild -project StreamTranslate.xcodeproj \
  -scheme StreamTranslateTranslationBench \
  -configuration Release \
  -destination 'platform=macOS' build \
  CODE_SIGNING_ALLOWED=NO

StreamTranslateTranslationBench
StreamTranslateTranslationBench --batch
StreamTranslateTranslationBench --input /path/to/one-english-sentence-per-line.txt
```

The retained local measurements and model decisions are in [`docs/benchmark-2026-09-04.md`](docs/benchmark-2026-09-04.md).

## Session diagnostics

Enable **Settings → Diagnostics** only for a measured session. The app writes `source-audio.wav`, `capture.jsonl`, and `pipeline.jsonl` under `~/Library/Logs/StreamTranslate/Sessions/` and automatically prunes old data.

Analyze one session with:

```bash
python3 Tools/analyze_session.py \
  ~/Library/Logs/StreamTranslate/Sessions/<session-directory>
```

The report includes capture gaps, first/p50/p95 capture-to-stage latency, operation time, partial rewrites, visible deletions, peak physical footprint, and pipeline errors.

## Project structure

```text
StreamTranslate/
├── Models/                 settings, captions, stability, ASR types
├── Bridge/                 optional NeMo-Speech.cpp C ABI adapter
├── Services/               capture, native streaming ASR, Whisper, translation
├── Utilities/              logging, diagnostics, shortcuts
├── ViewModels/             pipeline scheduling and UI state
├── Views/ and Windows/     subtitle and settings UI
Tools/                      ASR, translation, and session-analysis benchmarks
StreamTranslateTests/       193 tests
```

`project.yml` is the source of truth for the generated Xcode project.

## Known limits

- The Apple and Nemotron streaming backends are fixed to English. Chinese and automatic routing use Whisper.
- Nemotron is an optional Metal backend with about 1.05 GB measured process RSS versus 39 MB maximum RSS for the five-minute Apple benchmark. Semantic-normalized WER tied Apple on the five-voice synthetic set; the current evidence supports lower latency, not a general accuracy claim.
- Overlapping speakers are mixed into one audio stream.
- Vocabulary is recognition context, not a bilingual translation glossary.
- Apple Translation on macOS 26.2 has no public glossary or low-latency strategy API. The low-latency strategy first appears in macOS 26.4.
- A different ad-hoc app signature can require Screen Recording and Microphone permission again; use `scripts/install-local.sh` for repeated installations.
- Full System Audio validation requires the user-granted Screen Recording permission and cannot be completed by a test process after macOS denies that prompt.

## License

[MIT](LICENSE)
