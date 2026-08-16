# XFlow 2A — History Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist every dictation to a local append-only file so the phase 2B dashboard has something to read.

**Architecture:** A `DictationRecord` value type and its JSONL encoding live in `XFlowCore`, where they are checkable without a filesystem. `HistoryStore` also lives in `XFlowCore` and takes its file URL as a parameter, so the disk layer can be checked against a temporary directory. A new `Transcript` pair type threads the raw transcript alongside the cleaned one from `Transcriber` through `TranscriptAssembler` to `AppDelegate`, whose two duplicated finish paths collapse into one `complete(...)` method that ends by recording.

**Tech Stack:** Swift 6 toolchain in language mode 5, Foundation only, AppKit for the menu items, `OSLog` for diagnostics. No new dependencies.

Spec: [2026-08-17-xflow-history-store-design.md](../specs/2026-08-17-xflow-history-store-design.md)

## Global Constraints

- `swift build` must be clean with **zero warnings**. `swift run XFlowChecks` must report **zero failures**. Both gate every commit.
- There is **no `swift test`**. This machine has Command Line Tools only — neither `XCTest` nor `swift-testing` exists. Checks are assert-based functions in `Sources/XFlowChecks/`, registered in `Sources/XFlowChecks/main.swift`.
- **Never run `swift run XFlow`.** It produces an unbundled process with no `Info.plist`, so no bundle identifier, and `UNUserNotificationCenter` traps. Always assemble with `./build.sh debug` and launch `build/XFlow.app`.
- Reading logs requires the absolute path, because `log` is shadowed in this user's shell profile: `/usr/bin/log show --last 20m --predicate 'subsystem == "com.aamirhannan.xflow"'`
- Never commit directly to `main`. All work happens on `feat/history-store`, cut from `main` in Task 1.
- Deliberate shortcuts get a `ponytail:` comment naming the ceiling and the upgrade condition.
- Do not touch the transcription request builders. `language` is never sent, and the vocabulary prompt never goes on a transcription request. Neither is in scope here; do not "tidy" them.
- Storage path is exactly `~/Library/Application Support/XFlow/history.jsonl`, directory mode `0700`, file mode `0600`.
- `OSLog` subsystem is `com.aamirhannan.xflow`; use category `history` for new logging.

---

### Task 1: The record and its JSONL encoding

Pure value type plus line encode/decode. No filesystem, no app changes. This is the format everything else rests on.

**Files:**
- Create: `Sources/XFlowCore/DictationRecord.swift`
- Create: `Sources/XFlowChecks/HistoryChecks.swift`
- Modify: `Sources/XFlowChecks/main.swift:24` (register the new check group)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct DictationRecord: Codable, Equatable, Identifiable` with `let id: UUID`, `let timestamp: Date`, `let durationSeconds: Double`, `let rawText: String`, `let cleanedText: String`, and `var wordCount: Int { get }`.
  - `public init(id: UUID = UUID(), timestamp: Date = Date(), durationSeconds: Double, rawText: String, cleanedText: String)`
  - `public enum HistoryLog` with `static func line(for: DictationRecord) throws -> String` and `static func records(from: String) -> [DictationRecord]`.

- [ ] **Step 1: Cut the working branch**

Based on the spec branch rather than `main`, so the spec, this plan, and the
implementation all reach `main` through a single pull request. Never merge the
spec branch to unblock this — see the branching rules in `CLAUDE.md`.

```bash
git checkout -b feat/history-store docs/phase2a-history-store
```

- [ ] **Step 2: Write the failing checks**

Create `Sources/XFlowChecks/HistoryChecks.swift`:

```swift
import Foundation
import XFlowCore

