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
        // `try?` wraps the offset seekToEnd() returns, which defeats its
        // @discardableResult — hence the explicit discard.
        _ = try? handle.seekToEnd()
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
