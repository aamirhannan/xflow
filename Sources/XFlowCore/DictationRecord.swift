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
