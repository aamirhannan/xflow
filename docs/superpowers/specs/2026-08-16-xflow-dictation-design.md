# XFlow — push-to-talk dictation for macOS

**Date:** 2026-08-16
**Status:** Approved design, ready for implementation planning

## Problem

Wispr Flow solves push-to-talk dictation extremely well but costs $29/month for
a feature set that is 95% unused: dashboards, analytics, history, team
management. The only part that matters is the loop: hold a key, speak, release,
and the text lands in whatever field the cursor is in. With a personal OpenAI
key the same loop costs a few dollars a month.

Two properties of the paid tool must be preserved:

1. **Near-perfect accuracy** on natural, fast speech.
2. **Mixed-language handling**: Hindi/Urdu spoken aloud comes out written in
   Latin script ("mujhe yeh chahiye"), not Devanagari, so it can be pasted into
   English-language contexts unchanged.

## Goals

Hold `fn` anywhere in macOS → speak → release → the transcribed, cleaned text
appears in the active text field within roughly 2 seconds. Permissions are
granted exactly once. Nothing else.

## Non-goals for v1

Explicitly cut, to be reconsidered only on demand: transcript history,
dashboard, analytics, streaming partial text, custom vocabulary/prompt
dictionary, per-app formatting profiles, auto-update, team distribution and
notarization, offline/local model fallback, rich (non-text) clipboard restore.

## Decisions

| Decision | Choice | Reason |
| --- | --- | --- |
| Transcription | OpenAI `gpt-4o-transcribe` (model configurable) | User already holds an OpenAI key; strong multilingual accuracy |
| Text cleanup | OpenAI `gpt-4o-mini`, single call | Romanizes Hindi/Urdu, strips fillers, fixes punctuation |
| Trigger | Hold `fn` / Globe, keyCode 63 | Matches existing muscle memory from Wispr Flow |
| Feedback | Floating pill with live waveform | Confirms the mic is live without moving the eyes to the menu bar |
| Distribution | Local only, stable self-signed certificate | No Apple Developer account needed; Developer ID is a later build-setting swap |
| Language | Swift, AppKit, zero third-party dependencies | Everything needed is in AVFoundation/AppKit/Foundation |

## Architecture

A single menu-bar-only application (`LSUIElement = true`). The app never
becomes the frontmost application, which is what allows a synthetic paste to
land in the user's actual target window rather than in our own UI.

**App Sandbox must be disabled.** A sandboxed process cannot post events into
other applications, which is the core of the feature. This permanently rules
out Mac App Store distribution and is accepted.

### State machine

```
idle → recording → transcribing → inserting → idle
```

One enum with one owner. Every component is driven by it and holds no
independent state. Any error transitions directly back to `idle` after
surfacing feedback.

### Components

| Component | Responsibility | Implementation |
| --- | --- | --- |
| `HotkeyMonitor` | Detect `fn` press and release | `NSEvent.addGlobalMonitorForEvents` + `addLocalMonitorForEvents` on `.flagsChanged`, filtered to keyCode 63 |
| `Recorder` | Capture audio, report level | `AVAudioRecorder` writing a temp `.m4a`; `averagePower(forChannel:)` polled at 20 Hz |
| `Transcriber` | Audio bytes → clean text | Two `URLSession` calls: multipart `POST /v1/audio/transcriptions`, then `POST /v1/chat/completions` |
| `Inserter` | Text → active field | Save clipboard, write text, post synthetic ⌘V, restore clipboard |
| `OverlayPill` | Show current state | Borderless non-activating `NSPanel` with waveform bars and a spinner |
| `MenuBar` | Key entry, toggles, quit | `NSStatusItem`; API key stored in Keychain |
| `PermissionsWindow` | First-run and recovery | Live status per grant with deep links into System Settings |

Target size is roughly 500–600 lines across six or seven files. No package
dependencies.

### Flow

1. `fn` down → check `IsSecureEventInputEnabled()`; if true, show a refusal on
   the pill and abort.
2. Show the pill, start `AVAudioRecorder` into a temp `.m4a`, begin polling the
   level meter to drive the waveform.
3. `fn` up → stop recording. If the clip is shorter than 0.4 s, discard it and
   make no network call.
4. Pill switches to a spinner. Upload the `.m4a` to the transcription endpoint.
5. Pass the transcript through the cleanup call.
6. Save the current clipboard string, write the result, wait ~80 ms, post ⌘V,
   wait ~150 ms, restore the previous clipboard string.
7. Fade the pill out, delete the temp file, return to `idle`.

### Deliberate simplifications

Both of these are intentional and should carry a `ponytail:` comment naming the
ceiling and the upgrade path.

