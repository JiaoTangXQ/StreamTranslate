# StreamTranslate Project Context

## Product boundary

### Append-only local topic forest (1.7.3 / build 25)

`ConversationSummaryView` adds a default-collapsed right-edge tab over the existing
native dark caption panel. First expansion immediately starts independent topic
trees owned by `ConversationMindMap`, with kinds `discussion`, `advertisement` and
`uncertain`. Advertisements start as compact folded rows; other roots start expanded, with their
first branch expanded. Topics and branches toggle independently, and the outline
can be copied. Lazy topic views retain stable topic/branch/point identities as
new facts arrive. Titles and existing tree order are immutable. The drawer is at
most 380pt wide and supports a 300pt caption window. While expanded and unpaused,
completed original-source changes
schedule automatic updates after a two-second delay anchored to the first change;
further changes do not postpone that scheduled update. Busy changes replace one
latest pending request; no parallel inference or model instance is started. The
footer exposes pause, continue and retry. The drawer overlays
captions without changing their layout width. Expanding a panel shorter than 300pt
temporarily raises its minimum height from 144pt to 300pt; folding restores the
stored height preference. Preserve this overlay behavior and the incumbent UI.

Production summary input reads the full current capture session from
`CaptionHistoryStore`, never just the 100-row live cache. Only completed original
source text is summarized. `SummaryTranscript.batches` bounds each batch to 900
source characters and 12 numbered records, splitting oversized utterances. The
model receives only new/changed records and a labels-only routing index of at most
1,200 characters: T/kind/topic title and B/branch title, with no old point text or
old summary. Bounded source-derived keywords select relevant topics privately and
are not sent as factual material. There is never a request to rewrite the full graph. Initial processing still
covers the complete saved session. Production llama `response_format` constrains
one JSON object with an `additions` array of at most eight nodes. All fields are
required; topic values are enumerated from actual candidates and `new:1`–`new:8`,
and sources are bounded to this batch's record numbers. Software validates the
complete package before committing. Existing T/B IDs or new titles route additions
into the forest; old NDJSON remains parser/fixture compatibility only. Unrelated subjects
create roots and returning subjects can target existing roots. Kind mismatch
cannot place discussion under an advertisement: it uses the supplied title to
route to a new separate topic. Each explicit `new:` alias creates an independent
root, even with an existing title/kind; titles never cause global topic merging.
Repeated use of the same alias within its batch targets that batch's new root.
Topic references must match `Tn` or `new:n` with a positive integer; conflicting
titles for the same new topic alias reject the update and retain the completed
forest instead of attaching facts beneath a misleading parent. Topic/branch labels
reject newlines and `|` so they cannot forge routing entries. A branch must reference
an existing B ID or have a trimmed new name beginning with a Chinese character.
Only explicit existing T-ID routing can append to an old topic; normalized exact
facts in its selected branch merge source evidence while preserving point identity,
negative signs and word boundaries. For ordinary new-source batches, the bounded index
includes only up to six topics with lexical overlap; unrelated recent topics never
fill spare space. Chinese matching uses title/branch bigrams. At most 256 English
source keywords per topic are retained privately for routing English speech to
Chinese titles. Generic program/sponsorship terms are filtered. This is conservative
lexical retrieval: pronouns or paraphrases without overlap may create duplicate
roots, old topics can be omitted, and classification can fail.

Source corrections invalidate only points depending on changed captions and
reprocess the transitive closure of those points' source evidence. Their topic IDs
are traced from the previous completed map's point.sources and prioritized in the
candidate index even without lexical overlap, subject to the same six-topic and
1,200-character limits; this does not guarantee every linked topic is included. Unaffected
nodes retain their IDs and order. New point IDs are deterministic SHA-256 hashes
of topic/branch/source/text identity; complete-node previews publish only when the
outline changes. Streaming draft scanning handles escaped strings and previews
complete objects from the additions array over the old forest. Completed
graph, source keys and coverage metadata commit only after all
batches succeed; cancellation/failure keeps the previous completed graph. A limit
of 300 topics/6,000 facts pauses additions retaining that graph; full transcripts
remain in history. Results are approximate AI output, held in memory only, and reset on capture-session
change or clear. They are not summaries of older saved sessions.

