# Phase 2A — the decisions behind the history store

What was built, what was rejected and why, and what the next phase needs to know.
[0001-architecture](0001-architecture.md) describes the store as it stands; this
file records the reasoning, which the code cannot.

Shipped 2026-08-17 as PR #1, merge commit `b4d9574`. Checks went 138 → **158**.

## Why phase 2 needed this first

Phase 2 is about giving XFlow a face: a dashboard, insights, and a real
onboarding flow. None of it could start, because the app kept nothing. Every
audio file was deleted after transcription and every transcript went to the
clipboard and was dropped. There was no store to read.

So phase 2 was decomposed into three, and only the first was built:

| | Piece | Depends on |
| --- | --- | --- |
| **2A** | History store — shipped | nothing |
| 2B | Dashboard — history, search, insights | 2A |
| 2C | Onboarding — the three permissions, the 🌐 key step, API keys | nothing |

2A → 2B is a hard chain: every insight is a query over the store, so a schema
designed to fit a mockup gets rewritten. 2C is independent of both.

Each gets its own spec, plan, and build cycle. Everything in phase 2 stays on
the local disk — no account, no sync, no server. Authentication is a phase 3
question, deliberately not answered here.

## Decisions

### Both transcripts, no audio

A record keeps what the model heard **and** what cleanup produced. Cleanup is
verified mechanically and can still be wrong — see finding 8 in
[0003-findings](0003-findings.md) — so the raw side is the only record of what
was actually said, and it costs about twice a text field, which is nothing.

Audio was rejected: ~1MB per minute, so hours of dictation become gigabytes, and
it would turn the file into a genuine privacy liability rather than a text log.
The cost is that old dictations can never be re-transcribed when a better model
ships. Accepted.

### Timestamp, duration, word count — and nothing else

Enough for every headline stat: totals, dictations per day, streaks, and time
saved against typing. Three things were considered and declined:

- **The target app** — the frontmost application at paste time, which needs no
  extra permission and would give per-app breakdowns. **This is the only field
  that cannot be backfilled**, because it is knowable only at the moment of the
  paste. If it is ever wanted, every record written before that day is blank.
- **Pipeline health** — perceived wait, segment count, cleanup outcome, model
  IDs. Would have turned the dashboard into a debugging surface. Addable later
  from a fresh record onward.
- **Estimated cost.** Addable later.

Word count is **derived on read, not stored**, so a later fix to the definition
of a word reaches every historical record instead of only new ones.

### Append-only JSONL

One JSON object per line, appended with a single write. Pure Foundation, no
dependency. The whole format rests on one property: JSON escapes newlines, so a
multi-paragraph transcript still occupies exactly one physical line. There is a
check for precisely that.

Corruption is bounded by construction — only the final line can ever be torn, and
the decoder skips any line it cannot parse, so the worst case is losing one
dictation rather than the file.

**SQLite was rejected**, though it would have added no dependency since macOS
ships `libsqlite3`. It costs roughly 150 lines of C interop to buy indexed
queries and partial loads that 36,000 rows do not need. Revisit if audio is ever
stored, or if history reaches the millions.

**A single rewritten JSON file was rejected**: same code size as JSONL, strictly
worse failure behaviour — a crash mid-write loses everything rather than one line.

### Keep forever, the user deletes

Auto-pruning was rejected because it makes statistics lie: "total words dictated"
silently becomes "words in the last 90 days" unless every screen is careful about
it. Opt-in recording was rejected because most people never find the toggle, and
an empty dashboard defeats the point of building one.

Instead the controls ship in the same build as the recording: **Save history**
pauses new writes without hiding what is already stored, and **Delete all
history…** removes the file behind a confirmation. A store that captures
everything the speaker says needs its off switch on day one, not in the phase
that adds the UI.

### One completion path

Both finish paths in `AppDelegate` ended with the same six statements. Rather
than adding a `record(...)` line to each, the duplicated tail was extracted into
one `complete(...)` whose final step is the write.

This was the point of the whole task. Adding two lines would have been a smaller
diff and wrong: the two paths had already drifted once — single-shot never logged
the perceived wait, segmented did — and a third caller would have forgotten to
record. With one path, "every dictation is recorded" is structural rather than a
rule two call sites must remember. The refactor also *removed* more lines than it
added.

Recording is the last thing `complete(...)` does, after the paste, so nothing the
store does can delay or break the text arriving.

## What the spec got wrong, and the code proved

