# Architecture as it stands (V3)

Hold `fn`, speak, release, and the text appears in whatever field has focus. The
wait after releasing is roughly constant no matter how long you spoke.

## Targets

| Target | Role |
| --- | --- |
| `XFlowCore` | Pure logic: state machine, silence detection, segment policy, transcript assembly, request builders, script verification. No AppKit, no URLSession. |
| `XFlow` | The app: hotkey, audio capture, network, overlay, menu bar, settings, paste. |
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

## Providers, and why they are split

| Stage | Provider | Model |
| --- | --- | --- |
| Speech to text | OpenAI | `gpt-4o-mini-transcribe` |
| Cleanup / formatting | Groq | `llama-3.3-70b-versatile` |

Split by measurement, not preference. Whisper commits to a single language per
clip, so code-switched Hindi/English loses whichever side does not win — Groq's
Whisper deleted the Hindi in 6 of 6 runs on a mixed recording. OpenAI's model
keeps both. Groq is far faster and cheaper for the text stage, where no such
failure exists.

Whisper model IDs still route to Groq (`Transcription.endpoint(for:)`), so
switching the STT provider back is a settings change, not a rewrite.

Two keys in the Keychain under service `com.aamirhannan.xflow`, accounts
`openai` and `groq`.

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

## Deliberate shortcuts

Marked with `ponytail:` comments naming the ceiling and the upgrade path. Live
ones: clipboard restore is plain-text only; the noise floor is an exponential
tracker rather than a real VAD; ICU romanization is a floor, not the default
path; one lock guards all audio-tap state; history has no in-memory cache and
re-reads the whole file on every query.

Two have already come due and been upgraded: `AVAudioRecorder` → `AVAudioEngine`
when segmentation arrived, and the single shared `URLSession` → one per
dictation when pooled HTTP/3 connections started hanging.