func checkHistoryLog() {
    // A whole-second date on purpose: the format encodes dates as ISO-8601,
    // which has no sub-second component, so a Date() with a fractional part
    // would not survive a round trip and the check would fail for a reason
    // that has nothing to do with the record.
    let record = DictationRecord(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        timestamp: Date(timeIntervalSince1970: 1_755_000_000),
        durationSeconds: 12.5,
        rawText: "यह एक टेस्ट है",
        cleanedText: "Yah ek test hai."
    )

    guard let line = try? HistoryLog.line(for: record) else {
        Checks.check(false, "a record encodes to a line")
        return
    }
    Checks.equal(HistoryLog.records(from: line), [record],
                 "a record survives an encode and decode round trip")

    // The entire format rests on this: JSON escapes newlines, so a
    // multi-paragraph transcript still occupies exactly one physical line.
    let multiline = DictationRecord(
        durationSeconds: 3,
        rawText: "first para\n\nsecond para",
        cleanedText: "First para.\n\nSecond para."
    )
    guard let multilineLine = try? HistoryLog.line(for: multiline) else {
        Checks.check(false, "a multi-paragraph record encodes")
        return
    }
    Checks.equal(multilineLine.contains("\n"), false,
                 "a transcript containing newlines still encodes to one physical line")

    // Append-only means only the last line can ever be torn. Losing one record
    // is acceptable; losing the file is not.
    let torn = line + "\n" + line + "\n" + String(line.prefix(20))
    Checks.equal(HistoryLog.records(from: torn).count, 2,
                 "a truncated final line still yields every record before it")

    // A damaged line in the middle must not stop the ones after it loading.
    let middleGarbage = line + "\n" + "{not json" + "\n" + line
    Checks.equal(HistoryLog.records(from: middleGarbage).count, 2,
                 "an unparseable line is skipped without losing the lines after it")

    Checks.equal(HistoryLog.records(from: "").count, 0, "empty contents decode to no records")

    // Word count is derived from the cleaned side, because that is the text the
    // user actually received.
    Checks.equal(
        DictationRecord(durationSeconds: 1, rawText: "x", cleanedText: "one two three").wordCount,
        3, "word count on plain Latin text"
    )
    Checks.equal(
        DictationRecord(durationSeconds: 1, rawText: "x", cleanedText: "  spaced \n out  words ").wordCount,
        3, "word count ignores runs of whitespace and newlines"
    )
    Checks.equal(
        DictationRecord(durationSeconds: 1, rawText: "x", cleanedText: "mujhe RBAC ka access chahiye").wordCount,
        5, "word count on romanized mixed Hindi and English"
    )
    Checks.equal(
        DictationRecord(durationSeconds: 1, rawText: "x", cleanedText: "").wordCount,
        0, "empty text has no words"
    )
}
```

- [ ] **Step 3: Register the check group**

In `Sources/XFlowChecks/main.swift`, add after line 24 (`checkTranscriptAssembler()`):

```swift
checkHistoryLog()
```

- [ ] **Step 4: Run the checks to verify they fail**

Run: `swift build 2>&1 | head -20`
Expected: FAIL — `cannot find 'DictationRecord' in scope` and `cannot find 'HistoryLog' in scope`.

- [ ] **Step 5: Write the implementation**

Create `Sources/XFlowCore/DictationRecord.swift`:

```swift
import Foundation

/// One dictation, as stored on disk.
///
/// `wordCount` is derived rather than persisted: freezing today's definition of
/// a word into the file would mean a later fix could never reach old records.
public struct DictationRecord: Codable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let durationSeconds: Double
    public let rawText: String
    public let cleanedText: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        durationSeconds: Double,
        rawText: String,
        cleanedText: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.rawText = rawText
        self.cleanedText = cleanedText
    }

    /// Counted on the cleaned side, because that is the text the user actually
    /// received. The raw side may still carry Devanagari when cleanup failed.
    public var wordCount: Int {
        cleanedText.split(whereSeparator: \.isWhitespace).count
    }
}

/// The on-disk format: one JSON object per line.
///
/// Dates are ISO-8601, which makes the file readable and greppable at the cost
/// of sub-second precision. A dictation log does not need milliseconds.
public enum HistoryLog {
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// One record, one line. JSON escapes newlines as `\n`, so a multi-paragraph
    /// transcript still occupies exactly one physical line — the property the
    /// whole format rests on.
    public static func line(for record: DictationRecord) throws -> String {
        String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    /// Skips any line that will not decode. The file is append-only, so only the
    /// final line can ever be torn and the worst case is losing one record.
    public static func records(from contents: String) -> [DictationRecord] {
        contents.split(separator: "\n").compactMap {
            try? decoder.decode(DictationRecord.self, from: Data($0.utf8))
        }
    }
}
```

- [ ] **Step 6: Run the checks to verify they pass**

Run: `swift build && swift run XFlowChecks`
Expected: PASS — `✅ N checks passed`, zero warnings from the build.

- [ ] **Step 7: Commit**

```bash
git add Sources/XFlowCore/DictationRecord.swift Sources/XFlowChecks/HistoryChecks.swift Sources/XFlowChecks/main.swift
git commit -m "feat: dictation record and its JSONL line format"
```

---

### Task 2: The store on disk

The file itself. It lives in `XFlowCore` and takes its URL as a parameter precisely so these checks can run against a temporary directory — anything in the `XFlow` target is unreachable from `XFlowChecks`.

**Files:**
- Create: `Sources/XFlowCore/HistoryStore.swift`
- Modify: `Sources/XFlowChecks/HistoryChecks.swift` (append a second check function)
- Modify: `Sources/XFlowChecks/main.swift` (register it)

**Interfaces:**
- Consumes: `DictationRecord`, `HistoryLog.line(for:)`, `HistoryLog.records(from:)` from Task 1.
- Produces: `public final class HistoryStore` with `static let defaultFileURL: URL`, `init(fileURL: URL = HistoryStore.defaultFileURL)`, `func record(_ record: DictationRecord)`, `func all() -> [DictationRecord]`, `func delete(id: UUID)`, `func deleteAll()`.

- [ ] **Step 1: Write the failing checks**

Append to `Sources/XFlowChecks/HistoryChecks.swift`:

```swift
func checkHistoryStore() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xflow-history-checks-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("history.jsonl")
    defer { try? FileManager.default.removeItem(at: directory) }