Three claims were written before the code existed and did not survive contact
with it. The spec has been corrected in place; they are recorded here because
each was a reasonable-sounding mistake.

1. **`Probe.swift` needed no change.** The spec listed it as affected by the new
   return type. It is not: `Probe` rebuilds the pipeline from `XFlowCore` request
   builders and never calls `Transcriber` — it cannot, since `XFlowChecks` does
   not depend on the `XFlow` target.
2. **`HistoryStore` belongs in `XFlowCore`, not `XFlow`.** Same reason from the
   other direction: anything in the `XFlow` target is unreachable from the
   checks, so a disk layer placed there is an unchecked one by construction.
   Moving it and taking the file URL as a parameter costs one line and makes the
   whole thing checkable against a temporary directory. `Settings.historyEnabled`
   stayed in `XFlow` and gates the *call site*, so the store never learns about
   `UserDefaults`.
3. **The disk layer is checked after all.** The spec said it would not be.

The general lesson: in this repo, "can `XFlowChecks` reach it?" decides which
target a type lives in. That question is worth asking before writing the file,
not after.

## Two traps found while writing the checks

Both would have failed for reasons unrelated to the code under test.

- **ISO-8601 has no sub-second component.** A round-trip check built on `Date()`
  fails, because the fractional part does not survive. The check uses a
  whole-second timestamp. Real records lose sub-second precision too, which a
  dictation log does not need.
- **`Checks.equal` is generic over one type.** Passing an optional and a literal
  — `Int?` against `0o600`, `UUID?` against a `UUID` — makes inference ambiguous.
  Compare non-optionals, or map to arrays: `store.all().map(\.id)` against
  `[second.id, first.id]` covers count and order in one line.

## The bug the checks caught

`write(to:atomically:)` **replaces** the file rather than editing it, and the
replacement is created under the process umask. Without an explicit
`setAttributes` after every rewrite, the history would have quietly become
world-readable the first time a single record was deleted — with no error, no log
line, and nothing visible until someone thought to look at the mode.

The check asserts `0600` both on creation and after a rewrite. Do not delete it.

## Process notes

**Parallel worktrees worked here.** Tasks 1-2 (`DictationRecord`, `HistoryStore`,
`HistoryChecks`, `main.swift`) and task 3 (`TranscriptAssembler`, `Transcriber`,
`AppDelegate`, `SegmentationChecks`) touch no file in common, so they ran as two
sessions on two worktree branches and merged with zero conflicts. Tasks 4-6
depend on both lanes and stayed serial.

The split is worth repeating, with two cautions learned:

- **Disjointness is by file, not by feature.** `main.swift` was the one file both
  lanes might have reached for; assigning it explicitly to one of them is what
  kept the merge clean.
- **Tell a worker session which comments not to touch.** Every comment in
  `Transcriber` records a real bug. A session without that context would
  reasonably "tidy" them while changing the return type.

Worker sessions never merge and never push. They commit on their own branch and
the planning session assembles.

**Branching changed during this phase.** Nothing reaches `main` except through a
pull request the user merges — see `CLAUDE.md`. The one exception is folding
parallel-worktree session branches into their own feature branch, which is
assembly rather than integration.

## Outstanding

**The manual pass has never been run.** Everything mechanical is verified — build
clean, 158 checks — but these five need a microphone, the Keychain keys, and a
person:

1. Dictate twice → two lines in `~/Library/Application Support/XFlow/history.jsonl`, mode `-rw-------`
2. Uncheck **Save history**, dictate → text still pastes, no new line
3. **Delete all history…** → confirm removes the file; the next dictation recreates it
4. `chmod 500` the directory, dictate → text still pastes and the log carries
   `history append failed` rather than any user-visible error; `chmod 700` after
5. `PERCEIVED WAIT` unchanged, in its usual ~1.5s range

Until then, treat the store as built but not proven in the app.

## What 2B needs from this

The schema is fixed, so the dashboard is designed against it rather than the
reverse. Statistics are pure functions over `[DictationRecord]` and belong in
`XFlowCore`, where they can be checked — the same reasoning that moved
`HistoryStore` there.

The deployment target is macOS 14, so SwiftUI hosted through `NSHostingView` is
available. The existing hand-rolled `NSStackView` interface in
`PermissionsWindow` is not a precedent worth extending for a view that size.

Two things 2B inherits and should not re-decide: history has no in-memory cache,
so add one only when the dashboard must update while open; and the two menu-bar
controls move into the dashboard when it exists.
