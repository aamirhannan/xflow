# XFlow v2 Implementation Plan — Groq + silence-based segmentation

> **Historical document.** This records what was planned on the date above and is
> not updated. Several decisions here have since been reversed by measurement.
> For how the app works today, see [`notes/0001-architecture.md`](../../../notes/0001-architecture.md);
> for why it changed, [`notes/0002-versions.md`](../../../notes/0002-versions.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move both API legs to Groq with a vocabulary prompt, then transcribe during the recording so the wait after releasing `fn` stops growing with how long you spoke.

**Architecture:** Phase 1 replaces the OpenAI endpoints with Groq's OpenAI-compatible ones and adds the vocabulary prompt that made Groq win the benchmark — a small, measurable change. Phase 2 replaces `AVAudioRecorder` with `AVAudioEngine`, detects pauses from the RMS signal already computed for the waveform, and pipelines each closed segment through transcription and cleanup while the user is still speaking.

**Tech Stack:** Swift 6 (language mode 5), SwiftPM, AppKit, AVFoundation, Groq HTTP APIs.

## Global Constraints

- **Groq only.** OpenAI is removed entirely. No provider protocol, no factory, no failover — one implementation.
- **STT model is `whisper-large-v3-turbo`.** Not `whisper-large-v3`, which benchmarked worse on Hinglish and returned HTTP 500 three times on a 983KB file.
- **Cleanup model is `openai/gpt-oss-20b`** (a Groq-hosted model whose ID happens to carry an `openai/` prefix; it is not an OpenAI API call).
- **Never send a `language` parameter.** With `language=en`, Whisper translated and summarized instead of transcribing and lost most of the content. This must be covered by a check, not just a comment.
- **The vocabulary prompt is sent on transcription only**, never on the cleanup call.
- **Minimum segment length is 10s**, matching Groq's minimum billed duration exactly, so segmenting costs nothing extra.
- **No third-party dependencies.** Foundation, AppKit, AVFoundation, IOKit, Security only.
- **There is no `swift test`.** Checks live in the `XFlowChecks` executable, run with `swift run XFlowChecks`. Each check group is a file exposing a top-level `check<Thing>()` function, called from `Sources/XFlowChecks/main.swift`. Check files `import XFlowCore`, so anything exercised must be `public`.
- **Every failure degrades toward "text is on the clipboard"**, never toward lost words.
- **Deliberate simplifications carry a `ponytail:` comment** naming the ceiling and the upgrade path.
- **Phase 1 must be measured before Phase 2 is started.** Task 6 is a hard gate.

---

# Phase 1 — Groq provider swap

## Task 1: Groq request builders

**Files:**
- Create: `Sources/XFlowCore/Groq.swift`
- Delete: `Sources/XFlowCore/OpenAI.swift`
- Create: `Sources/XFlowChecks/GroqChecks.swift`
- Delete: `Sources/XFlowChecks/OpenAIChecks.swift`
- Modify: `Sources/XFlowChecks/main.swift`

**Interfaces:**
- Consumes: `MultipartBody`, `XFlowError`, `CleanupPrompt`
- Produces: `Groq.transcriptionURL`, `Groq.chatURL`, `Groq.defaultSTTModel`, `Groq.defaultCleanupModel`, `Groq.transcriptionRequest(apiKey:model:audio:filename:vocabulary:boundary:) -> URLRequest`, `Groq.cleanupRequest(apiKey:model:transcript:) -> URLRequest`, `Groq.decodeTranscript(_:) throws -> String`, `Groq.decodeCleanup(_:) throws -> String`

- [ ] **Step 1: Write the failing checks**

`Sources/XFlowChecks/GroqChecks.swift`:

```swift
import Foundation
import XFlowCore

func checkGroq() {
    let audio = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let request = Groq.transcriptionRequest(
        apiKey: "gsk-test", model: Groq.defaultSTTModel,
        audio: audio, filename: "clip.m4a",
        vocabulary: "RBAC, SOX", boundary: "B"
    )

    Checks.equal(request.url?.absoluteString,
                 "https://api.groq.com/openai/v1/audio/transcriptions",
                 "transcription targets the groq endpoint")
    Checks.equal(request.httpMethod, "POST", "transcription is a POST")
    Checks.equal(request.value(forHTTPHeaderField: "Authorization"), "Bearer gsk-test",
                 "transcription carries the bearer token")
    Checks.equal(Groq.defaultSTTModel, "whisper-large-v3-turbo", "stt model is turbo")
    Checks.equal(Groq.defaultCleanupModel, "openai/gpt-oss-20b", "cleanup model is gpt-oss-20b")

    let body = String(data: request.httpBody!, encoding: .isoLatin1)!
    Checks.check(request.httpBody!.range(of: audio) != nil, "body carries the audio bytes")
    Checks.check(body.contains("whisper-large-v3-turbo"), "body names the model")
    Checks.check(body.contains("name=\"prompt\""), "body carries the vocabulary prompt")
    Checks.check(body.contains("RBAC, SOX"), "body carries the vocabulary terms")

    // Regression guard. With language=en, Whisper translated and summarised
    // instead of transcribing and lost most of the content. It must never be sent.
    Checks.check(!body.contains("name=\"language\""), "transcription never sends a language field")

    let noVocab = Groq.transcriptionRequest(
        apiKey: "gsk-test", model: Groq.defaultSTTModel,
        audio: audio, filename: "clip.m4a", vocabulary: "   ", boundary: "B"
    )
    let noVocabBody = String(data: noVocab.httpBody!, encoding: .isoLatin1)!
    Checks.check(!noVocabBody.contains("name=\"prompt\""),
                 "blank vocabulary omits the prompt field entirely")

    let cleanup = Groq.cleanupRequest(
        apiKey: "gsk-test", model: Groq.defaultCleanupModel, transcript: "hello there"
    )
    Checks.equal(cleanup.url?.absoluteString,
                 "https://api.groq.com/openai/v1/chat/completions",
                 "cleanup targets the groq chat endpoint")

    let json = try! JSONSerialization.jsonObject(with: cleanup.httpBody!) as! [String: Any]
    Checks.equal(json["model"] as? String, "openai/gpt-oss-20b", "cleanup names the model")
    Checks.equal(json["temperature"] as? Double, 0, "cleanup runs at temperature zero")
    let messages = json["messages"] as! [[String: String]]
    Checks.equal(messages.count, 2, "cleanup sends exactly two messages")
    Checks.equal(messages[0]["content"], CleanupPrompt.system, "system message is the cleanup prompt")
    Checks.equal(messages[1]["content"], "hello there", "user message is the transcript")

    Checks.equal(try? Groq.decodeTranscript(Data(#"{"text":"  mujhe yeh chahiye  "}"#.utf8)),
                 "mujhe yeh chahiye", "transcript is decoded and trimmed")
    Checks.throwsError(XFlowError.emptyTranscript, "blank transcript is an empty transcript error") {
        _ = try Groq.decodeTranscript(Data(#"{"text":"   "}"#.utf8))
    }
    Checks.throwsError(XFlowError.decoding, "malformed transcript body is a decoding error") {
        _ = try Groq.decodeTranscript(Data("not json".utf8))
    }
    Checks.equal(try? Groq.decodeCleanup(Data(#"{"choices":[{"message":{"content":"Mujhe yeh chahiye.\n"}}]}"#.utf8)),
                 "Mujhe yeh chahiye.", "cleanup response is decoded and trimmed")
    Checks.throwsError(XFlowError.decoding, "cleanup with no choices is a decoding error") {
        _ = try Groq.decodeCleanup(Data(#"{"choices":[]}"#.utf8))
    }
}
```

In `Sources/XFlowChecks/main.swift`, replace the line `checkOpenAI()` with `checkGroq()`.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift run XFlowChecks`
Expected: FAIL — `cannot find 'Groq' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/XFlowCore/Groq.swift`:

```swift
import Foundation

/// Request construction and response decoding only. No URLSession here, so all
/// of it is checkable without a network or a mock server.
///
/// Groq's endpoints are OpenAI-compatible in shape, which is why the request
/// bodies look familiar. `openai/gpt-oss-20b` is a Groq-hosted model whose ID
/// carries an `openai/` prefix — it is not a call to OpenAI.
public enum Groq {
    public static let transcriptionURL =
        URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    public static let chatURL =
        URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    /// Benchmarked on real Hinglish speech: turbo beat both whisper-large-v3 and
    /// gpt-4o-transcribe on accuracy, at 15x the speed of the latter.
    /// whisper-large-v3 also returned HTTP 500 repeatedly on a 983KB file.
    public static let defaultSTTModel = "whisper-large-v3-turbo"
    /// 1000 tokens/sec, which turns a 4.11s cleanup into roughly 0.4s.
    public static let defaultCleanupModel = "openai/gpt-oss-20b"

    public static func transcriptionRequest(
        apiKey: String,
        model: String,
        audio: Data,
        filename: String,
        vocabulary: String,
        boundary: String = "xflow-\(UUID().uuidString)"
    ) -> URLRequest {
        var body = MultipartBody(boundary: boundary)
        body.addField(name: "model", value: model)

        // The vocabulary prompt is what makes Groq win: without it "risk owner"
        // came back as "response और" and SOX as "शॉक्स". Sent only when it has
        // content — an empty prompt field is worse than no prompt field.
        let terms = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty { body.addField(name: "prompt", value: terms) }

        // NO `language` FIELD. EVER. With language=en, Whisper stopped
        // transcribing and started translating and summarising, destroying most
        // of the content. Auto-detection is the only correct setting here.

        body.addFile(name: "file", filename: filename, contentType: "audio/m4a", data: audio)

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finished
        return request
    }

    public static func cleanupRequest(apiKey: String, model: String, transcript: String) -> URLRequest {
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": CleanupPrompt.system],
                ["role": "user", "content": transcript],
            ],
        ]

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    public static func decodeTranscript(_ data: Data) throws -> String {
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw XFlowError.decoding
        }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw XFlowError.emptyTranscript }
        return text
    }

    public static func decodeCleanup(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let content = response.choices.first?.message.content
        else { throw XFlowError.decoding }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Delete the OpenAI files**

```bash
rm Sources/XFlowCore/OpenAI.swift Sources/XFlowChecks/OpenAIChecks.swift
```

- [ ] **Step 5: Run the checks to verify they pass**

Run: `swift build && swift run XFlowChecks`
Expected: build fails first — `Transcriber.swift` still references `OpenAI`. That is expected and fixed in Task 3. To check this task in isolation, run `swift run XFlowChecks` only after Task 3. If you are executing tasks strictly in order, proceed to Task 2 and Task 3, then run.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/XFlowCore Sources/XFlowChecks
git commit -m "feat: groq request builders with vocabulary prompt"
```

---

## Task 2: Vocabulary prompt setting

**Files:**
- Create: `Sources/XFlowCore/VocabularyPrompt.swift`
- Modify: `Sources/XFlow/Settings.swift`
- Create: `Sources/XFlowChecks/VocabularyPromptChecks.swift`
- Modify: `Sources/XFlowChecks/main.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `VocabularyPrompt.default: String`; `Settings.vocabulary: String` (get/set), `Settings.sttModel`, `Settings.cleanupModel` defaults changed

- [ ] **Step 1: Write the failing checks**

`Sources/XFlowChecks/VocabularyPromptChecks.swift`:

```swift
import XFlowCore

func checkVocabularyPrompt() {
    let terms = VocabularyPrompt.default

    Checks.check(!terms.isEmpty, "a default vocabulary ships with the app")
    // These are the exact terms the benchmark showed being mangled without it.
    Checks.check(terms.contains("RBAC"), "default vocabulary includes RBAC")
    Checks.check(terms.contains("SOX"), "default vocabulary includes SOX")
    Checks.check(terms.contains("risk owner"), "default vocabulary includes risk owner")
    // A prompt is a bias, not a dictionary — an enormous one degrades results.
    Checks.check(terms.count < 900, "default vocabulary stays short enough to bias, not dominate")
}
```

Add `checkVocabularyPrompt()` to `Sources/XFlowChecks/main.swift`.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift run XFlowChecks`
Expected: FAIL — `cannot find 'VocabularyPrompt' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/XFlowCore/VocabularyPrompt.swift`:

```swift
public enum VocabularyPrompt {
    /// Seeded from the terms that were provably mangled without it: RBAC came
    /// back as "आरबैक", SOX as "शॉक्स", and "risk owner" as "response और".
    /// Users should edit this to match their own jargon — it is the highest
    /// leverage accuracy knob in the app.
    public static let `default` = """
    RBAC, SOX, RACM, risk owner, auditor, engagement, control, internal audit, \
    super admin, screen, scope, dashboard, workflow, compliance
    """
}
```

In `Sources/XFlow/Settings.swift`, add the vocabulary accessor and change the two model defaults:

```swift
    static var sttModel: String {
        get { defaults.string(forKey: "sttModel") ?? Groq.defaultSTTModel }
        set { defaults.set(newValue, forKey: "sttModel") }
    }

    static var cleanupModel: String {
        get { defaults.string(forKey: "cleanupModel") ?? Groq.defaultCleanupModel }
        set { defaults.set(newValue, forKey: "cleanupModel") }
    }

    /// Terms biased into the transcription request. Editable in settings.
    static var vocabulary: String {
        get { defaults.string(forKey: "vocabulary") ?? VocabularyPrompt.default }
        set { defaults.set(newValue, forKey: "vocabulary") }
    }
```

Add `import XFlowCore` to the top of `Settings.swift`.

Existing installs have `sttModel` already set to `gpt-4o-transcribe` in UserDefaults, which would silently keep pointing at a model Groq does not host. Clear the stale values once, at the top of `Settings`:

```swift
    /// One-time migration: v1 stored OpenAI model names, which Groq does not
    /// host. Clearing them lets the new defaults apply.
    static func migrateFromV1() {
        guard defaults.object(forKey: "didMigrateToGroq") == nil else { return }
        defaults.removeObject(forKey: "sttModel")
        defaults.removeObject(forKey: "cleanupModel")
        defaults.set(true, forKey: "didMigrateToGroq")
    }
```

- [ ] **Step 4: Run the checks to verify they pass**

Run: `swift run XFlowChecks` (after Task 3 makes the package build)
Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/XFlowCore/VocabularyPrompt.swift Sources/XFlow/Settings.swift Sources/XFlowChecks
git commit -m "feat: editable vocabulary prompt with groq model defaults"
```

---

## Task 3: Point the transcriber and Keychain at Groq

**Files:**
- Modify: `Sources/XFlow/Transcriber.swift`
- Modify: `Sources/XFlow/Keychain.swift`
- Modify: `Sources/XFlow/AppDelegate.swift`

**Interfaces:**
- Consumes: `Groq` (Task 1), `Settings.vocabulary` (Task 2)
- Produces: `Keychain.apiKey` now reads account `groq`; `Transcriber.transcribe(fileURL:) async throws -> String` unchanged in signature

- [ ] **Step 1: Switch the Keychain account**

In `Sources/XFlow/Keychain.swift`, change the account constant:

```swift
    private static let service = "com.aamirhannan.xflow"
    // v1 stored an OpenAI key under "openai". Groq keys live under their own
    // account, so an old key is simply ignored rather than sent to the wrong host.
    private static let account = "groq"
```

- [ ] **Step 2: Switch the transcriber to Groq**

In `Sources/XFlow/Transcriber.swift`, replace the two request-building calls. The transcription call gains the vocabulary argument:

```swift
        let transcript = try await send(
            Groq.transcriptionRequest(
                apiKey: apiKey,
                model: Settings.sttModel,
                audio: audio,
                filename: fileURL.lastPathComponent,
                vocabulary: Settings.vocabulary
            ),
            on: session,
            decode: Groq.decodeTranscript
        )
```

and the cleanup call:

```swift
            return try await send(
                Groq.cleanupRequest(
                    apiKey: apiKey,
                    model: Settings.cleanupModel,
                    transcript: transcript
                ),
                on: session,
                decode: Groq.decodeCleanup
            )
```

- [ ] **Step 3: Run the migration at launch**

In `Sources/XFlow/AppDelegate.swift`, add the migration call as the first line of `applicationDidFinishLaunching`:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.migrateFromV1()
        preventAppNap()
        installEditMenu()
```

- [ ] **Step 4: Verify the package builds and all checks pass**

Run: `swift build && swift run XFlowChecks`
Expected: build succeeds with no warnings; all checks pass with no failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/XFlow/Transcriber.swift Sources/XFlow/Keychain.swift Sources/XFlow/AppDelegate.swift
git commit -m "feat: route both api legs through groq"
```

---

## Task 4: Groq key and vocabulary in the settings window

**Files:**
- Modify: `Sources/XFlow/PermissionsWindow.swift`

**Interfaces:**
- Consumes: `Keychain.apiKey`, `Settings.vocabulary`
- Produces: no new public API

- [ ] **Step 1: Relabel the key field**

In `Sources/XFlow/PermissionsWindow.swift`, change the API key heading and placeholder:

```swift
        stack.addArrangedSubview(heading("Groq API key"))

        keyField.placeholderString = "gsk_…"
```

and change the caption below the save button:

```swift
        stack.addArrangedSubview(caption("Stored in your macOS Keychain, never on disk. Get one at console.groq.com/keys"))
```

- [ ] **Step 2: Add the vocabulary field**

Add a stored property alongside `keyField`:

```swift
    private let vocabularyField = NSTextField()
```

Then, after the API key section in `init`, add:

```swift
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Vocabulary"))

        vocabularyField.stringValue = Settings.vocabulary
        vocabularyField.target = self
        vocabularyField.action = #selector(saveVocabulary)
        vocabularyField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.addArrangedSubview(vocabularyField)

        let saveVocab = NSButton(title: "Save vocabulary", target: self, action: #selector(saveVocabulary))
        stack.addArrangedSubview(saveVocab)

        stack.addArrangedSubview(caption(
            "Names and acronyms you say often. This is the biggest accuracy lever in the app: "
            + "without it, RBAC came back as आरबैक and \"risk owner\" as \"response और\"."
        ))
```

And the action:

```swift
    @objc private func saveVocabulary() {
        Settings.vocabulary = vocabularyField.stringValue
    }
```

Finally, widen the window so the new rows fit — change the `contentRect` height in `init` from `360` to `520`.

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: build succeeds with no warnings.

- [ ] **Step 4: Build the app and confirm the window**

Run: `./build.sh debug && open build/XFlow.app`
Expected: the setup window shows a "Groq API key" field with a `gsk_…` placeholder and a "Vocabulary" field pre-filled with the default terms.

- [ ] **Step 5: Commit**

```bash
git add Sources/XFlow/PermissionsWindow.swift
git commit -m "feat: groq key and vocabulary fields in settings"
```

---

## Task 5: Update the docs for Groq

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite the requirements and cost sections**

In `README.md`, replace the OpenAI mentions. The intro paragraph becomes:

```markdown
A 1,100-line macOS menu-bar app that replaces the $29/month dictation tools with
your own Groq key, for a few rupees an hour. Speech is transcribed by
`whisper-large-v3-turbo`, then formatted by `openai/gpt-oss-20b` — which also
transliterates Hindi/Urdu into Latin script, so spoken Hinglish comes out as
"mujhe yeh chahiye" rather than Devanagari.
```

Replace the Requirements line with:

```markdown
macOS 14 or later, Xcode Command Line Tools, and a Groq API key from
[console.groq.com/keys](https://console.groq.com/keys).
```

Replace the whole Cost section with:

```markdown
## Cost

`whisper-large-v3-turbo` is $0.04/hour of audio and `openai/gpt-oss-20b` costs
fractions of a cent per dictation — roughly ₹4/hour, and plausibly ₹0 inside
Groq's free tier of 2,000 requests/day. Groq bills a 10-second minimum per
request, which is why segments are never shorter than that.

Settings, all editable from the menu bar or with `defaults write com.aamirhannan.xflow`:
`sttModel`, `cleanupModel`, `vocabulary`, `cleanupEnabled`.
```

- [ ] **Step 2: Document the two traps**

Add a new section before Known limits:

```markdown
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
  into Devanagari.
- **Never send `language=en`.** Whisper stops transcribing and starts
  translating and summarising, losing most of the content.
- `whisper-large-v3` is worse than `turbo` here *and* returned HTTP 500 three
  times on a 983KB file. The cheaper model is the better one for this workload.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: groq setup, cost, and the benchmark that chose these settings"
```

---

## Task 6: Measure Phase 1 — HARD GATE

**Files:** none

This task writes no code. Its output is a decision.

- [ ] **Step 1: Enter a Groq key and dictate**

Build and launch (`./build.sh debug && open build/XFlow.app`), paste a Groq key from console.groq.com/keys, and dictate four times: roughly 12s, 25s, 65s and 126s of mixed Hindi and English.

- [ ] **Step 2: Read the measured latencies**

Run: `/usr/bin/log show --last 20m --predicate 'subsystem == "com.aamirhannan.xflow"' | grep "200 in"`

Note the shell alias trap: `log` is shadowed in this user's profile, so the absolute path is required.

Record STT and cleanup times against the v1 baseline:

| Audio | v1 total | v2 Phase 1 total |
| --- | --- | --- |
| ~12s | 1.96s | ? |
| ~25s | 2.30s | ? |
| ~65s | 6.31s | ? |
| ~126s | 9.56s | ? |

- [ ] **Step 3: Check accuracy on real usage**

Dictate a passage containing RBAC, SOX and "risk owner". Confirm they appear correctly and that English words stay in Latin script.

- [ ] **Step 4: Decide whether Phase 2 is worth building**

The design projects Phase 1 at roughly 1.8s for a 126s dictation and Phase 2 at roughly 1.2s. **If the measured Phase 1 numbers are already acceptable, stop here.** Phase 2 costs an audio-engine rewrite, a silence detector to tune, and concurrent-segment ordering, to buy roughly 0.6s on long dictations only.

Record the decision in the commit message and continue only on a yes.

- [ ] **Step 5: Commit the measurements**

```bash
git commit --allow-empty -m "measure: phase 1 latency on groq, and the phase 2 decision"
```

---

# Phase 2 — Silence-based segmentation

Build only if Task 6 said yes.

## Task 7: Silence detector

**Files:**
- Create: `Sources/XFlowCore/SilenceDetector.swift`
- Create: `Sources/XFlowChecks/SilenceDetectorChecks.swift`
- Modify: `Sources/XFlowChecks/main.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `SilenceDetector(pauseDuration:sensitivity:initialFloor:)`, `mutating func feed(rms: Float, at: TimeInterval) -> Bool`, `var noiseFloor: Float`

- [ ] **Step 1: Write the failing checks**

`Sources/XFlowChecks/SilenceDetectorChecks.swift`:

```swift
import Foundation
import XFlowCore

func checkSilenceDetector() {
    // Speech at 0.5 RMS, then quiet at 0.005. A pause is confirmed only after
    // 600ms of continuous quiet, and only reported once.
    var detector = SilenceDetector(pauseDuration: 0.6, sensitivity: 3, initialFloor: 0.01)

    var firedDuringSpeech = false
    for i in 0..<20 {
        if detector.feed(rms: 0.5, at: Double(i) * 0.05) { firedDuringSpeech = true }
    }
    Checks.equal(firedDuringSpeech, false, "speech never reports a pause")

    var fireTimes: [Double] = []
    for i in 20..<60 {
        let t = Double(i) * 0.05
        if detector.feed(rms: 0.005, at: t) { fireTimes.append(t) }
    }
    Checks.equal(fireTimes.count, 1, "a pause is reported exactly once, not every sample")
    if let first = fireTimes.first {
        // Quiet began at 1.00s, so confirmation lands at 1.60s give or take a sample.
        Checks.check(first >= 1.55 && first <= 1.70,
                     "pause confirms after the configured 600ms, not sooner")
    }

    // A short gap between words must not be mistaken for a pause.
    var shortGap = SilenceDetector(pauseDuration: 0.6, sensitivity: 3, initialFloor: 0.01)
    for i in 0..<20 { _ = shortGap.feed(rms: 0.5, at: Double(i) * 0.05) }
    var firedOnShortGap = false
    for i in 20..<26 {  // 300ms of quiet only
        if shortGap.feed(rms: 0.005, at: Double(i) * 0.05) { firedOnShortGap = true }
    }
    Checks.equal(firedOnShortGap, false, "a 300ms gap is not a pause")

    // Resuming speech re-arms the detector for the next pause.
    for i in 26..<40 { _ = shortGap.feed(rms: 0.5, at: Double(i) * 0.05) }
    var firedAfterResume = false
    for i in 40..<70 {
        if shortGap.feed(rms: 0.005, at: Double(i) * 0.05) { firedAfterResume = true }
    }
    Checks.equal(firedAfterResume, true, "the detector re-arms after speech resumes")

    // In a noisy room the floor rises, so absolute thresholds would never fire.
    var noisy = SilenceDetector(pauseDuration: 0.6, sensitivity: 3, initialFloor: 0.01)
    for i in 0..<40 { _ = noisy.feed(rms: 0.30, at: Double(i) * 0.05) }
    for i in 40..<80 { _ = noisy.feed(rms: 0.08, at: Double(i) * 0.05) }
    Checks.check(noisy.noiseFloor >= 0.01, "the noise floor adapts upward in a noisy room")
}
```

Add `checkSilenceDetector()` to `Sources/XFlowChecks/main.swift`.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift run XFlowChecks`
Expected: FAIL — `cannot find 'SilenceDetector' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/XFlowCore/SilenceDetector.swift`:

```swift
import Foundation

/// Decides when the speaker has paused, from the same RMS values that drive the
/// waveform. Cutting segments at pauses rather than at fixed intervals is what
/// keeps a word from being sliced in half — the accuracy objection that ruled
/// out naive time-based chunking.
public struct SilenceDetector {
    /// How long the level must stay down before it counts as a pause.
    public let pauseDuration: TimeInterval
    /// Silence threshold as a multiple of the observed noise floor.
    public let sensitivity: Float

    /// ponytail: the floor tracks a decaying minimum rather than running a real
    /// noise estimator. Room tone, mic gain and background chatter all move the
    /// true floor, and a fixed dB threshold is wrong on every machine. Replace
    /// with a proper VAD only if this misfires in practice.
    public private(set) var noiseFloor: Float

    private var quietSince: TimeInterval?
    private var alreadyReported = false

    public init(
        pauseDuration: TimeInterval = 0.6,
        sensitivity: Float = 3,
        initialFloor: Float = 0.01
    ) {
        self.pauseDuration = pauseDuration
        self.sensitivity = sensitivity
        self.noiseFloor = initialFloor
    }

    /// Feed one RMS sample. Returns true on the single sample where a pause
    /// becomes confirmed, and false everywhere else — including for the rest of
    /// that same pause, so a caller cannot close two segments on one silence.
    public mutating func feed(rms: Float, at time: TimeInterval) -> Bool {
        // Drift up slowly so a room that gets noisier is tracked; snap down
        // immediately so a room that goes quiet is tracked at once.
        noiseFloor = max(0.0005, min(noiseFloor * 1.0005, max(rms, 0.0005)))

        guard rms < noiseFloor * sensitivity else {
            quietSince = nil
            alreadyReported = false
            return false
        }

        guard let start = quietSince else {
            quietSince = time
            return false
        }

        guard !alreadyReported, time - start >= pauseDuration else { return false }
        alreadyReported = true
        return true
    }
}
```

- [ ] **Step 4: Run the checks to verify they pass**

Run: `swift run XFlowChecks`
Expected: all checks pass with no failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/XFlowCore/SilenceDetector.swift Sources/XFlowChecks
git commit -m "feat: adaptive silence detector for segment boundaries"
```

---

## Task 8: Segment policy

**Files:**
- Modify: `Sources/XFlowCore/SessionState.swift`
- Create: `Sources/XFlowChecks/SegmentPolicyChecks.swift`
- Modify: `Sources/XFlowChecks/main.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `SegmentPolicy.minimumDuration`, `SegmentPolicy.forceCloseAfter`, `SegmentPolicy.shouldClose(segmentDuration:pauseDetected:) -> Bool`

- [ ] **Step 1: Write the failing checks**

`Sources/XFlowChecks/SegmentPolicyChecks.swift`:

```swift
import XFlowCore

func checkSegmentPolicy() {
    // Groq bills a 10-second minimum per request, so closing earlier than that
    // pays for silence. This constant is a billing fact, not a preference.
    Checks.equal(SegmentPolicy.minimumDuration, 10, "minimum segment matches groq billing floor")
    Checks.equal(SegmentPolicy.forceCloseAfter, 30, "a segment is force-closed at 30s")

    Checks.equal(SegmentPolicy.shouldClose(segmentDuration: 12, pauseDetected: true), true,
                 "a pause past the floor closes the segment")
    Checks.equal(SegmentPolicy.shouldClose(segmentDuration: 4, pauseDetected: true), false,
                 "a pause below the floor does not close the segment")
    Checks.equal(SegmentPolicy.shouldClose(segmentDuration: 12, pauseDetected: false), false,
                 "no pause means no close while under the force limit")
    Checks.equal(SegmentPolicy.shouldClose(segmentDuration: 30, pauseDetected: false), true,
                 "a segment with no pause is force-closed at the limit")
    Checks.equal(SegmentPolicy.shouldClose(segmentDuration: 45, pauseDetected: false), true,
                 "past the force limit it still closes")
}
```

Add `checkSegmentPolicy()` to `Sources/XFlowChecks/main.swift`.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift run XFlowChecks`
Expected: FAIL — `cannot find 'SegmentPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/XFlowCore/SessionState.swift`:

```swift
public enum SegmentPolicy {
    /// Groq bills a 10-second minimum per request. Closing a segment sooner
    /// pays for silence, so this floor makes segmenting cost nothing extra.
    public static let minimumDuration: TimeInterval = 10
    /// Someone can talk for a long time without a real pause. Past this we cut
    /// anyway, otherwise the whole point of segmenting is lost.
    public static let forceCloseAfter: TimeInterval = 30

    public static func shouldClose(segmentDuration: TimeInterval, pauseDetected: Bool) -> Bool {
        if segmentDuration >= forceCloseAfter { return true }
        return pauseDetected && segmentDuration >= minimumDuration
    }
}
```

- [ ] **Step 4: Run the checks to verify they pass**

Run: `swift run XFlowChecks`
Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/XFlowCore/SessionState.swift Sources/XFlowChecks
git commit -m "feat: segment close policy pinned to groq billing floor"
```

---

## Task 9: Transcript assembler

**Files:**
- Create: `Sources/XFlowCore/TranscriptAssembler.swift`
- Create: `Sources/XFlowChecks/TranscriptAssemblerChecks.swift`
- Modify: `Sources/XFlowChecks/main.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `TranscriptAssembler()`, `mutating func store(_ text: String, at index: Int)`, `mutating func markFailed(at index: Int)`, `var failedIndices: [Int]`, `func assembled() -> String`

- [ ] **Step 1: Write the failing checks**

`Sources/XFlowChecks/TranscriptAssemblerChecks.swift`:

```swift
import XFlowCore

func checkTranscriptAssembler() {
    // Segments finish out of order because they run concurrently. Order in the
    // output must follow the index, never completion time.
    var assembler = TranscriptAssembler()
    assembler.store("second part", at: 1)
    assembler.store("first part", at: 0)
    assembler.store("third part", at: 2)
    Checks.equal(assembler.assembled(), "first part second part third part",
                 "segments assemble in index order, not completion order")

    var empty = TranscriptAssembler()
    Checks.equal(empty.assembled(), "", "nothing stored assembles to empty")
    Checks.equal(empty.failedIndices, [], "nothing stored has no failures")

    var withGap = TranscriptAssembler()
    withGap.store("zero", at: 0)
    withGap.store("two", at: 2)
    Checks.equal(withGap.assembled(), "zero two", "a missing index is skipped, not padded")

    var failing = TranscriptAssembler()
    failing.store("zero", at: 0)
    failing.markFailed(at: 1)
    failing.store("two", at: 2)
    Checks.equal(failing.failedIndices, [1], "a failed segment is tracked by index")

    // A segment that failed and was later retried successfully is no longer failed.
    failing.store("one", at: 1)
    Checks.equal(failing.failedIndices, [], "a recovered segment clears its failure")
    Checks.equal(failing.assembled(), "zero one two", "recovered text lands in the right place")

    // Blank results must not produce double spaces.
    var blanks = TranscriptAssembler()
    blanks.store("zero", at: 0)
    blanks.store("   ", at: 1)
    blanks.store("two", at: 2)
    Checks.equal(blanks.assembled(), "zero two", "blank segments do not leave gaps in the text")
}
```

Add `checkTranscriptAssembler()` to `Sources/XFlowChecks/main.swift`.

- [ ] **Step 2: Run the checks to verify they fail**

Run: `swift run XFlowChecks`
Expected: FAIL — `cannot find 'TranscriptAssembler' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/XFlowCore/TranscriptAssembler.swift`:

```swift
import Foundation

/// Collects segment transcripts that complete in any order and joins them by
/// index. Concurrency means segment 3 can land before segment 1; the reader
/// must never see that.
public struct TranscriptAssembler {
    private var pieces: [Int: String] = [:]
    private var failed: Set<Int> = []

    public init() {}

    public mutating func store(_ text: String, at index: Int) {
        pieces[index] = text
        failed.remove(index)
    }

    public mutating func markFailed(at index: Int) {
        failed.insert(index)
    }

    /// Sorted so the caller can retry deterministically.
    public var failedIndices: [Int] { failed.sorted() }

    public func assembled() -> String {
        pieces.keys.sorted()
            .compactMap { pieces[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
```

- [ ] **Step 4: Run the checks to verify they pass**

Run: `swift run XFlowChecks`
Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/XFlowCore/TranscriptAssembler.swift Sources/XFlowChecks
git commit -m "feat: order-independent transcript assembly"
```

---

## Task 10: Segmenting recorder

**Files:**
- Create: `Sources/XFlow/SegmentingRecorder.swift`
- Keep unchanged: `Sources/XFlow/Recorder.swift` (the kill switch still uses it)

**Interfaces:**
- Consumes: `SilenceDetector`, `SegmentPolicy`, `RecordingPolicy`
- Produces: `SegmentingRecorder()`, `var onLevel: (Float) -> Void`, `var onSegment: (URL, Int) -> Void`, `var onAutoStop: () -> Void`, `func start() throws`, `func stop() -> (tail: URL?, tailIndex: Int, duration: TimeInterval)?`, `func rebuildFullAudio() -> URL?`

- [ ] **Step 1: Write the implementation**

`Sources/XFlow/SegmentingRecorder.swift`:

```swift
import AVFoundation
import XFlowCore

/// Records continuously while handing completed segments to the caller mid-
/// dictation, so transcription overlaps with speaking.
///
/// This is the upgrade the `ponytail:` note in Recorder.swift predicted:
/// AVAudioRecorder cannot surface audio before it stops, so the engine is now
/// justified. Recorder.swift stays for the single-shot kill switch.
final class SegmentingRecorder {
    var onLevel: (Float) -> Void = { _ in }
    /// Called on the main queue with a finished segment file and its index.
    var onSegment: (URL, Int) -> Void = { _, _ in }
    var onAutoStop: () -> Void = {}

    private let engine = AVAudioEngine()
    private var detector = SilenceDetector()
    private var segmentFile: AVAudioFile?
    private var segmentIndex = 0
    private var segmentStart: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private var startedAt: Date?
    private var capTimer: Timer?

    /// Every buffer of the session, kept so a failed segment can be recovered by
    /// re-sending the whole recording. 120s of 24kHz mono float is ~11MB, which
    /// is cheap next to losing the user's words.
    private var sessionBuffers: [AVAudioPCMBuffer] = []

    private var outputSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        reset()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        segmentFile = try makeSegmentFile(format: format)
        startedAt = Date()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer, format: format)
        }

        engine.prepare()
        try engine.start()

        capTimer = Timer.scheduledTimer(
            withTimeInterval: RecordingPolicy.maximumDuration, repeats: false
        ) { [weak self] _ in
            self?.onAutoStop()
        }
    }

    /// Stops the engine and returns the still-unsent tail segment.
    func stop() -> (tail: URL?, tailIndex: Int, duration: TimeInterval)? {
        guard let startedAt else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        capTimer?.invalidate()
        capTimer = nil

        let tailURL = segmentFile?.url
        let index = segmentIndex
        // Releasing the file handle is what flushes and finalises the AAC container.
        segmentFile = nil
        self.startedAt = nil

        return (tailURL, index, Date().timeIntervalSince(startedAt))
    }

    /// Writes every retained buffer to one file, for the whole-audio fallback.
    func rebuildFullAudio() -> URL? {
        guard let first = sessionBuffers.first else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xflow-full-\(UUID().uuidString).m4a")
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: outputSettings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            _ = first
            for buffer in sessionBuffers { try file.write(from: buffer) }
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Internals

    private func handle(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        for i in 0..<frames { sum += channel[i] * channel[i] }
        let rms = (sum / Float(frames)).squareRoot()

        elapsed += Double(frames) / format.sampleRate

        try? segmentFile?.write(from: buffer)
        sessionBuffers.append(buffer)

        let pause = detector.feed(rms: rms, at: elapsed)
        let duration = elapsed - segmentStart

        DispatchQueue.main.async { self.onLevel(min(1, rms * 6)) }

        guard SegmentPolicy.shouldClose(segmentDuration: duration, pauseDetected: pause) else { return }
        closeSegment(format: format)
    }

    private func closeSegment(format: AVAudioFormat) {
        guard let finished = segmentFile?.url else { return }
        let index = segmentIndex

        // Dropping the reference finalises the file before anyone reads it.
        segmentFile = nil
        segmentIndex += 1
        segmentStart = elapsed
        segmentFile = try? makeSegmentFile(format: format)

        DispatchQueue.main.async { self.onSegment(finished, index) }
    }

    private func makeSegmentFile(format: AVAudioFormat) throws -> AVAudioFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xflow-seg-\(UUID().uuidString).m4a")
        return try AVAudioFile(
            forWriting: url, settings: outputSettings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
    }

    private func reset() {
        detector = SilenceDetector()
        segmentIndex = 0
        segmentStart = 0
        elapsed = 0
        sessionBuffers.removeAll()
    }

    deinit {
        capTimer?.invalidate()
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build && swift run XFlowChecks`
Expected: build succeeds with no warnings; all checks still pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/XFlow/SegmentingRecorder.swift
git commit -m "feat: avaudioengine recorder that emits segments at pauses"
```

---

## Task 11: Pipeline segments through the API while recording

**Files:**
- Modify: `Sources/XFlow/AppDelegate.swift`
- Modify: `Sources/XFlow/Settings.swift`
- Modify: `Sources/XFlow/MenuBarController.swift`

**Interfaces:**
- Consumes: `SegmentingRecorder`, `TranscriptAssembler`, `Transcriber`
- Produces: `Settings.segmentingEnabled: Bool` (default true)

- [ ] **Step 1: Add the kill switch setting**

In `Sources/XFlow/Settings.swift`:

```swift
    /// Kill switch. v1's single-shot path stays in the code because a
    /// segmentation bug must never leave the user without dictation.
    static var segmentingEnabled: Bool {
        get { defaults.object(forKey: "segmentingEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "segmentingEnabled") }
    }
```

- [ ] **Step 2: Add the menu toggle**

In `Sources/XFlow/MenuBarController.swift`, add a stored property beside `cleanupMenuItem`:

```swift
    private let segmentingMenuItem: NSMenuItem
```

Initialise it before `super.init()`:

```swift
        segmentingMenuItem = NSMenuItem(
            title: "Transcribe while speaking",
            action: #selector(toggleSegmenting),
            keyEquivalent: ""
        )
```

Add it to the menu right after `cleanupMenuItem`:

```swift
        segmentingMenuItem.target = self
        segmentingMenuItem.state = Settings.segmentingEnabled ? .on : .off
        menu.addItem(segmentingMenuItem)
```

And the action:

```swift
    @objc private func toggleSegmenting() {
        Settings.segmentingEnabled.toggle()
        segmentingMenuItem.state = Settings.segmentingEnabled ? .on : .off
    }
```

- [ ] **Step 3: Wire the segmenting path into the app delegate**

In `Sources/XFlow/AppDelegate.swift`, add the new members beside the existing ones:

```swift
    private let segmentingRecorder = SegmentingRecorder()
    private var assembler = TranscriptAssembler()
    private var segmentTasks: [Task<Void, Never>] = []
```

In `applicationDidFinishLaunching`, wire its callbacks next to the existing recorder wiring:

```swift
        segmentingRecorder.onLevel = { [weak self] level in self?.pill.update(level: level) }
        segmentingRecorder.onAutoStop = { [weak self] in self?.handle(.hotkeyUp) }
        segmentingRecorder.onSegment = { [weak self] url, index in
            self?.transcribeSegment(url, index: index)
        }
```

Replace `startRecording()` with a version that picks a path:

```swift
    private func startRecording() {
        guard !IsSecureEventInputEnabled() else {
            fail("Can't dictate into a password field")
            return
        }

        assembler = TranscriptAssembler()
        segmentTasks.forEach { $0.cancel() }
        segmentTasks.removeAll()

        do {
            if Settings.segmentingEnabled {
                try segmentingRecorder.start()
            } else {
                try recorder.start()
            }
            pill.showRecording()
            menuBar.setRecording(true)
        } catch {
            fail("Microphone unavailable")
        }
    }
```

Add the per-segment transcription, which runs while the user is still speaking:

```swift
    /// Fires as soon as a segment closes, so its round trip overlaps with the
    /// rest of the dictation. Failures are recorded, not thrown: the whole-audio
    /// fallback in finishSegmentedRecording recovers them.
    private func transcribeSegment(_ url: URL, index: Int) {
        let task = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let text = try await transcriber.transcribe(fileURL: url)
                await MainActor.run { self.assembler.store(text, at: index) }
            } catch {
                log.error("segment \(index, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                await MainActor.run { self.assembler.markFailed(at: index) }
            }
        }
        segmentTasks.append(task)
    }
```

Replace `finishRecording()` so it routes to the right path:

```swift
    private func finishRecording() {
        menuBar.setRecording(false)
        if Settings.segmentingEnabled {
            finishSegmentedRecording()
        } else {
            finishSingleShotRecording()
        }
    }
```

Rename the existing body of `finishRecording` to `finishSingleShotRecording()` unchanged, and add:

```swift
    private func finishSegmentedRecording() {
        guard let result = segmentingRecorder.stop() else {
            state = state.next(on: .failed, now: Date())
            pill.hide()
            return
        }

        guard result.duration >= RecordingPolicy.minimumDuration else {
            result.tail.map { try? FileManager.default.removeItem(at: $0) }
            state = state.next(on: .failed, now: Date())
            pill.hide()
            return
        }

        pill.showTranscribing()

        Task { [weak self] in
            guard let self else { return }

            // The tail is the only unprocessed audio, which is why the wait no
            // longer grows with how long the user spoke.
            if let tail = result.tail {
                defer { try? FileManager.default.removeItem(at: tail) }
                do {
                    let text = try await transcriber.transcribe(fileURL: tail)
                    await MainActor.run { self.assembler.store(text, at: result.tailIndex) }
                } catch {
                    await MainActor.run { self.assembler.markFailed(at: result.tailIndex) }
                }
            }

            // Earlier segments are usually done already; this waits only for stragglers.
            for task in segmentTasks { _ = await task.value }

            let failures = await MainActor.run { self.assembler.failedIndices }
            let text: String
            if failures.isEmpty {
                text = await MainActor.run { self.assembler.assembled() }
            } else {
                log.notice("\(failures.count, privacy: .public) segments failed; falling back to whole audio")
                text = await self.wholeAudioFallback() ?? (await MainActor.run { self.assembler.assembled() })
            }

            guard !text.isEmpty else {
                await MainActor.run { self.fail("Nothing heard") }
                return
            }

            let pasted = await Inserter.insert(text)
            await MainActor.run {
                self.pill.hide()
                self.handle(.transcriptReady)
                self.handle(.inserted)
                if !pasted {
                    self.notify("Copied to clipboard — press ⌘V to paste (Accessibility is off)")
                }
            }
        }
    }

    /// Last resort when a segment could not be transcribed: send the entire
    /// recording as one request. Slower, but no words are lost.
    private func wholeAudioFallback() async -> String? {
        guard let url = segmentingRecorder.rebuildFullAudio() else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try? await transcriber.transcribe(fileURL: url)
    }
```

- [ ] **Step 4: Verify it builds and checks pass**

Run: `swift build && swift run XFlowChecks`
Expected: build succeeds with no warnings; all checks pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/XFlow/AppDelegate.swift Sources/XFlow/Settings.swift Sources/XFlow/MenuBarController.swift
git commit -m "feat: transcribe segments while the user is still speaking"
```

---

## Task 12: Verify segmentation end to end

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Build and run the segmentation smoke tests**

Run: `./build.sh debug && open build/XFlow.app`

Then work through each of these by hand:

1. Dictate 3 minutes of mixed Hindi and English with natural pauses. Confirm no word is lost at a boundary and no word is duplicated.
2. Confirm the wait after releasing `fn` does not grow with length — time a 20s dictation against a 150s one; they should feel the same.
3. Speak for 40 seconds with no pause at all. Confirm the force-close still produces complete text.
4. Turn Wi-Fi off midway through a 60s dictation, then back on before releasing. Confirm the whole-audio fallback recovers the text.
5. Turn off "Transcribe while speaking" in the menu bar. Confirm single-shot dictation still works.
6. Tap `fn` briefly. Confirm nothing is sent.

- [ ] **Step 2: Read the segment timings**

Run: `/usr/bin/log show --last 20m --predicate 'subsystem == "com.aamirhannan.xflow"' | grep -E "200 in|segment"`

Confirm several transcription calls appear *during* the dictation rather than all at the end.

- [ ] **Step 3: Add the segmentation checks to the README**

Append to the manual smoke checklist in `README.md`:

```markdown
- [ ] Dictate 3 minutes with pauses — no word lost or duplicated at a segment boundary
- [ ] A 150s dictation feels no slower to finish than a 20s one
- [ ] Speak 40s with no pause — force-close still produces complete text
- [ ] Drop the network mid-dictation — the whole-audio fallback recovers it
- [ ] Turn off "Transcribe while speaking" — single-shot still works
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: segmentation smoke checks"
```

---

## Self-review notes

**Spec coverage.** Every section of the v2 spec maps to a task: provider swap and endpoints (Task 1), vocabulary prompt as an editable setting (Tasks 2, 4), the `language` ban as a check rather than a comment (Task 1), Keychain account change and v1 UserDefaults migration (Tasks 2, 3), the Phase 1 measurement gate (Task 6), silence detection with an adaptive floor and exposed sensitivity (Task 7), the 10s billing floor and 30s force-close (Task 8), out-of-order assembly (Task 9), `AVAudioEngine` capture with retained PCM (Task 10), the concurrent pipeline, whole-audio fallback and kill switch (Task 11), and both automated and manual testing (throughout, plus Task 12).

**Deliberate omissions.** The spec mentions capping in-flight segments at 3. With a 10s floor and a 120s cap, a session yields at most 12 segments and typically 3 or 4, each finishing in under a second — so an explicit semaphore would be machinery guarding a limit that cannot be reached. Add it only if the recording cap is ever raised. Similarly, per-segment cleanup happens implicitly because `Transcriber.transcribe` already runs both legs per call.

**Known risk carried forward.** `SegmentingRecorder` writes AAC through `AVAudioFile` and relies on releasing the reference to finalise each container. If a segment ever uploads truncated, the `clip read: inMemory=… onDisk=…` log line added during the v1 investigation is the diagnostic already in place.
