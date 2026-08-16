# Phase 2B/2C workstream split — two parallel sessions

Splits [2026-08-17-xflow-ui.md](2026-08-17-xflow-ui.md) across two worktree
sessions. **Read that plan for the actual code** — this file only says who owns
what.

Base branch: `feat/xflow-window` (cut from `docs/phase2bc-ui`, which carries the
spec and the plan).

## Ownership

Every file has exactly one owner. Zero overlap — verified with
`git diff --name-only` before merging.

| Session | Branch | Plan task | Files |
| --- | --- | --- | --- |
| 1 | `feat/xflow-window-s1` | Task 1 | **Create** `Sources/XFlowCore/Statistics.swift`, `Sources/XFlowCore/HistoryQuery.swift`, `Sources/XFlowChecks/StatisticsChecks.swift`, `Sources/XFlowChecks/HistoryQueryChecks.swift` · **Modify** `Sources/XFlowChecks/main.swift` |
| 2 | `feat/xflow-window-s2` | Task 2 | **Create** `Sources/XFlow/Permissions.swift`, `Sources/XFlow/MainWindow.swift`, `Sources/XFlow/SettingsView.swift` · **Modify** `Sources/XFlow/AppDelegate.swift`, `Sources/XFlow/MenuBarController.swift` · **Delete** `Sources/XFlow/PermissionsWindow.swift` |

### Session 1 must not touch

Anything under `Sources/XFlow/`. Session 1 works only in `XFlowCore` and
`XFlowChecks`.

### Session 2 must not touch

Anything under `Sources/XFlowCore/` or `Sources/XFlowChecks/` — including
`main.swift`, which belongs to Session 1.

## Acceptance, both sessions

```bash
swift build          # zero warnings
swift run XFlowChecks   # zero failures
```

**Neither session launches the app.** Two `XFlow.app` instances running at once
means two menu-bar icons and two hotkey monitors fighting over `fn`, which will
disrupt the user's actual dictation. Do not run `./build.sh debug` and do not
`open build/XFlow.app`. The planning session does every app-level check on the
merged tree.

That means Session 2 skips Step 7 of Task 2 entirely — the window, the permission
rows, the toggles, and the dictation check are all verified after the merge. Say
so in the end summary.

**Never run `swift run XFlow`**: it produces an unbundled process with no
`Info.plist` and traps in `UNUserNotificationCenter`.

## Notes for Session 2

- `Permissions.swift` and the deletion of `PermissionsWindow.swift` happen in the
  **same step**. Creating the new file while the old one still declares the same
  enum is a redeclaration error.
- `SettingsView.swift` imports `AppKit` explicitly for `NSAlert`. Do not rely on
  `SwiftUI` re-exporting it.
- The `Delete all history…` menu item and its `onDeleteAllHistory` callback are
  removed from `MenuBarController` and `AppDelegate` — that action moves into
  Settings. The `Save history` toggle **stays** in the menu.
- After the work, `grep -rn "PermissionsWindow" Sources/` must print nothing.

## Commit format

Conventional prefix, a body explaining *why*, and the attribution trailer this
repo uses on every commit:

```
feat: statistics and history search as pure functions

<why, in a sentence or two>

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

Commit on your own branch only. **Do not merge. Do not push.** The planning
session merges into `feat/xflow-window`; the user merges that to `main` through a
pull request.

## Merge order

Session 1 first (pure additions in a different target, cannot conflict), then
Session 2. Expected conflicts: none.

## Left for the planning session after both land

- Task 3 — `HomeView` and the detail pane. Consumes Session 1's functions and
  modifies Session 2's `MainWindow.swift`, so it cannot run in parallel with
  either.
- Task 4 — the first-run wizard. Also modifies `MainWindow.swift`.
- Task 5 — notes, decision record, and the pull request.
- Every app-level verification both sessions skipped.