    // Non-optional on purpose: passing an optional and a literal to the generic
    // Checks.equal makes type inference ambiguous.
    func mode(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    let store = HistoryStore(fileURL: fileURL)

    Checks.equal(store.all(), [], "a store with no file yet reads as empty, not an error")

    let first = DictationRecord(durationSeconds: 5, rawText: "one", cleanedText: "One.")
    let second = DictationRecord(durationSeconds: 6, rawText: "two", cleanedText: "Two.")
    // record() is asynchronous, but all() is synchronous on the same serial
    // queue, so it always observes the writes queued ahead of it.
    store.record(first)
    store.record(second)

    Checks.equal(store.all().map(\.id), [second.id, first.id],
                 "both records are readable, newest first")

    // The store's whole privacy story rests on this mode.
    Checks.equal(mode(of: fileURL), 0o600, "the history file is readable only by its owner")

    // Simulate a write interrupted mid-line, which is the only corruption an
    // append-only file can suffer.
    if let handle = try? FileHandle(forWritingTo: fileURL) {
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("{\"id\":\"tru".utf8))
        try? handle.close()
    }
    Checks.equal(store.all().count, 2, "a torn final line does not cost more than its own record")

    store.delete(id: first.id)
    Checks.equal(store.all().map(\.id), [second.id],
                 "deleting one record leaves exactly the others")

    // Rewriting must not silently widen the file's permissions: an atomic write
    // replaces the file, and the replacement does not inherit its mode.
    Checks.equal(mode(of: fileURL), 0o600, "a rewrite keeps the owner-only mode")

    store.deleteAll()
    Checks.equal(store.all(), [], "deleting everything empties the history")

    // The store must survive being used again after its file is gone.
    store.record(first)
    Checks.equal(store.all().count, 1, "recording recreates the file after a delete-all")
}
```

- [ ] **Step 2: Register the check group**

In `Sources/XFlowChecks/main.swift`, add after `checkHistoryLog()`:

```swift
checkHistoryStore()
```

- [ ] **Step 3: Run the checks to verify they fail**

Run: `swift build 2>&1 | head -20`
Expected: FAIL — `cannot find 'HistoryStore' in scope`.

- [ ] **Step 4: Write the implementation**

Create `Sources/XFlowCore/HistoryStore.swift`:

```swift
import Foundation
import OSLog

private let log = Logger(subsystem: "com.aamirhannan.xflow", category: "history")

/// Append-only dictation history, one JSON object per line.
///
/// Every operation is non-throwing on purpose. History must never be able to
/// break dictation: by the time `record` runs, the text has already been pasted,
/// so a full disk or a bad permission is worth a log line and nothing more.
///
/// ponytail: no in-memory cache and no change notifications. `all()` reads the
/// whole file, which is milliseconds at the scale this reaches (roughly 18MB
/// after a year of heavy use). Add a cache when the dashboard has to update
/// while it is open.
public final class HistoryStore {
    public static let defaultFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("XFlow", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }()

    private let fileURL: URL

    /// Serialises every access. Writes are async so the caller never waits on
    /// disk; reads are sync and therefore always see the writes queued ahead.
    private let queue = DispatchQueue(label: "com.aamirhannan.xflow.history")

