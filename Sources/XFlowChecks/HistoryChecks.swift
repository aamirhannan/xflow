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
