# XFlow 2B + 2C — the window

Phase 2A gave XFlow a store. This gives it a face: a two-page window over that
store, and a first-run wizard that replaces the setup screen.

2B (dashboard) and 2C (onboarding) are specified together because they share a
window shell and a permissions surface. Designing them apart would mean building
both twice.

Everything stays local. No account, no sync, no server. Authentication is a phase
3 question and is not answered here.

## What exists to build on

`HistoryStore.all()` returns `[DictationRecord]`, newest first, where a record
carries `id`, `timestamp`, `durationSeconds`, `rawText`, `cleanedText`, and a
derived `wordCount`. See [the 2A spec](2026-08-17-xflow-history-store-design.md)
and `notes/0004-phase-2a-decisions.md`.

There is no target app, no cost, and no latency on a record. Any stat needing
those is out until new records start carrying them.

The deployment target is macOS 14, so SwiftUI is fully available. The current
interface is hand-rolled `NSStackView`; that is not a precedent worth extending.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Page count | Two: **Home** and **Settings** | There is one kind of data here. Splitting "dashboard" from "history" makes two pages that both list dictations, with a navigation click between a number and the rows it came from. |
| Window count | One, for everything including the wizard | The wizard takes over the same window on first run. Three windows for an app whose main interface is a menu-bar icon is three too many. |
| Stats | Words dictated, time spoken, day streak | The three that need nothing beyond what a record already holds. |
| Row interaction | Click opens a detail pane | The only shape with somewhere natural to put the raw transcript, which is what makes 2A's raw column worth its storage. |
| Onboarding | Wizard first run, checklist in Settings after | A first-run user with nothing granted and someone fixing one broken permission need different screens. The checklist is needed regardless, so the wizard is the only extra. |
| Toolkit | SwiftUI in `NSHostingView` | A dashboard in AppKit is thousands of lines. The same thing in SwiftUI is hundreds. |

### Deliberately rejected

**Time saved versus typing.** The headline stat every competitor leads with.
Declined: it needs an assumed typing speed, which makes the number an argument
rather than a measurement.

**An activity chart.** Swift Charts is a system framework and this would have
been about twenty lines. Declined as not worth the page space against three
numbers that say the same thing.

**Busiest weekday, longest dictation, average length.** Declined as filler.

**Export, editing a stored transcript, re-pasting into the last app, storing
audio.** All out of scope.

## Architecture

One `NSWindow` owned by `AppDelegate`, containing an `NSHostingView`. Which page
it shows is SwiftUI state.

| File | Target | Responsibility |
| --- | --- | --- |
| `Sources/XFlowCore/Statistics.swift` | XFlowCore | Totals and the streak. Pure functions over `[DictationRecord]`. |
| `Sources/XFlowCore/HistoryQuery.swift` | XFlowCore | Search filtering and day grouping. Pure. |
| `Sources/XFlow/Permissions.swift` | XFlow | The `Permissions` enum, extracted from `PermissionsWindow`. |
| `Sources/XFlow/MainWindow.swift` | XFlow | The window, the hosting view, and which page is showing. |
| `Sources/XFlow/HomeView.swift` | XFlow | Stats row, search, grouped list, detail pane. |
| `Sources/XFlow/SettingsView.swift` | XFlow | Permission checklist, API keys, vocabulary, toggles, delete-all. |
| `Sources/XFlow/OnboardingView.swift` | XFlow | The first-run wizard. |
| `Sources/XFlowChecks/StatisticsChecks.swift` | XFlowChecks | Streak and totals, including the edge cases. |
| `Sources/XFlowChecks/HistoryQueryChecks.swift` | XFlowChecks | Search and grouping. |

**Deleted:** `Sources/XFlow/PermissionsWindow.swift`, about 210 lines. Its
`Permissions` enum moves to its own file because both `SettingsView` and
`OnboardingView` need it; the window and its hand-rolled stack view go.

**Modified:** `AppDelegate.swift` (owns the window, opens the wizard on first
run), `MenuBarController.swift` (menu items), `Settings.swift` (one new flag),
`XFlowChecks/main.swift` (two new check groups).

