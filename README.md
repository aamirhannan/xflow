# XFlow

Hold `fn`, speak, release. The text lands in whatever field your cursor is in.

A ~1,500-line macOS menu-bar app that replaces the $29/month dictation tools with
your own Groq key, for a few rupees an hour. Speech is transcribed by
`whisper-large-v3-turbo`, then formatted by `openai/gpt-oss-20b` — which also
transliterates Hindi/Urdu into Latin script, so spoken Hinglish comes out as
"mujhe yeh chahiye" rather than Devanagari.

No dashboard, no analytics, no history. Just the loop.

## Requirements

macOS 14 or later, Xcode Command Line Tools, and a Groq API key from
[console.groq.com/keys](https://console.groq.com/keys).

Full Xcode is not required. This project has no `swift test` target for exactly
that reason — see [Development](#development).

## Build

macOS binds every permission grant to an app's code signature. An unsigned build
gets a new signature on every compile, so the OS treats each build as a brand-new
app and makes you re-approve Accessibility every single time. A stable
self-signed certificate fixes that, and costs nothing:

```bash
# One-time, in Keychain Access:
#   Keychain Access > Certificate Assistant > Create a Certificate…
#     Name:            XFlow Dev
#     Identity Type:   Self Signed Root
#     Certificate Type: Code Signing
#
# Or from the terminal:
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=XFlow Dev" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -out dev.p12 -inkey key.pem -in cert.pem -passout pass:xflow \
  -name "XFlow Dev" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import dev.p12 -k ~/Library/Keychains/login.keychain-db -P xflow -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
rm key.pem cert.pem dev.p12
```

Then:

```bash
./build.sh
open build/XFlow.app
```

`build.sh` warns and falls back to an ad-hoc signature if the identity is
missing, so it always produces a runnable app — you just get the permission
churn. Set `XFLOW_SIGN_IDENTITY` to use a different identity.

Handing the `.app` to someone else needs a paid Apple Developer ID and
notarization, which this project does not do.

## Setup

The setup window opens on first launch. Four things:

| Item | Why |
| --- | --- |
| **Microphone** | To record |
| **Accessibility** | To send the paste keystroke to other apps |
| **Input Monitoring** | To see the `fn` key while other apps are focused |
| **Keyboard → "Press 🌐 key to" → Do Nothing** | Otherwise `fn` also opens the emoji picker |

Then paste your Groq key (`gsk_…`) from
[console.groq.com/keys](https://console.groq.com/keys). It is stored in your
macOS Keychain and never written to disk or to this repository.

The same window has a **Vocabulary** field, pre-filled with a default set of
terms. Edit it to match your own jargon — names, acronyms, product words. It is
the highest-leverage accuracy knob in the app; see
[Why these exact settings](#why-these-exact-settings).

If you used v1 with an OpenAI key, nothing needs cleaning up by hand. Groq keys
live under their own Keychain account, so the old key is ignored rather than
sent to the wrong host, and the stale `sttModel`/`cleanupModel` defaults are
cleared once on first launch.

## Use

Hold `fn`. Speak. Release. Text appears.

The menu bar icon turns red while recording. If the paste is ever blocked, the
transcript is left on your clipboard and you get a notification — you never lose
what you said.

Long dictations are transcribed while you are still speaking: the recorder cuts
a segment at each natural pause and sends it immediately, so the wait after
releasing `fn` does not grow with how long you spoke. Turn it off with
**Transcribe while speaking** in the menu bar to fall back to the single-shot
path.

## Cost

`whisper-large-v3-turbo` is $0.04/hour of audio and `openai/gpt-oss-20b` costs
fractions of a cent per dictation — roughly ₹4/hour, and plausibly ₹0 inside
Groq's free tier of 2,000 requests/day. Groq bills a 10-second minimum per
request, which is why segments are never shorter than that.

Settings, all editable from the menu bar or with `defaults write com.aamirhannan.xflow`:
`sttModel`, `cleanupModel`, `vocabulary`, `cleanupEnabled`, `segmentingEnabled`.

## Why these exact settings

Benchmarked on a real 4-minute Hinglish recording rather than published word
error rates, which are almost entirely English-only:

| | Groq turbo | Groq turbo + vocabulary | OpenAI gpt-4o-transcribe |
| --- | --- | --- | --- |
| "risk owner" | `response और` | ✅ | ✅ |
| SOX | `शॉक्स` | ✅ | `सॉक्स` |
| RBAC | `आरबैक` | ✅ mostly | `आरबैक` |
| 42s clip | 1.00s | **0.71s** | 3.01s |
| 4min clip | 1.55s | — | 11.04s |

Two traps found the hard way:

- **The vocabulary prompt helps Groq and hurts OpenAI.** The same parameter that
  fixes Groq's acronyms pushed `gpt-4o-transcribe` into romanizing everything
  into Devanagari. It is sent on the transcription call only, never on cleanup.
- **Never send `language=en`.** Whisper stops transcribing and starts
  translating and summarising, losing most of the content. Auto-detection is the
  only correct setting, and a check in `XFlowChecks` fails if a `language` field
  ever reappears in the request body.
- `whisper-large-v3` is worse than `turbo` here *and* returned HTTP 500 three
  times on a 983KB file. The cheaper model is the better one for this workload.

## Development

```bash
swift build             # type-check everything
swift run XFlowChecks   # assert-based checks over XFlowCore
./build.sh debug        # assemble and sign the .app
```

`XFlowCore` holds everything testable without the OS: the session state machine,
multipart encoding, Groq request/response handling, the vocabulary prompt, the
silence detector, the segment policy, the transcript assembler, and the
clipboard swap. `XFlow` holds the parts only a running app can exercise.

There is no `swift test`. Xcode Command Line Tools ship neither `XCTest` nor
`swift-testing`, so `swift test` cannot run without a full 10GB Xcode install.
`XFlowChecks` is a plain executable of asserts that gives the same red-green
cycle with zero frameworks. Convert it to a real `.testTarget` if you install
Xcode and want one.

Do not run `swift run XFlow`. That produces an unbundled process with no
`Info.plist`, so it has no bundle identifier, no microphone usage string, and no
stable signature. Always launch `build/XFlow.app`.

Timings and segment boundaries are logged to the unified log:

```bash
/usr/bin/log show --last 20m --predicate 'subsystem == "com.aamirhannan.xflow"' | grep -E "200 in|segment"
```

Use the absolute `/usr/bin/log`. A bare `log` is shadowed by a shell function in
some profiles, and you get a confusing "no matching processes" instead of the
log.

### Manual smoke checklist

The OS-level behaviour cannot be unit tested. Run this before any release:

- [ ] Dictate into Chrome's address bar — text appears
- [ ] Dictate into VS Code — text appears
- [ ] Dictate a Hinglish sentence — output is Latin script, not Devanagari
- [ ] Say RBAC, SOX and "risk owner" — all three come back correctly spelled
- [ ] Focus a password field and hold `fn` — pill refuses, nothing is recorded
- [ ] Turn Wi-Fi off and dictate — error on the pill, no crash, no stuck state
- [ ] Revoke Accessibility and dictate — notification says the text is on the clipboard
- [ ] Tap `fn` briefly — nothing happens and no API call is made
- [ ] Hold `fn` for over two minutes — recording auto-stops and transcribes
- [ ] Paste into the API key field with ⌘V — works (an accessory app needs an explicit Edit menu for this)
- [ ] Dictate 3 minutes with pauses — no word lost or duplicated at a segment boundary
- [ ] A 150s dictation feels no slower to finish than a 20s one
- [ ] Speak 40s with no pause — force-close still produces complete text
- [ ] Drop the network mid-dictation — the whole-audio fallback recovers it
- [ ] Turn off "Transcribe while speaking" — single-shot still works

## Known limits

- Clipboard restore is plain text only: copy an image, dictate, and the image is
  gone from your clipboard.
- App Sandbox is off by necessity — a sandboxed app cannot paste into other
  apps — so this can never ship on the Mac App Store.
- The `fn` key is not configurable yet.

## License

MIT