- **`NSEvent` monitor instead of `CGEventTap`.** An event tap requires a
  run-loop source and is silently disabled by the OS on timeout. The `NSEvent`
  monitor is about ten lines. This works only because we do not need to
  *swallow* the keystroke — which in turn requires the user to set System
  Settings → Keyboard → "Press 🌐 key to:" → **Do Nothing**, so `fn` does not
  also open the emoji picker or trigger Apple's dictation. If swallowing the
  key ever becomes necessary, upgrade to `CGEventTap`.
- **`AVAudioRecorder` instead of `AVAudioEngine`.** The recorder writes an
  encoded file directly and provides metering for free. `AVAudioEngine` would
  mean owning buffers, format conversion, and WAV encoding by hand for no gain.
  Upgrade only if streaming partial transcripts is ever wanted.

## Permissions

| Grant | Needed for | How it is obtained |
| --- | --- | --- |
| Microphone | Recording | Auto-prompted on first record via `NSMicrophoneUsageDescription` |
| Accessibility | Posting the synthetic ⌘V; global key monitoring | Never auto-prompts; detected with `AXIsProcessTrusted()`, user sent to Settings |
| Input Monitoring | Keyboard monitoring on some macOS versions | May appear alongside Accessibility depending on version; detected and guided the same way |

### Signature stability

macOS binds a TCC grant to the application's code signature, not its path. An
unsigned or ad-hoc-signed build produces a new signature on every compile, so
the OS treats each build as a new application and every grant must be given
again. The fix is a single self-signed Code Signing certificate created once in
Keychain Access and used for every build: the identity never changes, so grants
persist. A paid Apple Developer ID is required only to hand the `.app` to other
people without a Gatekeeper warning, and is out of scope for v1.

### First-run window

The only real window in the app. Four rows, each with live status and an "Open
Settings" deep link: Microphone, Accessibility, Input Monitoring, and "Globe
key set to Do Nothing". Plus the API key field. The window re-opens on its own
if a grant is later revoked.

## Known hazards and countermeasures

| Hazard | Countermeasure |
| --- | --- |
| Pill steals key focus, so ⌘V lands in our own UI | `.nonactivatingPanel`, `canBecomeKey = false`, app is `LSUIElement`. The most common failure mode of hand-built versions of this tool. |
| Secure Event Input (password fields) blocks both monitoring and paste | Check `IsSecureEventInputEnabled()` on `fn` down and refuse visibly rather than recording into a void |
| Target app reads the pasteboard before our write lands | Ordered delays: write → 80 ms → ⌘V → 150 ms → restore |
| Clipboard restore is text-only, so a copied image is lost | Accepted for v1, marked with a `ponytail:` comment. Full multi-type restore is roughly 30 more lines. |
| Recording stuck open if an event is missed | Hard 2-minute cap that auto-stops and transcribes |

## Error handling

Every failure degrades toward "the text is on your clipboard", never toward
"your words are gone".

| Failure | Behaviour |
| --- | --- |
| Clip shorter than 0.4 s | Discard silently, no API call |
| Transcript empty (silence) | Nothing pasted, pill fades |
| Cleanup call fails (after a successful transcription) | Paste the raw transcript — a Devanagari transcript beats no transcript |
| Transcription call fails (network down, timeout) | One retry, then a notification; nothing pasted, because there is nothing to paste |
| HTTP 401 | Pill reports an invalid key and opens settings |
| HTTP 429 | One backoff retry, then a notification |
| ⌘V blocked or Accessibility missing | Text left on the clipboard plus a notification saying so |

## Testing

Most of this system is OS-level and can only be proven by hand. The split is
therefore explicit rather than aspirational.

**Automated** — an `XFlowCore` target holding the pure logic, covered by one
`swift test` file: state-machine transitions, multipart body construction, API
response decoding, the minimum-duration gate, and clipboard save/restore.

**Manual smoke checklist**, documented in the README and run before any
release: paste into Chrome, paste into VS Code, attempt in a password field,
run with the network off, run with Accessibility revoked, and confirm the
2-minute cap.

## Cost

Approximately `$0.006` per minute of audio for `gpt-4o-transcribe`, plus a few
cents per month for the cleanup pass — roughly **$2–5/month** at realistic
dictation volume against $29/month for the commercial tool.
`gpt-4o-mini-transcribe` roughly halves the transcription cost at slightly
lower quality, so the model is exposed as a setting. Current OpenAI pricing
should be confirmed when the key is wired up; these figures are from memory.

## Definition of done

Hold `fn` in any application, speak a mixed Hindi/English sentence, release,
and within roughly two seconds the romanized English text is in the active text
field — with system permissions having been approved exactly once.