Logic lives in `XFlowCore` for the reason 2A established: `XFlowChecks` depends
only on `XFlowCore`, so anything in the `XFlow` target is unreachable from the
checks.

## The pure layer

### Statistics

```swift
public enum Statistics {
    public static func totalWords(_ records: [DictationRecord]) -> Int
    public static func totalSpeechSeconds(_ records: [DictationRecord]) -> Double
    public static func streak(
        _ records: [DictationRecord], today: Date, calendar: Calendar = .current
    ) -> Int
}
```

`today` is a parameter rather than `Date()` so every streak edge case is
checkable.

**Streak rules**, stated because they are the only place this spec has genuine
ambiguity:

1. No records → `0`.
2. Records are grouped into calendar days in the given calendar.
3. If there is a record **today**, count back from today across consecutive days.
4. If there is none today but one **yesterday**, count back from yesterday. A
   streak does not break the instant midnight passes — it breaks when a whole day
   goes by without dictation.
5. Otherwise → `0`.

So dictating on the 5th, 6th and 7th gives a streak of 3 on the 7th, still 3 on
the 8th, and 0 on the 9th.

### HistoryQuery

```swift
public struct DayGroup: Equatable, Identifiable {
    public let id: Date          // start of that day
    public let title: String     // "Today", "Yesterday", or a formatted date
    public let records: [DictationRecord]
}

public enum HistoryQuery {
    public static func matching(_ query: String, in records: [DictationRecord]) -> [DictationRecord]
    public static func groupedByDay(
        _ records: [DictationRecord], today: Date, calendar: Calendar = .current
    ) -> [DayGroup]
}
```

**Search** trims the query; an empty or whitespace-only query returns every
record unchanged. Matching is case- and diacritic-insensitive, and runs against
**both** transcripts — a phrase remembered in Hindi still finds the record even
though the list displays it romanized.

**Grouping** preserves the newest-first order of both the groups and the records
within them.

## Home

```
┌─ XFlow ────────────────────────────┐
│  [ Home ]  [ Settings ]            │
├────────────────────────────────────┤
│  12,480      4.2h      31 days     │
│  words       spoken    streak      │
│                                    │
│  ┌─ Search ────────────────────┐   │
│  │ Today                       │   │
│  │  09:14  Mujhe RBAC ka...    │   │
│  │  09:02  Can you check...    │   │
│  │ Yesterday                   │   │
│  │  18:33  The audit trail...  │   │
│  └─────────────────────────────┘   │
└────────────────────────────────────┘
```

Three numbers, a search field, then dictations grouped by day. Each row is a
time and a one-line preview of the cleaned text.

Selecting a row opens a detail pane showing the full cleaned text, **Copy**,
**Delete**, and a **Show original** toggle that reveals `rawText`. That toggle is
the recovery path when cleanup romanizes something wrongly or drops a phrase.

**Loading.** `HistoryStore.all()` is read when the window appears and again after
a delete. There are no live updates while the window is open — a dictation made
with the window visible will not appear until it is reopened. This carries
forward 2A's `ponytail:` note: add a cache and change notifications when live
updates are actually wanted.

**Empty states**, deliberately distinct:

| Condition | Message |
| --- | --- |
| No records at all | Hold `fn` anywhere to dictate. Your history appears here. |
| Search matches nothing | No dictations match that search. |
| History recording paused | A quiet note that new dictations are not being saved, with a link to Settings. |

## Settings

One scrolling page:

1. **Permissions** — Microphone, Accessibility, Input Monitoring, each with a
   live ✅/⚠️ and a button opening the right System Settings pane. Plus the manual
   Keyboard → "Press 🌐 key to" → Do Nothing step, which no API can check or set.
2. **API keys** — OpenAI and Groq, stored in the Keychain, never on disk.
3. **Vocabulary** — with the existing note that it is the app's biggest accuracy
   lever.
