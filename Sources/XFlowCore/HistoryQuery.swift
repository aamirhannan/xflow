import Foundation

/// One day's worth of dictations, with a heading the screen can show.
public struct DayGroup: Equatable, Identifiable {
    public let id: Date         // start of that day, in the given calendar
    public let title: String    // "Today", "Yesterday", or a formatted date
    public let records: [DictationRecord]

    public init(id: Date, title: String, records: [DictationRecord]) {
        self.id = id
        self.title = title
        self.records = records
    }
}

/// Filtering and grouping for the history list. Pure, so the awkward parts —
/// what an empty query means, which day a timestamp belongs to — are checkable.
public enum HistoryQuery {
    /// An empty or whitespace-only query returns everything unchanged.
    ///
    /// Both transcripts are searched. Cleanup romanizes non-Latin script, so a
    /// phrase the speaker remembers saying in Devanagari would otherwise be
    /// unfindable in a list that displays it in Latin.
    public static func matching(_ query: String, in records: [DictationRecord]) -> [DictationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        return records.filter {
            contains(trimmed, in: $0.cleanedText) || contains(trimmed, in: $0.rawText)
        }
    }

    private static func contains(_ needle: String, in haystack: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Groups in encounter order, so the newest-first order the store hands over
    /// survives into the screen — both across groups and inside them.
    public static func groupedByDay(
        _ records: [DictationRecord], today: Date, calendar: Calendar = .current
    ) -> [DayGroup] {
        let startOfToday = calendar.startOfDay(for: today)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)

        var order: [Date] = []
        var buckets: [Date: [DictationRecord]] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.timestamp)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(record)
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        return order.map { day in
            let title: String
            if day == startOfToday {
                title = "Today"
            } else if let yesterday, day == yesterday {
                title = "Yesterday"
            } else {
                title = formatter.string(from: day)
            }
            return DayGroup(id: day, title: title, records: buckets[day] ?? [])
        }
    }
}