`LocalSummaryService` uses a separate Qwen3-4B-Instruct-2507 Q4_K_M model and private Unix socket,
one request at a time, two utility CPU threads, and explicit CPU-only startup:
`--device none --no-kv-offload --no-op-offload --no-warmup`, in addition to `-ngl 0`.
Older `-ngl 0` alone did not explicitly disable KV/op offload. The startup budget
is now 90 seconds instead of 60, with elapsed loading time in the UI and distinct
launch-error, startup-exit-code and timeout messages. AppLogger records only process
metadata (PID, error/exit code and elapsed time), never transcript text. Continuous updates reuse
one worker; after 15 seconds idle it is released even while expanded. New source
after idle reloads the worker, but an unchanged source does not trigger inference.
SSE output previews complete draft nodes in the drawer; incomplete objects wait
for completion. Fold, pause, minimize, phone-only mode, clear, capture-session
change, quit and memory pressure cancel work and release the worker; generation
guards reject late results. Errors and memory warnings pause automatic updates
until the user retries, avoiding repeated restarts on every caption. Model
installation downloads weights, not
conversation data. `scripts/install-summary-local.sh` pins the LM Studio quantization
revision and full SHA-256 and copies an available llama.cpp runtime. App execution
has no Python dependency. Model weights stay out of git.

The local `SystemLanguageModel` probe reported `deviceNotEligible`; this feature
does not use Apple Foundation Models. The production prompt reads sources first
and defines the schema fields without concrete JSON examples. Empty/whitespace
branch names use neutral `要点`; malformed B references or new-topic tokens used as
branch names are rejected. Same-title isolation, source-local correction,
cancellation, stable draft IDs and retrieval have regression coverage. Final
sequential regression passed 360 tests in 10.843s, including 34 summary-focused
tests; seven AppLoggerTests and one companionInstalledTranslation fixture remain
excluded. One five-stage production SSE/apply replay passed:
readiness at 15.316s, ad/memory/housing/return-to-memory completion at
31.184/47.238/65.859/82.425s, then eight dense facts appended to original T2 by
134.922s. Ad and housing nodes, including source evidence, remained unchanged.
The probe exited 0; peak child RSS was 4,049,632 KiB (about 3.86 GiB). This is one
synthetic sample, not a classification, latency, memory or real-ASR-concurrency
guarantee. The actual template/tokenizer sample measured 1,515 prompt tokens plus
1,024 output within the 4,096 context for 900 source/1,200 index characters, not a
global worst-case bound. Evidence: `build/topic-mindmap/real-model.log`. Source-ID range checks
cannot prove semantic grounding; earlier replay exposed wrong routing and copied
facts attributed to unsupported sources. Keep those grounding assertions strict.
Nine summary captures passed review under `build/topic-mindmap/preview/`: the
first discussion branch/whole first fact is visible at 300pt minimum height, and
300/620pt-wide, 640pt-tall views show independent connected memory/housing trees.
Final independent review had no required fixes. Arbitrary podcasts, VoiceOver,
full-capacity long sessions and concurrent real ASR/translation load remain unverified.
Release build succeeded. `scripts/install-local.sh` installed 1.7.3/build 25,
confirmed by bundle metadata; the app is running and strict signature verification
passed with unchanged signing identity. Previous 1.7.2 is retained at
`/Applications/StreamTranslate.app.previous`.
Historical
1.7.0 synthetic-text inference
observed preparation/first-generation/update times of 13.4/16.9/16.1s and a separate
two-request sample peaked at about 3.7 GiB child RSS; these are not 1.7.1 measurements
or guarantees. Historical 1.7.1 sequential regression passed 339 tests, including 13 summary
tests, with seven AppLoggerTests and one installed-translation-assets test excluded.
That release build, strict signature verification and 1.7.1/build 23 installation
passed, with 1.7.0 retained for rollback.
Single-worker synthetic-text streaming observed preparation/first-visible-text/
completion at 24.39/33.86/48.32s from probe start, with 71 update callbacks; the
incremental request took 31.18s (79.50s cumulative). These are single samples.
An initial probe timed out while an installed-app summary worker was also running;
the isolated single-worker rerun succeeded and left no worker behind. The sample
still retained outdated unresolved wording, so semantic consistency is not assured.
Those 300pt states and 620pt completed previews passed, and independent review found
no mandatory code changes for 1.7.1. Historical 1.7.2 sequential regression passed
346 tests in 10.932s, including 20 summary-focused tests and five parser cases,
with the same eight shared-log/installed-asset exclusions. The exit-42 and orphan-
prose/star-bullet regressions were verified failing before the fixes and passing
afterward. Synthetic-text mind-map inference observed readiness/first-visible/
completion at 26.80/39.53/51.57s, 60 updates and four branches; incremental output
completed at 82.54s cumulative (30.97s request). Peak child RSS was 3,760,000 KiB
(about 3.59 GiB). The probe succeeded and left no model worker. These are single samples with
the app/ASR closed, not real ASR concurrency evidence. The updated outline fixed
old manual/undecided wording and retained the unresolved subtitle issue, but still
turned writing requirements into a branch and added unsupported correction wording.
300/620pt state previews passed and independent review found no required changes;
physical scrolling, copy and AX operation are not verified by screenshots. Xcode
Release build passed; 1.7.2/build 24 was installed and launched, strict signature
verification passed with unchanged signing identity, and 1.7.1 was retained at
`/Applications/StreamTranslate.app.previous` then. Older backups were archived by the
existing installer; the user log was backed up under ignored `build/diagnosis/`
before launch. Earlier startup samples, with installed ASR and
translation helpers active, were 42.83s with old flags, 21.66s with explicit CPU
settings and 15.82s with no warmup. They do not establish the screenshot failure's
exact cause or latency guarantees. Old SIGABRT
reports during termination cleanup do not by themselves identify that cause.
Native mouse/keyboard/VoiceOver, actual memory-pressure
behavior and real ASR concurrency remain unverified. Read
`docs/conversation-summary-1.7.0.md` for setup, checks and limitations.

