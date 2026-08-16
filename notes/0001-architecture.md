# Architecture as it stands (V3)

Hold `fn`, speak, release, and the text appears in whatever field has focus. The
wait after releasing is roughly constant no matter how long you spoke.

## Targets

| Target | Role |
| --- | --- |
| `XFlowCore` | Pure logic: state machine, silence detection, segment policy, transcript assembly, request builders, script verification, history format, statistics and search. No AppKit, no URLSession. |
| `XFlow` | The app: hotkey, audio capture, network, overlay, menu bar, paste, and the SwiftUI window. |
| `XFlowChecks` | Assert-based checks, plus `--probe` for running the real pipeline over audio files. |

There is no test target. Command Line Tools ship neither `XCTest` nor
`swift-testing`, so `swift test` cannot run. `swift run XFlowChecks` replaces it.

## The app itself

Menu-bar only (`LSUIElement`), activation policy `.accessory`, **App Sandbox
off** — a sandboxed process cannot post events into other apps, which is the
whole feature. That permanently rules out the Mac App Store.

Signed with a local self-signed `XFlow Dev` certificate. macOS binds permission
grants to the code signature, so a stable identity is what stops Accessibility
being re-approved on every rebuild.

Three permissions: Microphone, Accessibility (to post ⌘V), Input Monitoring (to
see `fn` while another app is focused). Plus one manual step — System Settings →
Keyboard → "Press 🌐 key to" → **Do Nothing**, otherwise `fn` also opens the
emoji picker.

## The dictation flow

```
fn down
  └─ AVAudioEngine tap, ~93ms buffers
       ├─ RMS per buffer ──> waveform on the overlay pill
       └─ RMS per buffer ──> SilenceDetector
            └─ pause + segment ≥10s, or 30s elapsed
                 └─ close segment, write .m4a, fire async:
                      OpenAI transcription ──> Groq cleanup ──> assembler[index]
fn up
  └─ only the TAIL is unprocessed
       ├─ transcribe + clean the tail
       ├─ await any stragglers
       ├─ assemble by index (never by completion order)
       ├─ clipboard swap → synthetic ⌘V → restore clipboard
       └─ append one line to history.jsonl
```

The constant wait comes from that structure: everything except the tail was
already done while the user was still speaking.

## Providers

| Stage | Provider | Model |
| --- | --- | --- |
| Speech to text | Groq | `whisper-large-v3-turbo` |
| Cleanup / formatting | Groq | `llama-3.3-70b-versatile` |

Both legs on Groq, so **one API key runs the whole app**. About ₹3.5 per hour.

This is a trade, not an upgrade, and it reverses V3. Whisper commits to a single
language per clip, so code-switched speech loses whichever side does not win.
Measured on `audio/`, on the shipped code path:

| Recording | Result | Runs |
| --- | --- | --- |
| English | flawless, byte-identical output | 3 of 3 |
| Mixed Hindi + English | Hindi translated to English | 6 of 6 |
| Pure Hindi | translated to English | 3 of 3 |

`gpt-4o-mini-transcribe` is the only model measured to keep both languages in one
sentence, and it was the default through V3 for that reason. It costs 4.5x more
per hour, and this app's own history showed 19 of 20 real dictations were
English — so the multilingual model became a setting rather than the default.

**Switching back is one setting.** `Settings.sttModel` to
`gpt-4o-mini-transcribe`; `Transcription.endpoint(for:)` routes it to OpenAI and
the OpenAI key becomes required. Nothing else changes.

Keys live in the Keychain under service `com.aamirhannan.xflow`: account `groq`
is required, account `openai` is optional and read only when an OpenAI model is
selected.

## Cleanup

The second call is a **formatter, not an editor**. It may change exactly four
things: script (transliterate non-Latin to Latin), punctuation, capitalization,
and paragraph breaks. It may never remove, add, reorder, replace, condense, or
summarize.

Because a prompt is not a guarantee, the output is verified mechanically:

1. Still contains Devanagari or Arabic → transliteration did not happen.
2. Too dissimilar from an ICU transliteration of the input → it translated
   instead. Measured separation: transliteration 0.653–0.889, translation
   0.061–0.476, threshold 0.55.

