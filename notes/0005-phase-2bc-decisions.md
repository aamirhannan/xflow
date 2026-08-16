# Phase 2B + 2C — the decisions behind the window

What was built, what was rejected and why, and what phase 3 inherits.
[0001-architecture](0001-architecture.md) describes the window as it stands; this
records the reasoning. [0004](0004-phase-2a-decisions.md) does the same for the
store underneath it.

Checks went 158 → **188**.

## Why these two shipped together

2B (the dashboard) and 2C (onboarding) were specified and built as one phase.
They share a window shell and a permissions surface; apart, both would have been
built twice. The result is one window for the whole app rather than three.

## Decisions

### Two pages, not three

Home and Settings. A separate "Dashboard" page holding charts, with "History" as
its own list, was considered and rejected: there is only one kind of data here,
so it would have meant two pages that both list dictations and a navigation click
between a number and the rows it came from.

### Three numbers, and no more

Words dictated, time spoken, day streak. Three things were declined:

- **Time saved versus typing.** The stat every competitor in this category leads
  with. It needs an assumed typing speed, which makes the number an argument
  rather than a measurement.
- **An activity chart.** Swift Charts is a system framework and this was about
  twenty lines. Declined as not worth the page space against three numbers that
  say the same thing.
- **Busiest weekday, longest dictation, average length.** Filler.

None of these are hard to add later. All three are pure functions over records
that already exist, unlike 2A's target-app field, which can never be backfilled.

### The streak breaks after an empty day, not at midnight

The only place this phase had real ambiguity, so it is pinned by checks.

Dictating on the 5th, 6th and 7th gives a streak of **3** on the 7th, still **3**
on the 8th, and **0** on the 9th. A streak that broke at midnight would show
every user a zero each morning before they had a chance to speak.

`Statistics.streak` takes `today` as a parameter rather than calling `Date()`,
which is the only reason any of that is checkable.

### Search covers both transcripts

Cleanup romanizes non-Latin script, so a phrase the speaker remembers saying in
Devanagari would be unfindable in a list that displays it in Latin. Matching runs
against `rawText` and `cleanedText`, case- and diacritic-insensitively.

### A wizard *and* a checklist

Rejected: a checklist alone, which shows a first-run user six unmet requirements
at once — where people abandon setup. Also rejected: a wizard alone, which makes
fixing one broken permission a month later mean paging through five already
satisfied.

The checklist was needed either way, so the wizard was the only extra.

### SwiftUI

`PermissionsWindow` was 210 lines of hand-rolled `NSStackView` for a form. Two
pages, a detail view and a seven-screen wizard came to fewer lines than that.
The deployment target is macOS 14; there is no reason to lay out a form by hand.

## Found while building

**A first-run wizard is a regression for existing users.** `hasCompletedOnboarding`
defaults to false, so every current install would have been shown setup for an app
it had been using for weeks. `Settings.migrateOnboardingFlag()` starts the flag
true when both API keys are already in the Keychain. Any future first-run
experience needs the same treatment.

**Deleting a type means grepping for it, not just for its file.** The plan listed
the files to change but missed `HotkeyMonitor.swift`, whose doc comment named
`PermissionsWindow`. The acceptance criterion — `grep -rn "PermissionsWindow"
Sources/` prints nothing — caught what the file list did not. Write the grep into
the plan next time, not just the file list.

**Both `git merge` and `git reset` went wrong once each in this phase.** The spec
and plan commits landed on local `main` instead of the branch, and the first
attempt to move them reset `main` to the wrong commit. Nothing was pushed and
nothing was lost, but the lesson is cheap: after cutting a branch, confirm
`git branch --show-current` *and* that the commit actually landed where intended.

## Process notes

Tasks 1 and 2 ran in parallel worktrees, split by target rather than by feature —
Session 1 owned `XFlowCore` and `XFlowChecks`, Session 2 owned `XFlow`. That
boundary was cleaner than 2A's, where `main.swift` needed an explicit owner.
Zero conflicts.

One instruction was added beyond the plan and should be repeated: **worker
sessions must not build or launch the app.** Two `XFlow.app` instances mean two
hotkey monitors competing for `fn`, which breaks the user's real dictation while
the sessions work. All app-level verification happens after the merge.

Tasks 3 and 4 both modify `MainWindow.swift`, so they stayed serial.

## Still unverified

The wizard has never been run end to end. Clearing `hasCompletedOnboarding` and
relaunching is the only way to see it, and doing so on the developer's own
machine means revoking and re-granting real permissions.

The `chmod 500` failure path from 2A is also still untested.

## What phase 3 inherits

- **No live updates.** Home reads the store when it appears and after a delete.
  A dictation made while the window is open does not appear until it is reopened.
  This is 2A's no-cache shortcut surfacing; fix it with an observer when it
  matters, not before.
- **No editing, export, or re-paste.** Deliberately out of scope.
- **Still entirely local.** No account, no sync, no server. Authentication was
  deferred to phase 3 and remains unanswered.