4. **Behaviour** — Clean up transcripts, Transcribe while speaking, Save history.
5. **Delete all history…** — with a confirmation.

Permission state is polled every 1.5 seconds while the page is visible, as
today's window already does, because grants are made in System Settings and
nothing notifies the app.

## The wizard

Shown on first launch, gated on `Settings.hasCompletedOnboarding`:

1. **Welcome** — what XFlow does, in a sentence, and that everything stays on
   this Mac.
2. **Microphone** — request, live status.
3. **Accessibility** — why it is needed (posting ⌘V), open the pane, live status.
4. **Input Monitoring** — why it is needed (seeing `fn` while another app is
   focused), open the pane, live status.
5. **The 🌐 key** — set "Press 🌐 key to" to Do Nothing, otherwise `fn` also opens
   the emoji picker. Manual, with a "Done" the user asserts.
6. **API keys** — both fields, with a note on why transcription and cleanup use
   different providers.
7. **Finish** — hold `fn` and speak.

Each permission screen advances on its own when the grant lands, using the same
1.5s poll.

**Relaunch.** Accessibility and Input Monitoring grants do not always take effect
in a running process. The final screen offers a relaunch rather than leaving the
user with a green checklist and a dead `fn` key: launch a new instance from
`Bundle.main.bundleURL` and terminate. The wizard can also be reopened from
Settings, so a mistaken "Done" on the manual step is recoverable.

## Failure behaviour

The window is a reader. It cannot corrupt the store, and every failure below
degrades to an empty or stale view rather than an error.

| Failure | Behaviour |
| --- | --- |
| History file missing or unreadable | Empty state. `HistoryStore.all()` already returns `[]`. |
| A record fails to decode | Skipped by the store; the rest display. |
| Delete fails | The row reappears on the next read. No dialog. |
| Keychain write fails | The field shows what was typed; the existing transcription error path already reports a missing key. |
| A permission is revoked while running | The checklist turns ⚠️ within 1.5s. |

## Checks

`swift run XFlowChecks` gains two groups:

**Statistics** — totals over an empty array and a populated one; streak of zero
on empty; a single day; three consecutive days; a streak that survives a day with
no dictation *today* but one yesterday; a streak broken by a two-day gap;
multiple dictations on one day counting once; and records spanning a month
boundary.

**HistoryQuery** — an empty query returns everything; whitespace-only likewise;
case-insensitive matching; diacritic-insensitive matching; a match found in
`rawText` when `cleanedText` does not contain it; no matches returning empty;
grouping into Today, Yesterday and older; newest-first order preserved across
groups and within them; multiple records on one day landing in one group.

The SwiftUI views get no checks. There is no test framework on this machine, and
view code is verified by looking at it.

## Success criteria

- `swift build` clean with zero warnings; `swift run XFlowChecks` zero failures.
- **Open XFlow** shows Home with the three numbers and every stored dictation,
  grouped by day.
- Search narrows the list, including on a phrase present only in `rawText`.
- A row opens the detail pane; Copy puts the cleaned text on the clipboard;
  Show original reveals the raw transcript; Delete removes the row and it stays
  gone after reopening.
- Settings shows live permission states, saves both keys and the vocabulary, and
  its toggles agree with the menu bar.
- With `hasCompletedOnboarding` cleared, launching shows the wizard, each
  permission screen advances as the grant is made, and Finish offers a relaunch.
- `PermissionsWindow.swift` no longer exists and nothing references it.
- Dictation is unaffected: perceived wait unchanged, the hotkey still works with
  the window open and closed.

## Build order

| | Lane | Depends on |
| --- | --- | --- |
| 0 | `MainWindow` shell, `Permissions` extracted, menu wiring | — |
| A | `Statistics`, `HistoryQuery`, and their checks | 0 |
| B | `SettingsView`, `OnboardingView`, delete `PermissionsWindow` | 0 |
| C | `HomeView` and the detail pane | 0, A |

Lane 0 is shared pre-work and cannot be parallel. B is disjoint from A and C and
can run alongside either. C consumes A, so it follows A.
