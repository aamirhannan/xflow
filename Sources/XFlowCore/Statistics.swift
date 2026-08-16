import Foundation

/// Everything Home displays, as pure functions over stored records.
///
/// `today` is a parameter rather than `Date()` so every streak edge case is
/// reachable from a check.
public enum Statistics {
    public static func totalWords(_ records: [DictationRecord]) -> Int {
        records.reduce(0) { $0 + $1.wordCount }
    }

    public static func totalSpeechSeconds(_ records: [DictationRecord]) -> Double {
        records.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Minutes below an hour, hours above. A new user seeing "0.0h" would think
    /// the app was broken.
    public static func formattedSpeechTime(seconds: Double) -> String {
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    /// Consecutive days with at least one dictation, counting back from today —
    /// or from yesterday when nothing has been said yet today.
    ///
    /// That second case is the whole subtlety: a streak that broke at midnight
    /// would show every user a zero every morning before they had a chance to
    /// speak. It breaks when a whole day passes empty, not when the date changes.
    public static func streak(
        _ records: [DictationRecord], today: Date, calendar: Calendar = .current
    ) -> Int {
        guard !records.isEmpty else { return 0 }

        let days = Set(records.map { calendar.startOfDay(for: $0.timestamp) })
        let startOfToday = calendar.startOfDay(for: today)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)

        var cursor: Date
        if days.contains(startOfToday) {
            cursor = startOfToday
        } else if let yesterday, days.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}
