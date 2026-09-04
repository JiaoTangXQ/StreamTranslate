# StreamTranslate

StreamTranslate is a local macOS subtitle overlay for Chinese-English meetings. It listens through the microphone or captures audio playing on the Mac, detects whether each utterance is Chinese or English, and displays the original text together with its translation.

## What it does

- English speech → English transcript + Chinese translation
- Chinese speech → Chinese transcript + English translation
- Incremental bilingual captions while a person is still speaking
- Stable-prefix captions that keep confirmed words fixed while dimming the editable live edge
- Selectable on-device Whisper Small or Large-v3 Turbo recognition through WhisperKit/Core ML
- On-device translation through Apple Translation
- Microphone mode for nearby participants
- System Audio mode for calls and media playing on this Mac
- Floating always-on-top subtitle panel and full transcript history
- Resizable subtitle panel with saved width and height
- Automatic, far-field, and nearby speech-detection sensitivity modes
- `Cmd+Shift+T` global start/stop shortcut

Audio and transcript text are processed locally. Network access is used when WhisperKit downloads the speech model on first use and when macOS needs a missing Apple language pack.

## Requirements

- macOS 26.0 or later
- Apple Silicon Mac
- Xcode 26.0 or later for source builds
- Microphone permission for nearby speech
- Screen Recording permission for System Audio mode
- At least 800 MB of free disk space for the default model, or 2 GB when keeping both models and their compiled Core ML caches

## Build

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

For repeated local installation into `/Applications`, use the stable-signing
installer. The first run creates a local code-signing identity and may request
the Mac login password. Later builds keep the same macOS privacy identity, so
reinstalling does not reset microphone and screen-recording permissions.

```bash
./scripts/install-local.sh
```

On first launch, allow the requested permission and wait for `openai_whisper-small` to download and compile. On the tested Mac, the model occupies about 465 MB and the compiled Core ML cache about 212 MB. Selecting **准确度优先** loads the approximately 626 MB Large-v3 Turbo model; selecting **速度优先** returns to Whisper Small.

## Tests

```bash
xcodebuild test \
  -project StreamTranslate.xcodeproj \
  -scheme StreamTranslate \
  -destination 'platform=macOS'
```

The current suite contains 178 tests.

## Usage

1. Launch StreamTranslate and wait until the model is ready.
2. Leave **Microphone** selected to caption people near the Mac. Select **System Audio** for sound playing on the Mac.
3. Leave **Sensitivity** on **Automatic** for normal use. Select **Far (2–3 m)** when quiet speakers are being missed; it can also react to more room noise.
4. Add project names, people, and technical terms to **Vocabulary** when a meeting uses specialized wording.
5. Leave the ASR model on **速度优先** for lower latency, or select **准确度优先** for Large-v3 Turbo. Stop recording before switching models.
6. Start recording from the menu bar or press `Cmd+Shift+T`.
7. Speak Chinese or English. While you are speaking, confirmed text stays bright and fixed; the dim live edge may change as more audio arrives. At the pause, the exact final recognition may make one last correction. Existing translation remains visible until its replacement is ready.
8. Drag the floating panel background to move it, or drag an edge or corner to resize it. The new width and height are saved automatically.

The sensitivity setting controls whether quiet audio is submitted for recognition. It cannot restore speech detail lost to distance, echo, or competing noise. The microphone cannot isolate one participant from other audible sound; loud speakers, television audio, room echo, and overlapping voices can reduce accuracy.

## Data flow

```text
Microphone → AVAudioEngine → 16 kHz mono audio
    or
System Audio → ScreenCaptureKit → 16 kHz audio
    → adaptive speech segmentation
    → selected Whisper model language detection + transcription
    → stable confirmed prefix + editable live edge
    → Apple Translation in the detected direction
    → floating bilingual subtitles + transcript history
```

The segmenter ignores steady room noise and finalizes an utterance after a short pause. In **速度优先** mode it submits source-language previews every 0.75 seconds so the original text stays close to live speech. The slower **准确度优先** model uses one second for the first preview and 1.5 seconds thereafter to avoid inference backlog. Automatic language mode locks an utterance to Chinese or English after two matching detections. Partial translation runs independently and only after the confirmed prefix grows enough to read, instead of retranslating every raw hypothesis. The transcript always stores Whisper's exact final result rather than a stability-layer reconstruction.

## Project structure

```text
StreamTranslate/
├── Models/
│   ├── CaptionEntry.swift
│   ├── CaptionSettings.swift
│   ├── SpokenLanguage.swift
│   └── TranscriptionTypes.swift
├── Services/
│   ├── AudioCaptureService.swift
│   ├── SpeechSegmenter.swift
│   ├── TranslationService.swift
│   └── WhisperTranscriptionService.swift
├── ViewModels/CaptionViewModel.swift
├── Views/
├── Utilities/
├── Windows/
└── StreamTranslateApp.swift
```

`project.yml` is the source of truth for the Xcode project. Run `xcodegen generate` after changing targets, dependencies, or file membership.

## Troubleshooting

- **No microphone text:** enable StreamTranslate under System Settings → Privacy & Security → Microphone, then relaunch it.
- **No System Audio text:** enable Screen Recording permission and relaunch the app.
- **Model download fails:** verify the Mac can reach Hugging Face, then use Retry in the model window.
- **Wrong language or invented text:** reduce speaker volume/echo and move the Mac closer to the participant. The app is intended for Chinese and English only.
- **Logs:** inspect `~/Library/Logs/StreamTranslate.log`. The file is reset at launch.
- **Detailed capture evidence:** enable **Settings → Diagnostics** temporarily to save source WAV and JSONL pipeline events under `~/Library/Logs/StreamTranslate/Sessions/`. Leave it off for normal meetings because long sessions can use substantial disk space.

## Known limitations

- Automatic routing is limited to Chinese and English.
- Simultaneous speakers are mixed into one audio stream.
- **速度优先** uses Whisper Small and favors latency; **准确度优先** uses Large-v3 Turbo and can take longer per recognition pass.
- The first model launch is slower because Core ML compiles and caches model programs.

## License

[MIT](LICENSE)