### Bounded live captions and saved history (1.6.1 / build 21)

The live `CaptionViewModel.captionHistory` retains at most 100 completed entries;
the floating window shows 99 plus the streaming entry while speech is in progress.
Pending translation/review/refinement work retains its own caption until all users
release it, so eviction never drops a late correction from the saved record.
`CaptionHistoryStore` appends text-only journals under Application Support,
`StreamTranslate/TranscriptHistory`, on a serial utility queue. Same-UUID revisions
fold into one sentence on read. Sessions retain their original capture ID even
when an update arrives after a new recording starts. Production injects the store;
tests and synthetic fixtures do not use the user's archive.

The floating clock button and menu open `CaptionHistoryView`, which loads saved
sessions on demand and preserves the native dark UI. Only the selected session's
revision reloads its transcript, coalesced by 300 ms. One-click clear retires old
pipeline work, clears live captions, and deletes this history archive in queue
order; subsequent speech continues saving. Diagnostic logs remain separate.
Bad session indexes are reported without hiding valid sessions; an incomplete
last journal line is ignored. No historical diagnostics migration is performed.

Hover timestamps are not observable display state. Live text layout is eager but
bounded, with resize following only while the reader follows live output. Native
recognizer EOF/errors retire capture instead of leaving a running indicator;
graceful stop still drains the old generation's final result. This addresses
confirmed lifecycle gaps, but the user's actual ASR stall has not been reproduced.
Read `docs/long-session-history-1.6.1.md` for measurements and verification limits.

### Chinese dark settings (1.6.0 / build 20)

