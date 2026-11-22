# 1.10.0 / build 29: streaming automatic language, merged mind map

## What was found

Evidence came from `~/Library/Logs/StreamTranslate.log` (one 13-day run of a
build launched on 2026-11-08) and the saved preferences. That run used
`recognitionLanguageMode = automatic` with `openai_whisper-small`, so every
caption went through the Whisper snapshot path, not Apple streaming.

- Partial captions changed every 0.91 s at the median, 1.70 s at p90 and up to
  3.2 s (2,084 intervals). Each preview re-transcribed the whole utterance from
  its start, and the speed profile cut continuous speech every 8 s, often
  mid-sentence. Translation was not the bottleneck: final translations arrived
  97 ms after the final source at the median (p99 0.49 s, 521 captions).
- Language flipped per segment (en/zh/ja guesses), and music or applause
  produced Whisper subtitle-credit hallucinations (bracketed `(字幕…)` credit
  lines).
- Gaps of 20–44 s without any partial occurred in what the surrounding
  captions suggest was continuous speech (one sentence resumed mid-phrase
  after 44 s), one ending in a hallucinated final. A throwaway probe on the production Whisper
  service measured 8 s of pink noise: the ten preview passes took 13.15 s, more
  than real time, because decoding looped toward the 224-token limit; the
  final pass then forced English and Chinese retries that returned
  hallucinated credits. The pipeline is serial, so new speech waited behind
  that work. This is a confirmed cost on synthetic noise, not a reproduction of
  the user's exact gap.
- The process recording that log had been launched from a bundle that the
  installer later moved to `build/app-backups/`; the installed 1.9.1 was not the
  build that produced it.
- The optional Qwen review and Hy-MT links in Application Support point to
  files no longer on the external SSD, so both enhancements were unavailable.

## Changes

- Automatic language: `BilingualStreamingTranscriptionService` runs Apple
  en_US and zh_CN recognizers on the same stream; `BilingualRecognitionArbiter`
  selects the spoken language (see CONTEXT.md). One-time settings migration.
- Whisper (still selectable): no forced-language retries after a nil result,
  decode length bounded to 24 + 10 tokens per second of audio, subtitle-credit
  hallucination filter.
- Mind map: whole-topic revisions with stable IDs, merge-only `remove`,
  overview folding instead of loss, per-topic summary, session-length budgets,
  adaptive cadence, background updates with a cloud provider, per-batch commit.
- Diagnostics and rendering: persistent private log handle with rotation, no
  partial transcript logging, `PipelineHealthMonitor`, isolated live caption row.

## Verification

- `python3 Tools/run_portable_tests.py`: 340 test bodies, 0 failed assertions
  (baseline before the change: 346; the append-only forest tests were replaced
  by revision, cadence, batching, lifecycle and arbiter tests).
- Whisper noise probe after the change: the same ten previews took 4.28 s for
  8 s of audio; the music clip's forced Chinese retry returned nothing instead
  of a credit. Speech clips produced identical text with similar timing.
- Bilingual recognizer, real-time paced 50.5 s synthetic clip (English, 1.2 s
  gap, Mandarin, English, Mandarin without a gap; macOS TTS voices): switched
  en → zh → en → zh with no garbled cross-language text. Through
  `CaptionViewModel` and both Apple translation sessions, all eight captions
  committed in the right language with translations in the opposite direction.
- Cloud mind map (`Tools/ConversationSummaryProbe.swift`, configured DeepSeek
  provider, synthetic text): five stages took 1.7–3.0 s each; the release topic
  merged a later correction ("下周" → "推迟到月底") with cause and plan in one
  topic; filler added nothing. `--long` (14 unrelated topics, 7-topic budget):
  7 live topics plus an overview listing the 7 earliest, about 2 s per update.
  An earlier version that honored bare removals erased all topics in this test,
  which is why `remove` is now merge-only.
- Synthetic UI previews (`Tools/CaptionInteractionBenchmark.swift`) render the
  split and compact panes, topic summaries and the progress state.

## Not verified

- Real system or microphone audio with the bilingual recognizer, accented or
  code-switched speech, and long real sessions. TTS audio is cleaner than live
  content.
- The local summary model path with the new prompt and 6,144 context: the
  model is not installed on this Mac.
- Xcode build and the Swift Testing runner (Command Line Tools only here), the
  excluded UI/shared-log test files, VoiceOver and physical interaction.
- Whether ScreenCaptureKit stops audio callbacks during silence; the health
  monitor now logs it if it happens.
