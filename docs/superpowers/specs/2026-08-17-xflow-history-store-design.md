# XFlow 2A — the local history store

Phase 2 gives XFlow a face: a dashboard, insights, and a real onboarding flow.
None of it can be built yet, because the app currently keeps nothing. Every
audio file is deleted after transcription and every transcript goes to the
clipboard and is dropped. There is no store to read.

This spec covers **2A only**: persisting each dictation to disk. The dashboard
(2B) and the onboarding wizard (2C) get their own specs and their own build
cycles, in that order.

Everything stays on the local disk. No account, no sync, no server. That holds
for all of phase 2.

## Scope

**In:** a record type, a JSONL file on disk, the write path through the
dictation pipeline, a pause toggle, a delete-all control, and checks.

**Out:** the dashboard, statistics and aggregation, search, export, storing
audio, capturing which app the text was pasted into, and cost tracking. Each of
these is either a later phase or a decision made against it below.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| What is stored | Cleaned **and** raw transcript, no audio | Raw costs ~2x text, which is nothing, and is the only way to diff cleanup or recover from it misfiring — a failure mode already documented in `notes/0003-findings.md`. Audio would cost ~1MB/min and make the file a genuine privacy liability. |
| Metadata | Timestamp, speech duration, word count | The floor needed for every headline stat: totals, per-day counts, streaks, time-saved-vs-typing. |
| Format | Append-only JSONL | Pure Foundation, no dependency, one write per dictation, and corruption is bounded to the final line. |
| Location | `~/Library/Application Support/XFlow/history.jsonl` | Standard, backed up by Time Machine, synced nowhere. The app is unsandboxed, so this is the real path with no container redirection. |
| Retention | Keep forever, user deletes | No silent data loss, and all-time statistics stay honest. Auto-pruning would quietly turn "total words dictated" into a stat that lies. |
| Write site | One unified completion path | Structural guarantee that every dictation is recorded, rather than a rule two call sites must remember. |

### Deliberately rejected

**Capturing the target app.** The frontmost application at paste time would
unlock per-app breakdowns, and it needs no additional permission. It was
considered and declined. Note that it is the **only field that cannot be
backfilled** — it is knowable only at paste time. Every other omitted field
(cost, latency, cleanup outcome) can be added later without losing history.

**Storing word count.** Derived on read instead. Freezing today's definition of
a word into the file means a later fix cannot reach old records.

**SQLite.** macOS ships `libsqlite3`, so it would add no dependency, but it costs
roughly 150 lines of C interop to buy indexed queries and partial loads that
36,000 rows do not need. Revisit if audio is ever stored, or if history reaches
the millions.

## Architecture

Three new files, following the target split the repo already uses: pure logic in
`XFlowCore` where it is checkable, OS-touching code in `XFlow`.

| File | Target | Responsibility |
| --- | --- | --- |
| `Sources/XFlowCore/DictationRecord.swift` | XFlowCore | The record type and JSONL encode/decode. String ↔ struct only, no filesystem. |
| `Sources/XFlow/HistoryStore.swift` | XFlow | The file: append, read, delete. Owns all I/O and all failure swallowing. |
| `Sources/XFlowChecks/HistoryChecks.swift` | XFlowChecks | Round-trip, corruption, and word-count checks. |

The split exists so the format's worst edge case — a half-written final line —
is testable without touching a filesystem.

## The record

```swift
public struct DictationRecord: Codable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let durationSeconds: Double
    public let rawText: String
    public let cleanedText: String

    public var wordCount: Int   // derived from cleanedText, not persisted
}
```

`wordCount` splits `cleanedText` on whitespace and counts non-empty components.
It reads `cleanedText` rather than `rawText` because cleanup romanizes
non-Latin script, so the cleaned side is uniformly whitespace-delimited.

When cleanup is disabled, fails, or falls back, `cleanedText` equals whatever
the pipeline actually produced — which may be identical to `rawText`. That is
correct and needs no special case.

Encoding uses `JSONEncoder` with `.iso8601` date encoding, so the file stays
human-readable and greppable.

**One record per line.** JSON escapes newlines as `\n`, so a multi-paragraph
transcript still occupies exactly one physical line. The whole format depends on
this property, so it gets its own check.

## The store

```swift
final class HistoryStore {
    func record(_ record: DictationRecord)   // append; returns immediately
    func all() -> [DictationRecord]          // newest first
    func delete(id: UUID)
    func deleteAll()
}
```

- **Append** — `FileHandle` seek-to-end plus one line, on a private serial
  dispatch queue so the main thread never touches disk. `record()` returns
  immediately and reports nothing.
- **Read** — reads the whole file, decodes, returns newest first. No cache and
  no change notifications. Mark this with a `ponytail:` comment: the dashboard
  reads on open, so a cache is only needed once it must update live.
- **Delete one** — rewrites the file without that line. O(n), irrelevant at this
  scale.
- **Delete all** — removes the file.