SettingsView uses four native sidebar pages and an explicit dark palette, with
Chinese user-facing copy except product/model/technical names. Preserve all
existing preference keys and capture/model-switch guards. Its synthetic size
preview must not use live captions. Settings remains blocked in private-only
mode and floats above the caption panel. Read docs/settings-redesign-1.6.0.md
and retain the minimum-window/native-navigation checks when changing layout.

### Bookmark / Home Screen recovery (1.5.1 / build 18)

Read `docs/bookmark-recovery-1.5.1.md` when changing remote pairing or lifecycle.
iOS Home Screen installation copies cookies, not localStorage. A valid relay cookie
can request the Mac to rewrap the room key with ephemeral P-256 ECDH, HKDF-SHA256,
and AES-GCM; the relay sees only the sealed answer. This relies on the server's
cookie authorization, not a second local-storage factor, and does not extend
the 12-hour room lifetime. Same-cookie SSE streams are bounded to three, not
mutually exclusive. Expired authorization exposes an in-place paste-link pairing
form; a stale QR bookmark can reuse valid room authorization without consuming
its ticket again. Keep the cookie-only launch and simultaneous-stream regressions.

### Personal cross-network relay (1.5.0 / build 17)

The user's Mac has a separately provisioned, default-off `RemoteCaptionRelay`.
An independent Node service on the user's Hangzhou ECS relays AES-256-GCM ciphertext
over public HTTPS/SSE; audio/models stay local. The IP has a publicly trusted short-lived
certificate and a twice-daily renewal timer, tested including the Nginx reload hook.
No domain purchase, VPN client, or manual certificate trust is needed for this deployment.
Read `docs/remote-companion-1.5.0.md` before deploying or changing security/lifecycle.

`CompanionCaptionPublisher` feeds the remote output when explicitly enabled. Initial
confirmation is required; network loss never reopens Mac caption windows. `RemoteCaptionRelay`
coalesces updates, encrypts snapshots/deltas, bounds remote history, sends heartbeat/status,
and retries without redirecting publisher credentials or downgrading TLS. It reads the
0600 per-user `RemoteRelay.json` provisioning file, never Alibaba credentials or a bundled
shared token. Distribution to another Mac does not implicitly grant access to this server.

The cloud reader reuses `WebAssets` through a narrowly scoped optional transport adapter.
Its decoder authenticates before rendering. Unlike LAN mode's preferences-only storage,
remote localStorage also holds connection metadata and a decryption key, never transcript
content. QR fragments are one-use/120-second invitations; browser authorization lasts at
most 12 hours. App/service restarts may require rescanning; no permanent-pairing claim.
The relay serves browser code and remains a trusted software-delivery endpoint even though
it receives only ciphertext. Do not describe this as secure against a compromised server
replacing the web client. The earlier LAN-only network/security boundary still applies to
`WebCaptionServer`; it was not exposed to the public Internet.

### Full-viewport web reader (1.4.2)

The phone web reader reserves no header/footer or control-bar space while live.
`#reader` owns scrolling and fills the dynamic viewport with safe-area padding.
Tap reveals an overlay Aa button for three seconds; an open settings panel stays
available until dismissed. Keyboard activation also exposes controls. Connection
failures remain visible, while connection/security/engine details during live
reading belong in settings; the Mac HTTP risk confirmation is unchanged.

Only an actual reader scroll after user input can enter history mode. A gesture
without displacement, settings scrolling, new text and viewport/font changes
must not set history mode. Returning within 48px of the bottom resumes following
and hides the return-to-live button, including manual scrolling. Content resize
re-anchors only in live-follow mode. Keep `Tools/test_web_reader.mjs` coverage of
real wheel/touch input and growing drafts; do not regress to unconditional
`touchmove`/`wheel` → pause. See `docs/web-reader-1.4.2-verification.md`.

### Window interaction regression (1.4.1)

