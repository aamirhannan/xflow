# XFlow — rules for working in this repo

## Branching

Never commit directly to `main`.

1. Confirm the base branch before starting. It is usually `main`, but ask if the
   work builds on something unmerged.
2. Cut a branch from that base: `git checkout -b <type>/<short-name> <base>`.
   Types: `feat/`, `fix/`, `docs/`, `chore/`.
3. Do the work there, committing as you go.
4. Merge back into the base with `--no-ff` once it builds and all checks pass.
5. Push only when the user asks.

## Ask before changing

Describe what you intend to change and wait for a go-ahead before editing. This
applies to code, config, and dependencies. Investigating, measuring, reading, and
running the probe do not need permission — only changes do.

## Verification

There is **no `swift test`**. This machine has Command Line Tools only, where
neither `XCTest` nor `swift-testing` exists. Checks are an assert-based
executable:

```bash
swift build            # must be clean, zero warnings
swift run XFlowChecks  # must report zero failures
./build.sh debug       # assemble and sign the .app
```

Never run `swift run XFlow` — that produces an unbundled process with no
`Info.plist`, so no bundle identifier, no microphone usage string, and no stable
signature. Always launch `build/XFlow.app`.

Reading logs needs the absolute path, because `log` is shadowed in this user's
shell profile:

```bash
/usr/bin/log show --last 20m --predicate 'subsystem == "com.aamirhannan.xflow"'
```

## Testing transcription changes

Do not ask the user to dictate and read logs. Run the probe against audio files:

```bash
GROQ_API_KEY=... OPENAI_API_KEY=... swift run XFlowChecks --probe clip.m4a
```

It runs the shipped request builders and the shipped verification, printing every
stage. **Repeat language-behaviour tests at least six times** — several failures
here occur at a 50% rate and a single run cannot see them.

## Hard rules, each learned from a real bug

These are enforced by checks. Do not "simplify" them away.

- **Never send `language` on a transcription request.** With `language=en`
  Whisper translated and summarised instead of transcribing. With `language=hi`
  it wrote the speaker's English in Devanagari.
- **Never put the vocabulary prompt on a transcription request.** Those English
  terms bias language detection: mixed Hindi/English speech survived 3 of 6 runs
  with it, 6 of 6 without. Vocabulary belongs on the cleanup call.
- **A fresh `URLSession` per dictation.** Pooled HTTP/3 connections die silently
  when the NAT drops the UDP mapping, and requests hang until timeout.
- **Timeouts are never retried.** Retrying one turned a 30s stall into 62s.
- **An empty cleanup response is a failure, not a result.** Treating it as
  success silently deleted whole segments from the transcript.
- **The cleanup prompt keeps its `<transcript>` delimiter and worked examples.**
  Without them the model answers the speaker instead of transcribing them.
- **The API key lives in Keychain only.** This repository is public.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/XFlowCore/` | Pure logic, no OS dependencies. Everything checkable. |
| `Sources/XFlow/` | The AppKit app: hotkey, audio, network, UI, paste. |
| `Sources/XFlowChecks/` | Assert-based checks and the `--probe` harness. |
| `notes/` | Current architecture, version history, and measured findings. **Read these first.** |
| `docs/superpowers/` | Point-in-time specs and plans. Historical: never updated, and partly superseded. |

Keep `ponytail:` comments accurate — each names a deliberate shortcut and the
condition under which to upgrade it. Two have already come due.