The directory is created with POSIX permissions `0700` and the file with `0600`.

`Settings.historyEnabled` (default `true`) gates `record()`. When off it is a
no-op; reads and deletes still work, so existing history stays visible and
removable after recording is paused.

## Pipeline integration

### The unified completion path

Both finish paths in `AppDelegate` currently end with the same sequence —
transcribe, `handle(.transcriptReady)`, `Inserter.insert`, hide the pill,
`handle(.inserted)`, notify if the paste was blocked. That duplication is
extracted into a single `complete(...)` method whose final step is
`history.record(...)`.

This is what makes "every dictation is recorded" structurally true rather than a
convention two call sites must maintain. It also removes existing duplication,
so the net line count goes down.

### The `Transcript` type

Storing the raw transcript requires a change the existing code does not support.
`Transcriber.transcribe` returns only the final string; the raw transcript is a
local variable discarded at all five of its exit points. Because cleanup runs
per segment, `TranscriptAssembler` likewise only ever holds cleaned pieces.

A small type is threaded through:

```swift
public struct Transcript: Equatable {
    public let raw: String
    public let cleaned: String
}
```

- `Transcriber.transcribe(fileURL:)` returns `Transcript` instead of `String`.
  Its five exits each pair the raw transcript with what that path produced: the
  cleanup-disabled early return, the verified cleanup, the verified retry, the
  caught-error fallback, and the deterministic ICU romanization fallback.
- `TranscriptAssembler` stores `[Int: Transcript]`, and `assembled()` returns a
  `Transcript` whose two sides are each joined in index order.
- `AppDelegate` passes both sides into the record at its three call sites
  (single-shot, segmented tail, whole-audio fallback).
- `XFlowChecks/Probe.swift` is updated for the new return type.

`Transcript` lives in `Sources/XFlowCore/TranscriptAssembler.swift` alongside the
type that assembles it, rather than in a file of its own.

### What is recorded

Only dictations that produced text. A sub-0.4s hotkey tap, a "Nothing heard"
result, and any network failure write nothing — there is no transcript to store,
and no pipeline-health metadata is being kept that would justify an empty row.

## Controls

Two controls ship with 2A rather than waiting for the dashboard, because a store
that captures everything the user says needs its off-switch from the first
build:

- **"Save history"** — a checked menu-bar item bound to `Settings.historyEnabled`,
  on by default.
- **"Delete all history…"** — a menu-bar item that confirms with an `NSAlert`
  before calling `deleteAll()`.

Both move into the dashboard in 2B. Per-record deletion is exposed by the store
API now and gets its user interface in 2B.

## Failure behaviour

**History must never break dictation.** Every store operation is non-throwing.
A full disk, wrong permissions, or an unreadable file is logged through the
existing `OSLog` subsystem and otherwise ignored. By the time `record()` runs the
paste has already happened, so nothing downstream depends on the result.

| Failure | Behaviour |
| --- | --- |
| Directory or file cannot be created | Logged, dictation unaffected, nothing recorded |
| Write fails mid-append | Logged; the torn line is skipped on the next read |
| A line cannot be decoded | Skipped; every other record still loads |
| File missing on read | Empty history, not an error |
| Recording paused | `record()` is a no-op; reads and deletes still work |

Corruption is bounded by the append-only format: only the final line can ever be
torn, so the worst case is losing one dictation from history, never the file.

## Checks

`swift run XFlowChecks` gains `HistoryChecks`:

1. Encode then decode returns an equal record.
2. A transcript containing newlines encodes to exactly one line.
3. A file whose final line is truncated still yields every record before it.
4. An unparseable line in the middle is skipped without losing the lines after it.
5. `wordCount` is correct for Latin text, mixed Hindi/English text, and the
   empty string.
6. `TranscriptAssembler` joins `raw` and `cleaned` independently, both in index
   order — extending the existing assembler coverage.

The disk layer is deliberately not checked. It is roughly twenty lines of
`FileHandle` calls, and everything that can be got wrong about the format lives
in the pure layer above.

## Success criteria

- `swift build` is clean with zero warnings, and `swift run XFlowChecks` reports
  zero failures.
- After dictating, `~/Library/Application Support/XFlow/history.jsonl` contains
  one line per dictation, with both transcripts and a plausible duration.
- Turning off "Save history" stops new lines from appearing; existing lines
  remain readable and deletable.
- "Delete all history…" removes the file after confirmation.
- Deleting the file while the app runs, or corrupting its last line by hand, does
  not break dictation and does not throw.
- Perceived wait is unchanged — the write is off the main thread and after the
  paste.

## Next

2B designs the dashboard against this schema: statistics as pure functions over
`[DictationRecord]` in `XFlowCore`, and a SwiftUI window hosted through
`NSHostingView`. The deployment target is macOS 14, so SwiftUI is fully
available, and the existing hand-rolled `NSStackView` user interface is not a
precedent worth extending for a view this size.