The caption resize rim must be painted: transparent outer padding is excluded
from WindowServer mouse targeting even though `FloatingPanel.resizeEdges` would
accept those coordinates. The phone control window uses level floating + 1 and
full-screen auxiliary space behavior so an expanded caption panel cannot cover
it. Private-only entry guards remain unchanged. Validate with real mouse events
and window order, not only direct `sendEvent` or screenshots. The explicit
`--window-interaction-fixture` uses production window wiring with synthetic state
and isolated preferences; `Tools/WindowInteractionProbe.swift` drives only the
scoped installed/fixture app and restores geometry after drag tests. See
`docs/window-interaction-fix-2026-09-06.md`.

### Reading-first desktop controls (1.4.0, 2026-09-06)

`FloatingCaptionView` overlays `CaptionQuickControls` on pointer activity or tap,
with three-second inactivity hiding. Direct source choices, language, phone,
settings and minimize are available without the menu-bar detour. Options,
focused keyboard interaction and VoiceOver keep controls available; reduced
motion disables the fade. Idle/error states retain controls and feedback. The
overlay does not resize the transcript; wide/compact layouts share actions.

`CaptionViewModel.changeCaptureConfiguration` owns quick switching: await stop
work, update source/mode, prepare a compatible model if needed, then resume only
if previously recording and not cancelled. Settings-view model observers must
not race it. `captureStartGeneration` prevents an asynchronous start committing
after stop. Quick switches retain the companion conversation boundary; separate
starts still establish a new one. This is not gap-free audio: finalization,
models and permissions can take time. Remote phone recording stays out of scope.

`--reader-controls-preview NEW_DIRECTORY` renders synthetic off-screen
wide/narrow active/idle screenshots with isolated preferences, no audio/models
or listeners. Screenshots/core tests do not prove hardware switch timing,
keyboard accessibility or user acceptance. See
`docs/interaction-design-2026-09-06.md`.

### Personal-use web subtitle output (2026-09-06)

Mac 1.3.1 adds a separate, default-off `WebCaptionServer` beside the native
`CompanionServer`. `CompanionCaptionPublisher` feeds the same bounded current-capture
snapshot to whichever outputs are enabled. Both count for idle-system-sleep
prevention during recording, and neither disconnect path reopens Mac windows.
`phoneOnlyDisplay` also cancels pending web invitations and guards certificate
export/settings entry points. Browser acknowledgements plus an active stream
gate the web-connected UI state.

Mac 1.3.2 adds an explicitly consented `WebTransport.trustedLAN` quick-QR mode
on HTTP port 18444, preferring an active physical LAN IPv4. The Mac warns before
first enablement; `webQuickConnection` defaults false, separately persists that
choice, and is never set as a TLS-error fallback. Existing HTTPS is not silently
downgraded. HTTP is deliberately unencrypted: neither QR auth nor private-source
filtering protects against a network attacker. It is unsuitable for public Wi-Fi
or sensitive meetings and cannot request a browser screen wake lock. Safari may
show an HTTP warning; WeChat compatibility and real-device camera scanning remain
unverified. Quick mode uses a distinct non-Secure HttpOnly cookie with a 12-hour
limit and only in-memory server authorization; stopping/restarting/switching the
service removes that quick authorization. It never reads/deletes HTTPS credentials
during ordinary quick startup/revoke, or creates a certificate. An explicit full
certificate reset still removes HTTPS credentials. No cloud or domain is added.

The advanced web output remains local HTTPS/TLS 1.3 on port 18443 with a stable
system `.local` hostname, not raw native CompanionKit framing or Apple P2P.
WebKit/Chromium receive SSE snapshots/deltas. Slow sockets have one
latest-snapshot pending slot; browser sequence gaps reconnect. Authorization is
separate from the native phone: up to three browser cookies, HTTPS 90-day expiry,
one-time 120-second QR/8-digit invitations with a six-error cutoff. Matching
Host/Origin, strict bounded request parsing and private-source-IP admission are
mandatory. Text is rendered with textContent; only reading preferences enter
localStorage. No offline/transcript service worker is installed.

