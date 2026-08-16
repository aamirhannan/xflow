# Phase 2A workstream split — two parallel sessions

Splits [2026-08-17-xflow-history-store.md](2026-08-17-xflow-history-store.md) across two
worktree sessions. **Read that plan for the actual code** — this file only says who
owns what.

Base branch: `feat/history-store` (cut from `docs/phase2a-history-store`, which
carries the spec and the plan).

## Ownership

Every file has exactly one owner. There is **zero** overlap between the two
sessions — verified with `git diff --name-only` before merging.

| Session | Branch | Plan tasks | Files |
| --- | --- | --- | --- |
| 1 | `feat/history-store-s1` | Tasks 1 and 2 | **Create** `Sources/XFlowCore/DictationRecord.swift`, `Sources/XFlowCore/HistoryStore.swift`, `Sources/XFlowChecks/HistoryChecks.swift` · **Modify** `Sources/XFlowChecks/main.swift` |
| 2 | `feat/history-store-s2` | Task 3 | **Modify** `Sources/XFlowCore/TranscriptAssembler.swift`, `Sources/XFlow/Transcriber.swift`, `Sources/XFlow/AppDelegate.swift`, `Sources/XFlowChecks/SegmentationChecks.swift` |

### Session 1 must not touch

`Sources/XFlowCore/TranscriptAssembler.swift`, `Sources/XFlow/Transcriber.swift`,
`Sources/XFlow/AppDelegate.swift`, `Sources/XFlowChecks/SegmentationChecks.swift`,
`Sources/XFlow/Settings.swift`, `Sources/XFlow/MenuBarController.swift`.

### Session 2 must not touch

`Sources/XFlowCore/DictationRecord.swift`, `Sources/XFlowCore/HistoryStore.swift`,
`Sources/XFlowChecks/HistoryChecks.swift`, **`Sources/XFlowChecks/main.swift`**,
`Sources/XFlow/Settings.swift`, `Sources/XFlow/MenuBarController.swift`.

`main.swift` is the one file both sessions might reach for — Session 1 registers
two check groups there and Session 2 registers none. It belongs to Session 1.

## Acceptance, both sessions

```bash
swift build          # zero warnings
swift run XFlowChecks   # zero failures
```

Neither session builds or launches the app. `./build.sh debug` and the dictation
tests need a microphone, API keys in the Keychain, and a human — the planning
session runs them on the merged tree. **Never run `swift run XFlow`**: it
produces an unbundled process with no `Info.plist` and traps in
`UNUserNotificationCenter`.

Session 2 therefore stops after Step 6 of Task 3 and skips Step 7 (the manual
dictation check). Say so in the end summary.

## Commit format

Conventional prefix, a body explaining *why*, and the attribution trailer this
repo already uses on every commit:

```
feat: dictation record and its JSONL line format

<why, in a sentence or two>

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

Commit on your own branch only. **Do not merge. Do not push.** The planning
session merges into `feat/history-store`; the user merges that to `main` through
a pull request.

## Merge order

Session 1 first (pure additions, cannot conflict), then Session 2. Expected
conflicts: none.

## Left for the planning session after both land

- Task 4 — `Settings.historyEnabled`, the unified `complete(...)` path, and the
  recording call. Needs both lanes: `HistoryStore` from 1, `Transcript` from 2.
- Task 5 — the menu-bar controls.
- Task 6 — notes, spec corrections, and the pull request.
- The end-to-end verification Session 2 skipped, run once on the merged tree.
