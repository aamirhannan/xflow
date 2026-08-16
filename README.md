# XFlow

Hold `fn`, speak, release. The text lands in whatever field your cursor is in.

A 1,100-line macOS menu-bar app that replaces the $29/month dictation tools with
your own OpenAI key, for a few dollars a month. Speech is transcribed by
`gpt-4o-transcribe`, then cleaned up by `gpt-4o-mini` — which also transliterates
Hindi/Urdu into Latin script, so spoken Hinglish comes out as "mujhe yeh chahiye"
rather than Devanagari.

No dashboard, no analytics, no history. Just the loop.

## Requirements

macOS 14 or later, Xcode Command Line Tools, and an OpenAI API key.

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

Then paste your OpenAI key. It is stored in your macOS Keychain and never
written to disk or to this repository.

## Use

Hold `fn`. Speak. Release. Text appears.

The menu bar icon turns red while recording. If the paste is ever blocked, the
transcript is left on your clipboard and you get a notification — you never lose
what you said.

## Cost

Roughly $0.006 per minute of audio, plus a fraction of a cent for the cleanup
pass. About $2–5/month at real dictation volume. Switch to the cheaper
transcription model to roughly halve it:

```bash
defaults write com.aamirhannan.xflow sttModel -string "gpt-4o-mini-transcribe"
```

Other settings: `cleanupModel` (default `gpt-4o-mini`) and `cleanupEnabled`
(also togglable from the menu bar).

## Development

```bash
swift build             # type-check everything
swift run XFlowChecks   # assert-based checks over XFlowCore
./build.sh debug        # assemble and sign the .app
```

`XFlowCore` holds everything testable without the OS: the session state machine,
multipart encoding, OpenAI request/response handling, and the clipboard swap.
`XFlow` holds the parts only a running app can exercise.

There is no `swift test`. Xcode Command Line Tools ship neither `XCTest` nor
`swift-testing`, so `swift test` cannot run without a full 10GB Xcode install.
`XFlowChecks` is a plain executable of asserts that gives the same red-green
cycle with zero frameworks. Convert it to a real `.testTarget` if you install
Xcode and want one.

Do not run `swift run XFlow`. That produces an unbundled process with no
`Info.plist`, so it has no bundle identifier, no microphone usage string, and no
stable signature. Always launch `build/XFlow.app`.

### Manual smoke checklist

The OS-level behaviour cannot be unit tested. Run this before any release:

- [ ] Dictate into Chrome's address bar — text appears
- [ ] Dictate into VS Code — text appears
- [ ] Dictate a Hinglish sentence — output is Latin script, not Devanagari
- [ ] Focus a password field and hold `fn` — pill refuses, nothing is recorded
- [ ] Turn Wi-Fi off and dictate — error on the pill, no crash, no stuck state
- [ ] Revoke Accessibility and dictate — notification says the text is on the clipboard
- [ ] Tap `fn` briefly — nothing happens and no API call is made
- [ ] Hold `fn` for over two minutes — recording auto-stops and transcribes
- [ ] Paste into the API key field with ⌘V — works (an accessory app needs an explicit Edit menu for this)

## Known limits

- Clipboard restore is plain text only: copy an image, dictate, and the image is
  gone from your clipboard.
- App Sandbox is off by necessity — a sandboxed app cannot paste into other
  apps — so this can never ship on the Mac App Store.
- The `fn` key is not configurable yet.

## License

MIT