`WebIdentity` issues a one-year hostname-bound certificate under a dedicated
DNS-constrained root. Root signing key material is not persisted; only the leaf
key, public certificates and expiry are stored in Keychain. The public root
profile must be transferred from the user's Mac and manually trusted on iPhone;
never bypass TLS validation or silently install system roots. Renaming the Mac
or certificate expiry requires explicit reset and new phone setup. The explicit
`--export-web-profile NEW_PATH` command exports public setup material without
opening capture/model services or touching the running app's log. It refuses
existing destination files. See `docs/web-companion-use-zh.md` and verification
notes before claiming install/real-device readiness.

StreamTranslate is a local macOS SwiftUI app for English↔Chinese live captions. Microphone mode captures nearby speech; System Audio mode captures audio playing on the Mac. The target deployment machine is Apple M4 with 16 GB unified memory and macOS 26.2.

The project is local-first. `project.yml` is the XcodeGen source of truth. The 1.1 enhancement target is the same 16GB M4 on macOS 26.4. The user authorized GitHub publication under JiaoTangXQ; preserve the repository-local author/committer identity and scope credentials to that account when pushing.

## Runtime pipelines

`AudioCaptureService` produces ordered 16 kHz mono `CapturedAudioChunk` values. Microphone input uses AVAudioEngine conversion. System Audio uses ScreenCaptureKit and interprets each CMSampleBuffer through its Core Media audio format and AudioBufferList. Both capture paths have a three-second callback watchdog and recreate their capture object after a stall.

Recognition has three explicit backends:

1. Fixed English and Mandarin have distinct model profiles using `AppleStreamingTranscriptionService(language:)` (`en_US` / `zh_CN`). English remains the installation default. SpeechAnalyzer and SpeechTranscriber retain streaming state and receive each new chunk once. Volatile and final results retain their audio sample ranges. Apple model retention is `.whileInUse` so switching backends can release its model resources.
2. Optional fixed-English `NemotronStreamingTranscriptionService` loads the pinned NeMo-Speech.cpp 0.1.0 C ABI at runtime and runs `nemotron-speech-streaming-en-0.6b` Q8 on the Metal GPU. The app does not bundle its 667 MiB model. Assets are installed under Application Support by a checksum-verifying script. Built-in non-VAD endpointing uses 1,200 ms; 800 ms was rejected after it split a test utterance and corrupted its continuation.
3. Automatic or manually selected Whisper recognition uses `WhisperTranscriptionService` through WhisperKit/Core ML. `SpeechSegmenter` supplies pre-roll, adaptive energy gating, short-pause endpointing, preview cadence, and maximum utterance bounds. The event queue discards stale partial work. Explicit Whisper selections are preserved; incompatible native models follow language changes to the matching Apple profile or automatic Whisper fallback.

All recognition paths feed `CaptionTextStabilizer`. A prefix stabilizes only after agreement from independent audio evidence. A contradictory hypothesis is held rather than spliced onto the old prefix; two independent audio updates may correct the prefix. `TranslationDraftPlanner` uses lexical word boundaries, keeps two words at the tail, and may advance at a complete clause. A useful short initial phrase can settle after 250 ms. It avoids unfinished numbers/connectives; this is a latency/semantic-stability tradeoff, not a promise that every first fragment is useful.

`PartialTranslationQueue` retains only the newest request. It waits 30 ms to merge an Apple subword callback burst and refuses requests for a segment after that segment becomes final. A final event cancels obsolete draft work.

Final source text is appended to history immediately with a stable UUID. `FinalizedCaptionText` separates the frozen presentation from `recognizedText`; only the authoritative recognized text enters history/final translation. Native final ranges may trim silence and change the start sample: retiring a corresponding draft uses its complete audio range, not just exact start equality, and discards translation work for both starts. A late final must not reset another segment's live stabilizer, including a newer overlapping draft that extends beyond that final. `CaptionViewModel` groups pending final translations by direction, calls `TranslationSession.translate(batch:)` with that UUID as `clientIdentifier`, and updates only the matching caption. Old or out-of-order responses cannot replace a newer caption.