Either failure triggers one retry that replays the model's own output with a
correction. If that also fails, the transcript is romanized deterministically
with ICU (`String.applyingTransform(.toLatin)`, ~1.2ms for four minutes). Less
natural, but it can never translate and never leave script behind.

## What is guaranteed

Every failure degrades toward "the text is on your clipboard", never toward lost
words.

| Failure | Behaviour |
| --- | --- |
| Clip under 0.4s | Discarded, no API call |
| Cleanup fails or returns empty | Raw transcript is used |
| A segment fails twice | Whole recording re-sent as one request |
| ⌘V blocked | Text left on clipboard plus a notification |
| Segmentation misbehaving | Menu toggle reverts to single-shot |

## History

Every dictation that produced text appends one JSON object to
`~/Library/Application Support/XFlow/history.jsonl`, directory `0700`, file
`0600`. Nothing leaves the machine: no account, no sync, no server.

A record holds the timestamp, the speech duration, and **both** transcripts —
what the model heard and what cleanup produced. Both, because cleanup is
verified mechanically and can still be wrong, so the raw side is the only record
of what was actually said. Audio is not kept: it would cost ~1MB per minute and
turn the file into a real privacy liability. Word count is derived on read rather
than stored, so fixing the definition later reaches old records too.

Roughly 18MB after a year of heavy use, which is why the format is deliberately
dumb. `all()` reads the whole file and filters in memory; SQLite would buy
indexed queries that 36,000 rows do not need.

**History is never allowed to break dictation.** Every store operation is
non-throwing — a full disk or a wrong permission is a log line and nothing more —
and the write happens *after* the paste, so nothing it does can delay the text
arriving. Corruption is bounded by the append-only format: only the final line
can be torn, and the decoder skips any line it cannot parse, so the worst case
is losing one dictation rather than the file.

Two controls live in the menu bar until 2B moves them into the dashboard:
**Save history** pauses new writes without hiding what is already stored, and
**Delete all history…** removes the file behind a confirmation.

## The window

One window, two pages, and a wizard that takes over the same window on first run.
AppKit owns the frame; everything inside is SwiftUI in an `NSHostingView`. The
deployment target is macOS 14, so there is no reason to lay out a form by hand.

**Home** shows three numbers — words dictated, time spoken, day streak — then a
search field and every dictation grouped by day. Selecting one opens it with
Copy, Delete, and a **Show original** toggle. That toggle is why both transcripts
are stored: when cleanup romanizes something wrongly or drops a phrase, it is the
only route back to what was actually said.

The numbers and the search are pure functions in `XFlowCore` (`Statistics`,
`HistoryQuery`), so the awkward parts are checkable — which day a timestamp
belongs to, and when a streak breaks. A streak survives the day after your last
dictation and breaks when a whole day passes empty, rather than at midnight,
which would show everyone a zero every morning.

Home reads the store when it appears and after a delete. It does not update
while open.

**Settings** is the permission checklist, both API keys, vocabulary, the three
behaviour toggles, and Delete all history. Permission state is polled every 1.5
seconds because grants are made in System Settings and nothing notifies the app.

The **wizard** runs once, one requirement per screen, and each permission screen
advances by itself when the grant lands. Its last screen offers a relaunch:
Accessibility and Input Monitoring grants do not always take effect in a process
that was already running.

This replaced `PermissionsWindow`, 210 lines of hand-rolled `NSStackView`. The
whole window — two pages, a detail view and a wizard — added fewer lines than
that form had.

## Deliberate shortcuts

Marked with `ponytail:` comments naming the ceiling and the upgrade path. Live
ones: clipboard restore is plain-text only; the noise floor is an exponential
tracker rather than a real VAD; ICU romanization is a floor, not the default
path; one lock guards all audio-tap state; history has no in-memory cache and
re-reads the whole file on every query, so Home does not update while open.

Two have already come due and been upgraded: `AVAudioRecorder` → `AVAudioEngine`
when segmentation arrived, and the single shared `URLSession` → one per
dictation when pooled HTTP/3 connections started hanging.