    public init(fileURL: URL = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func record(_ record: DictationRecord) {
        queue.async { [fileURL] in
            do {
                let line = try HistoryLog.line(for: record) + "\n"
                try Self.createIfMissing(at: fileURL)
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                log.error("history append failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Newest first, which is the order every screen wants.
    public func all() -> [DictationRecord] {
        queue.sync { Array(Self.read(from: fileURL).reversed()) }
    }

    public func delete(id: UUID) {
        queue.sync {
            let kept = Self.read(from: fileURL).filter { $0.id != id }
            Self.overwrite(fileURL, with: kept)
        }
    }

    public func deleteAll() {
        queue.sync {
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                log.error("history delete-all failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Disk

    private static func read(from url: URL) -> [DictationRecord] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return HistoryLog.records(from: contents)
    }

    private static func overwrite(_ url: URL, with records: [DictationRecord]) {
        let body = records.compactMap { try? HistoryLog.line(for: $0) }.joined(separator: "\n")
        let text = body.isEmpty ? "" : body + "\n"
        do {
            try createIfMissing(at: url)
            try text.write(to: url, atomically: true, encoding: .utf8)
            // An atomic write replaces the file rather than editing it, and the
            // replacement is created with the process umask — so without this the
            // history would quietly become world-readable on its first rewrite.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("history rewrite failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func createIfMissing(at url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
        }
    }
}
```

- [ ] **Step 5: Run the checks to verify they pass**

Run: `swift build && swift run XFlowChecks`
Expected: PASS — `✅ N checks passed`, zero warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/XFlowCore/HistoryStore.swift Sources/XFlowChecks/HistoryChecks.swift Sources/XFlowChecks/main.swift
git commit -m "feat: append-only history store on disk"
```

---

### Task 3: Carry the raw transcript alongside the cleaned one

Storing the raw side needs a type change the current code cannot express: `Transcriber.transcribe` throws its raw transcript away at all five exit points, and `TranscriptAssembler` only ever holds cleaned pieces. Nothing is recorded yet in this task — it only makes the raw text reachable.

**Files:**
- Modify: `Sources/XFlowCore/TranscriptAssembler.swift` (whole file)
- Modify: `Sources/XFlow/Transcriber.swift:64-142` (return type and five returns)
- Modify: `Sources/XFlow/AppDelegate.swift:149-295` (call sites)
- Modify: `Sources/XFlowChecks/SegmentationChecks.swift:87-123` (`checkTranscriptAssembler`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public struct Transcript: Equatable` with `let raw: String`, `let cleaned: String`, and `public init(raw: String, cleaned: String)`.
  - `TranscriptAssembler.store(_ transcript: Transcript, at index: Int)` — signature changed from `String`.
  - `TranscriptAssembler.assembled() -> Transcript` — return type changed from `String`.
  - `Transcriber.transcribe(fileURL: URL) async throws -> Transcript` — return type changed from `String`.

- [ ] **Step 1: Update the assembler checks to the new types**

In `Sources/XFlowChecks/SegmentationChecks.swift`, replace the whole `checkTranscriptAssembler()` function with:

```swift
func checkTranscriptAssembler() {
    // Segments finish out of order because they run concurrently. Order in the
    // output must follow the index, never completion time.
    var assembler = TranscriptAssembler()
    assembler.store(Transcript(raw: "doosra bhag", cleaned: "second part"), at: 1)
    assembler.store(Transcript(raw: "pehla bhag", cleaned: "first part"), at: 0)
    assembler.store(Transcript(raw: "teesra bhag", cleaned: "third part"), at: 2)
    Checks.equal(assembler.assembled().cleaned, "first part second part third part",
                 "segments assemble in index order, not completion order")
    // Both sides are joined independently, so the raw text stays usable as a
    // fallback even when it reads nothing like the cleaned output.
    Checks.equal(assembler.assembled().raw, "pehla bhag doosra bhag teesra bhag",
                 "the raw side assembles in index order too")

    let empty = TranscriptAssembler()
    Checks.equal(empty.assembled(), Transcript(raw: "", cleaned: ""),
                 "nothing stored assembles to empty on both sides")
    Checks.equal(empty.failedIndices, [], "nothing stored has no failures")

    var withGap = TranscriptAssembler()
    withGap.store(Transcript(raw: "zero", cleaned: "zero"), at: 0)
    withGap.store(Transcript(raw: "two", cleaned: "two"), at: 2)
    Checks.equal(withGap.assembled().cleaned, "zero two", "a missing index is skipped, not padded")

    var failing = TranscriptAssembler()
    failing.store(Transcript(raw: "zero", cleaned: "zero"), at: 0)
    failing.markFailed(at: 1)
    failing.store(Transcript(raw: "two", cleaned: "two"), at: 2)
    Checks.equal(failing.failedIndices, [1], "a failed segment is tracked by index")

    // A segment that failed and was later retried successfully is no longer failed.
    failing.store(Transcript(raw: "one", cleaned: "one"), at: 1)
    Checks.equal(failing.failedIndices, [], "a recovered segment clears its failure")
    Checks.equal(failing.assembled().cleaned, "zero one two", "recovered text lands in the right place")

    // Blank results must not produce double spaces.
    var blanks = TranscriptAssembler()
    blanks.store(Transcript(raw: "zero", cleaned: "zero"), at: 0)
    blanks.store(Transcript(raw: "   ", cleaned: "   "), at: 1)
    blanks.store(Transcript(raw: "two", cleaned: "two"), at: 2)
    Checks.equal(blanks.assembled().cleaned, "zero two",
                 "blank segments do not leave gaps in the text")

    // One side blank and the other not is normal: cleanup can return nothing
    // useful for a segment whose raw transcript is fine.
    var lopsided = TranscriptAssembler()
    lopsided.store(Transcript(raw: "kuch to hai", cleaned: ""), at: 0)
    lopsided.store(Transcript(raw: "aur bhi", cleaned: "and more"), at: 1)
    Checks.equal(lopsided.assembled().raw, "kuch to hai aur bhi", "a blank cleaned side does not drop the raw text")
    Checks.equal(lopsided.assembled().cleaned, "and more", "a blank cleaned piece is skipped on its own side only")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | head -20`
Expected: FAIL — `cannot find 'Transcript' in scope`.

- [ ] **Step 3: Add the type and update the assembler**

Replace the whole of `Sources/XFlowCore/TranscriptAssembler.swift`:

```swift
import Foundation

/// What one transcription produced: the model's own words, and the formatted
/// text the user receives. Both sides are kept because cleanup is verified
/// mechanically and can still be wrong — the raw side is the only record of
/// what was actually heard.
public struct Transcript: Equatable {
    public let raw: String
    public let cleaned: String

    public init(raw: String, cleaned: String) {
        self.raw = raw
        self.cleaned = cleaned
    }
}

/// Collects segment transcripts that complete in any order and joins them by
/// index. Concurrency means segment 3 can land before segment 1; the reader
/// must never see that.
public struct TranscriptAssembler {
    private var pieces: [Int: Transcript] = [:]
    private var failed: Set<Int> = []

    public init() {}

    public mutating func store(_ transcript: Transcript, at index: Int) {
        pieces[index] = transcript
        failed.remove(index)
    }

    public mutating func markFailed(at index: Int) {
        failed.insert(index)
    }

    /// Sorted so the caller can retry deterministically.
    public var failedIndices: [Int] { failed.sorted() }

    /// Each side is joined independently: a segment whose cleanup came back
    /// empty must not remove its raw text from the other side.
    public func assembled() -> Transcript {
        Transcript(raw: join { $0.raw }, cleaned: join { $0.cleaned })
    }

    private func join(_ side: (Transcript) -> String) -> String {
        pieces.keys.sorted()
            .compactMap { pieces[$0].map(side)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
```

- [ ] **Step 4: Update `Transcriber` to return the pair**

In `Sources/XFlow/Transcriber.swift`, change the signature at line 64 and each of the five returns. The declaration becomes:

```swift
    func transcribe(fileURL: URL) async throws -> Transcript {
```

Then, leaving every comment in that method exactly as it is, change only these five return statements:

```swift
        // was: guard Settings.cleanupEnabled else { return transcript }
        guard Settings.cleanupEnabled else { return Transcript(raw: transcript, cleaned: transcript) }
```

```swift
        // was: guard let problem = isWrong(cleaned) else { return cleaned }
        guard let problem = isWrong(cleaned) else {
            return Transcript(raw: transcript, cleaned: cleaned)
        }
```

```swift
        // was: if isWrong(retried) == nil { return retried }
        if isWrong(retried) == nil { return Transcript(raw: transcript, cleaned: retried) }
```

```swift
        // was: return Script.romanize(transcript)
        return Transcript(raw: transcript, cleaned: Script.romanize(transcript))
```

```swift
        // was (in the catch): return transcript
        return Transcript(raw: transcript, cleaned: transcript)
```

- [ ] **Step 5: Update the three call sites in `AppDelegate`**

In `Sources/XFlow/AppDelegate.swift`:

In `transcribeSegment(_:index:)`, the stored value is now the pair:

```swift
                let transcript = try await transcriber.transcribe(fileURL: url)
                await MainActor.run { self.assembler.store(transcript, at: index) }
```

In `finishSingleShotRecording()`, insert the cleaned side:

```swift
                let transcript = try await transcriber.transcribe(fileURL: clip.url)
                await MainActor.run { self.handle(.transcriptReady) }

                let pasted = await Inserter.insert(transcript.cleaned)
```

In `finishSegmentedRecording()`, the tail and the assembled result:

```swift
            if let tail = result.tail {
                do {
                    let transcript = try await transcriber.transcribe(fileURL: tail)
                    await MainActor.run { self.assembler.store(transcript, at: result.tailIndex) }
                } catch {
                    await MainActor.run { self.assembler.markFailed(at: result.tailIndex) }
                }
                try? FileManager.default.removeItem(at: tail)
            }
```

```swift
            let failures = await MainActor.run { self.assembler.failedIndices }
            var text = await MainActor.run { self.assembler.assembled() }

            if !failures.isEmpty {
                log.notice("\(failures.count, privacy: .public) segments failed, falling back to whole audio")
                if let recovered = await self.wholeAudioFallback() { text = recovered }
            }

            guard !text.cleaned.isEmpty else {
                await MainActor.run { self.fail("Nothing heard") }
                return
            }
```

and further down:

```swift
            let pasted = await Inserter.insert(text.cleaned)
```

And `wholeAudioFallback()` now returns the pair:

```swift
    private func wholeAudioFallback() async -> Transcript? {
        guard let url = segmentingRecorder.rebuildFullAudio() else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try? await transcriber.transcribe(fileURL: url)
    }
```

- [ ] **Step 6: Run the build and the checks**

Run: `swift build && swift run XFlowChecks`
Expected: PASS — `✅ N checks passed`, zero warnings.

- [ ] **Step 7: Verify dictation still works before recording anything**

Run: `./build.sh debug && open build/XFlow.app`
Then dictate one short sentence into any text field.
Expected: the text pastes exactly as before. This task changed types only — a behaviour change here means the pair was wired to the wrong side.

Check the perceived wait is unchanged:

```bash
/usr/bin/log show --last 5m --predicate 'subsystem == "com.aamirhannan.xflow"' | grep "PERCEIVED WAIT"
```

- [ ] **Step 8: Commit**

```bash
git add Sources/XFlowCore/TranscriptAssembler.swift Sources/XFlow/Transcriber.swift Sources/XFlow/AppDelegate.swift Sources/XFlowChecks/SegmentationChecks.swift
git commit -m "refactor: carry the raw transcript alongside the cleaned one"
```

---

### Task 4: One completion path, and record into it

Both finish paths end with the same six statements today. Collapsing them into one method is what makes "every dictation is recorded" structurally true rather than a rule two call sites have to remember — and it deletes the existing duplication.

**Files:**
- Modify: `Sources/XFlow/Settings.swift` (add `historyEnabled`)
- Modify: `Sources/XFlow/AppDelegate.swift:9-25` (add the store), `:175-295` (unify the tails)

**Interfaces:**
- Consumes: `HistoryStore`, `DictationRecord` from Tasks 1-2; `Transcript` from Task 3.
- Produces: `Settings.historyEnabled: Bool` (default `true`); `AppDelegate.complete(_ transcript: Transcript, duration: TimeInterval) async`.

- [ ] **Step 1: Add the setting**

In `Sources/XFlow/Settings.swift`, add after `segmentingEnabled`:

```swift
    /// Off means new dictations are not written to history. Reading and deleting
    /// still work, so pausing never hides or strands what is already stored.
    static var historyEnabled: Bool {
        get { defaults.object(forKey: "historyEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "historyEnabled") }
    }
```

- [ ] **Step 2: Hold a store on the delegate**

In `Sources/XFlow/AppDelegate.swift`, add to the stored properties beside `transcriber`:

```swift
    private let history = HistoryStore()
```

- [ ] **Step 3: Add the unified completion path**

Add this method to `AppDelegate`, directly above `wholeAudioFallback()`:

```swift
    /// The single place a dictation ends. Both the single-shot and the segmented
    /// path route through here, so history cannot miss one and a future third
    /// path gets recording for free.
    ///
    /// Recording is last on purpose: the paste has already happened by the time
    /// it runs, so nothing the store does can delay or break the text arriving.
    ///
    /// Only reached when there is text. A sub-0.4s hotkey tap, a "Nothing heard"
    /// result and a network failure all return before this, so history holds no
    /// empty rows.
    private func complete(_ transcript: Transcript, duration: TimeInterval) async {
        await MainActor.run { self.handle(.transcriptReady) }

        let pasted = await Inserter.insert(transcript.cleaned)
        await MainActor.run {
            self.pill.hide()
            self.handle(.inserted)
            if !pasted {
                self.notify("Copied to clipboard — press ⌘V to paste (Accessibility is off)")
            }
        }

        guard Settings.historyEnabled else { return }
        history.record(
            DictationRecord(
                durationSeconds: duration,
                rawText: transcript.raw,
                cleanedText: transcript.cleaned
            )
        )
    }
```

- [ ] **Step 4: Route the single-shot path through it**

In `finishSingleShotRecording()`, replace the body of the `do` block so it reads:

```swift
            do {
                let transcript = try await transcriber.transcribe(fileURL: clip.url)
                await self.complete(transcript, duration: clip.duration)
            } catch let error as XFlowError {
```

The `catch` blocks below it stay exactly as they are.

- [ ] **Step 5: Route the segmented path through it**

In `finishSegmentedRecording()`, replace everything from the `guard !text.cleaned.isEmpty` check to the end of the `Task` closure with:

```swift
            guard !text.cleaned.isEmpty else {
                await MainActor.run { self.fail("Nothing heard") }
                return
            }

            // The only latency number that matters: fn release to text on screen.
            log.notice("PERCEIVED WAIT \(String(format: "%.2f", Date().timeIntervalSince(releasedAt)), privacy: .public)s")
            await self.complete(text, duration: result.duration)
```

- [ ] **Step 6: Build and run the checks**

Run: `swift build && swift run XFlowChecks`
Expected: PASS, zero warnings.

- [ ] **Step 7: Verify end to end**

```bash
./build.sh debug && open build/XFlow.app
```

Dictate two short sentences, in two separate dictations. Then:

```bash
cat ~/Library/Application\ Support/XFlow/history.jsonl
ls -l ~/Library/Application\ Support/XFlow/history.jsonl
```

Expected: exactly two lines, each one JSON object with `rawText`, `cleanedText`, an ISO-8601 `timestamp`, and a `durationSeconds` matching roughly how long you spoke. The file mode is `-rw-------`.

Confirm the wait did not regress:

```bash
/usr/bin/log show --last 5m --predicate 'subsystem == "com.aamirhannan.xflow"' | grep -E "PERCEIVED WAIT|history"
```

Expected: the perceived wait is in its usual ~1.5s range, and no `history append failed` lines.

Then verify a failure cannot reach dictation — make the directory unwritable and dictate again:

```bash
chmod 500 ~/Library/Application\ Support/XFlow
```

Dictate once. Expected: the text still pastes normally, and the log carries a `history append failed` line rather than any user-visible error. Restore it:

```bash
chmod 700 ~/Library/Application\ Support/XFlow
```

- [ ] **Step 8: Commit**

```bash
git add Sources/XFlow/AppDelegate.swift Sources/XFlow/Settings.swift
git commit -m "feat: record every dictation through one completion path"
```

---

### Task 5: The controls

A store that captures everything the user says needs its off-switch in the same build, not the one after. Both controls move into the dashboard in 2B.

**Files:**
- Modify: `Sources/XFlow/MenuBarController.swift` (whole file — two new items)
- Modify: `Sources/XFlow/AppDelegate.swift:26-53` (wire the delete callback)

**Interfaces:**
- Consumes: `Settings.historyEnabled` from Task 4; `HistoryStore.deleteAll()` from Task 2.
- Produces: `MenuBarController.onDeleteAllHistory: () -> Void`.

- [ ] **Step 1: Add the menu items**

In `Sources/XFlow/MenuBarController.swift`, add the stored properties beside the existing ones:

```swift
    var onDeleteAllHistory: () -> Void = {}

    private let historyMenuItem: NSMenuItem
```

Initialise it alongside the others in `init()`:

```swift
        historyMenuItem = NSMenuItem(
            title: "Save history",
            action: #selector(toggleHistory),
            keyEquivalent: ""
        )
```

Add both items to the menu, after `segmentingMenuItem` and before the `Settings…` item:

```swift
        historyMenuItem.target = self
        historyMenuItem.state = Settings.historyEnabled ? .on : .off
        menu.addItem(historyMenuItem)

        let deleteHistory = NSMenuItem(
            title: "Delete all history…",
            action: #selector(deleteAllHistory),
            keyEquivalent: ""
        )
        deleteHistory.target = self
        menu.addItem(deleteHistory)
```

And the two actions, beside the existing `@objc` methods:

```swift
    @objc private func toggleHistory() {
        Settings.historyEnabled.toggle()
        historyMenuItem.state = Settings.historyEnabled ? .on : .off
    }

    @objc private func deleteAllHistory() {
        let alert = NSAlert()
        alert.messageText = "Delete all dictation history?"
        alert.informativeText =
            "Every transcript stored on this Mac will be removed. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        // An accessory app is not frontmost when its menu is used, and a sheetless
        // alert from a background app can open behind whatever the user is in.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDeleteAllHistory()
    }
```

- [ ] **Step 2: Wire the callback**

In `Sources/XFlow/AppDelegate.swift`, beside the existing `menuBar.onOpenSettings` line in `applicationDidFinishLaunching`:

```swift
        menuBar.onDeleteAllHistory = { [weak self] in self?.history.deleteAll() }
```

- [ ] **Step 3: Build and run the checks**

Run: `swift build && swift run XFlowChecks`
Expected: PASS, zero warnings.

- [ ] **Step 4: Verify both controls**

```bash
./build.sh debug && open build/XFlow.app
```

1. Dictate once, confirm a line appears in `~/Library/Application Support/XFlow/history.jsonl`.
2. Uncheck **Save history** in the menu. Dictate again. Expected: the text still pastes, and the file gains no new line.
3. Re-check **Save history**. Dictate. Expected: a new line appears.
4. Choose **Delete all history…** and cancel. Expected: the file is untouched.
5. Choose it again and confirm. Expected: the file is gone.
6. Dictate once more. Expected: the file is recreated with one line, mode `-rw-------`.

- [ ] **Step 5: Commit**

```bash
git add Sources/XFlow/MenuBarController.swift Sources/XFlow/AppDelegate.swift
git commit -m "feat: pause and delete controls for dictation history"
```

---

### Task 6: Notes and merge

The repo's `notes/` are the first thing anyone reads. A new subsystem that is not in them does not exist.

**Files:**
- Modify: `notes/0001-architecture.md`
- Modify: `docs/superpowers/specs/2026-08-17-xflow-history-store-design.md` (correct two claims found during implementation)

- [ ] **Step 1: Correct the spec**

Two statements in the spec were wrong and were corrected during planning. Fix them in place so the spec matches what shipped:

1. In the architecture table, `HistoryStore.swift` is in **`XFlowCore`**, not `XFlow` — anything in the `XFlow` target is unreachable from `XFlowChecks`, and the store takes a `fileURL` parameter so it can be checked against a temporary directory.
2. Remove the claim that `XFlowChecks/Probe.swift` needs updating. `Probe` rebuilds the pipeline from `XFlowCore` builders and never calls `Transcriber`.
3. In the "Checks" section, add that the disk layer **is** checked (append, read order, torn line, delete, delete-all, and the `0600` mode), replacing the sentence saying it is deliberately not checked.

- [ ] **Step 2: Document the store in the architecture note**

Add a section to `notes/0001-architecture.md` after "What is guaranteed", covering: the file location and format, that both transcripts are kept and audio is not, that word count is derived, that history is never allowed to break dictation, and that the two controls live in the menu bar until 2B moves them into the dashboard. Match the existing voice — short, measured, no marketing.

Also update the dictation-flow diagram in that note so the last line reads:

```
       ├─ clipboard swap → synthetic ⌘V → restore clipboard
       └─ append one line to history.jsonl
```

- [ ] **Step 3: Final gate**

```bash
swift build 2>&1 | tail -5
swift run XFlowChecks
./build.sh debug
```

Expected: zero warnings, `✅ N checks passed`, and a signed `build/XFlow.app`.

- [ ] **Step 4: Commit and open the pull request**

```bash
git add notes/0001-architecture.md docs/superpowers/specs/2026-08-17-xflow-history-store-design.md
git commit -m "docs: record the history store in the architecture notes"

gh auth switch -u aamirhannan
git push -u github-personal feat/history-store
gh pr create --base main --head feat/history-store \
  --title "Phase 2A: local dictation history store" \
  --body "$(cat <<'BODY'
Persists every dictation to `~/Library/Application Support/XFlow/history.jsonl`
so the 2B dashboard has something to read. Local only — no account, no sync.

Includes the design spec and the implementation plan alongside the code.

- `DictationRecord` + JSONL format, with word count derived rather than stored
- `HistoryStore`: append-only, owner-only file mode, non-throwing throughout
- `Transcript` pair type so the raw transcript survives beside the cleaned one
- One `complete(...)` path in `AppDelegate`, replacing two duplicated tails
- "Save history" and "Delete all history…" in the menu bar

History can never break dictation: every store operation swallows its failures,
and the write happens after the paste.
BODY
)"
gh auth switch -u aamirhannan-irame
```

**Do not merge this pull request.** The user merges it.

---

## Done when

- `swift build` is clean with zero warnings and `swift run XFlowChecks` reports zero failures.
- Dictating appends exactly one line per dictation to `~/Library/Application Support/XFlow/history.jsonl`, mode `-rw-------`, carrying both transcripts, an ISO-8601 timestamp, and a plausible duration.
- Turning off **Save history** stops new lines; existing ones stay readable and deletable.
- **Delete all history…** removes the file after confirmation, and the next dictation recreates it.
- Making the directory unwritable does not break dictation and produces a log line rather than an error.
- The perceived wait is unchanged from before the change.
- `notes/0001-architecture.md` describes the store.