Draft scheduling retains phrase/growth triggers and adds a monotonic 600ms maximum wait since the previous request, with a real timer for silence/no further callback. The latest pending prefix replaces older text without postponing its deadline. Drafts require two English words or four Chinese characters; complete short utterances still translate at finalization. Segment/language changes, clear-history and finalization cancel pending work. Expected cancellation of obsolete drafts must not show an error banner. macOS 26.4 requests `.lowLatency`; earlier supported systems use the existing Translation configuration.

The installed 1.2.1 build 9 adds optional native Qwen source review and bidirectional Hy-MT final refinement. Both are separate killable local processes, installed under Application Support; no Python is required by the app. Models currently link to the external SSD because internal free space is low. Missing assets retain the original path. Qwen copies a bounded 40-second PCM ring, reviews 0.5–20-second finals with up to 2 seconds leading/0.5 seconds trailing context, and aligns the hypothesis back onto the original utterance before revising the same UUID. Pure-segment/contextual agreement and limited corroboration from an earlier raw Apple hypothesis guard revisions; numbers, negation and pronouns cannot use the single-view corroboration shortcut. These are not statistically independent recognizer votes.

Each reviewer has one running and at most two queued jobs. Generation and source-text guards reject late responses. Hy-MT waits for source review and keeps Apple drafts/finals visible while refining. It uses a private 0700 Unix socket directory, not a TCP listener. Up to two preceding same-capture captions (600 characters maximum) may derive a constrained software term mapping or resolve an explicit same-subject `used to … / no longer do` ellipsis. Raw background is not sent to the translation model: a five-minute test exposed background-copying regressions. Numeric/fraction integrity checks reject comparable value changes, not all semantic errors. Memory-pressure warning/critical events release optional models without interrupting the base capture/ASR/translation path, and do not reload them within the same capture. Hy-MT 7B triggered memory pressure about 115 seconds into a 320-second replay and is not the default for this machine's current load; 1.8B completed the same duration without observed pressure. TranslateGemma 4B is a comparison candidate, not an installed default.

Mandarin SpeechAnalyzer requests finalization only at a real 450ms audio pause, after at least four recognized semantic units and four seconds from the current speech onset, with no open paired conditional. Leading silence/noise without substantive ASR does not spend an utterance budget. The earlier 14-second forced commit was removed: aggregate result ranges produced mid-word/conditional cuts in actual system capture. Numeric draft-tail guards do NOT apply to real pause finalization, since a delayed percent token otherwise misses the pause and merges the next sentence. The recognizer is never restarted or fed duplicate audio. Unbroken long speech may delay refinement or exceed the source-review window; fast drafts still continue. `historyRevision` makes final corrections follow the bottom while respecting manual scrolling.

## Component ownership

- `CaptionViewModel`: main-actor lifecycle, capture coordination, backend choice, partial/final scheduling, caption history
- `AudioCaptureService`: AVAudioEngine/ScreenCaptureKit capture, normalization, callback health, recovery
- `AppleStreamingTranscriptionService`: fixed English/Mandarin SpeechAnalyzer input, asset preparation, and volatile/final mapping
- `NemotronStreamingTranscriptionService` and `NemotronBridge`: optional continuous English Metal inference and safe C ABI ownership
- `SpeechSegmenter`: Whisper-only energy/VAD-style boundary logic and rolling preview events
- `CaptionTextStabilizer`: frozen prefix, editable suffix, conservative translation prefix, translation cadence
- `WhisperTranscriptionService`: optional Whisper model download/load and snapshot transcription
- `TranslationService`: Apple Translation sessions, single requests, identified batch responses
- `MeetingSessionLogger`: WAV/capture/pipeline evidence, runtime physical footprint, bounded retention
- `FloatingCaptionView` and `FloatingPanel`: current bilingual caption, history, stable layout

## Model decisions on the target Mac

- Default English ASR: Apple SpeechTranscriber. A corrected 10.855-second real-time replay first produced text at 1.024 seconds and finalized 0.201 seconds after input ended. A 300.181-second replay finished in 300.397 seconds with 39.0 MB maximum RSS and no swaps. WER was 3.45% on the synthetic content (`first`→`1st`).
- Earlier recognition-prefix comparison: Nemotron Streaming English 0.6B Q8 through NeMo-Speech.cpp 0.1.0 produced a three-word translation-ready prefix at 0.921 and 0.932 seconds in two runs, finalized 0.064 and 0.057 seconds after input ended, and had 0% WER on the primary synthetic sentence. A five-voice set produced a 1.284-second average prefix versus Apple's 1.737 seconds; semantic-normalized WER tied at 3.28%. This is not a universal subtitle-speed ranking: the later three-case integrated EN comparison had median first translations of 1.747s for Nemotron versus 1.633s for Apple + Qwen + HY 1.8B. Nemotron process RSS was about 1.05GB, with cold initialization about seven seconds.
- Whisper Small remains the multilingual fallback and comparison backend. The 10.855-second sample took 0.505 seconds as a whole-utterance pass and had 0% WER, but its snapshot architecture cannot keep computation constant as a live utterance grows.
- Whisper Large-v3 Turbo remains manual. It is not loaded alongside Apple Speech by default.
- Moonshine Medium Streaming was rejected after local testing: 34.361-second model load, 4.567-second processing for 10.462 seconds of audio, and 10.34% WER with a repeated ending.
- Hy-MT2 1.8B Q4_K_M was initially rejected as the sole default translator. The installed 1.2.1 instead keeps Apple on the fast path and optionally refines both directions. Constrained terminology/ellipsis, punctuation-scope protection and integrity guards address observed regressions, but do not guarantee every refinement is better. The earlier 2.78-second number was a whole test-set time, not per-caption latency. Exact-prefix reuse reduced median refinement processing about 24–25ms in two matched 48-case runs with identical outputs, not overall latency by that percentage.
- Nemotron remains installed but is not currently selected. Apple Speech English is the final target-machine configuration and the project default. NVIDIA's 560ms label is a model operating point, not measured subtitle latency. The official 0.1.0 runtime uses ggml/Metal on Apple Silicon, not Core ML/ANE.
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

The current suite has 277 tests. On CLT-only systems `python3 Tools/run_portable_tests.py` runs 229 core test bodies with a sequential assertion adapter, explicitly excluding 48 UI/shared-log tests. All 229 passed for the final build 8 inference pipeline; build 9 only fixes Settings window layering, compiled and visually verified above the caption overlay. This is not the standard Swift Testing runner. `Tools/EnhancementReplayMain.swift` exercises actual ASR, caption state and Apple translation on prerecorded 16kHz mono audio; `--review --refine` enables native enhancements. `--review-model` and `--refine-model` override comparison weights without changing installed defaults. `--no-bounded-finalization` retains Apple's own endpoint behavior for comparison. See `docs/refinement-1.2.1-verification-2026-09-05.md` for final installed-app evidence and limitations, and the chronological worklog for rejected intermediate versions.

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
- Do not use the frozen presentation as authoritative final source text; final corrections must reach history and translation.
- Do not wait for translation before committing final source text.
- Do not identify captions by array position or completion order; use their UUID.
- Do not clear an existing translation while its replacement is in flight.
- Do not apply Whisper microphone sensitivity to Apple Speech; it does not use `SpeechSegmenter`.
- Do not keep Apple Speech and Whisper loaded together unless a measured optional review mode justifies the memory.
- Do not claim Nemotron uses the Neural Engine or improves general English accuracy; the integrated official runtime is Metal-based and target-audio accuracy evidence is still required.
- Do not add a 1.8B/7B translation model based only on public benchmarks. Compare representative user content against Apple Translation on the target Mac.
- Keep Diagnostics off in normal use because continuous WAV/JSONL output consumes disk.
- Use `scripts/install-local.sh` for repeated local deployment so privacy permissions remain attached to a consistent signing identity.
