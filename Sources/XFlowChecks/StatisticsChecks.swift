import Foundation
import XFlowCore

func checkStatistics() {
    // A fixed calendar and timezone: startOfDay depends on both, and a check
    // that passes only in one timezone is worse than no check.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!

    // 2 March 2026, chosen so "three days back" crosses a month boundary.
    let reference = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12))!

    func record(daysAgo: Int, text: String = "one two three", seconds: Double = 10) -> DictationRecord {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: reference)!
        return DictationRecord(
            timestamp: day, durationSeconds: seconds, rawText: text, cleanedText: text
        )
    }

    Checks.equal(Statistics.totalWords([]), 0, "no records means no words")
    Checks.equal(
        Statistics.totalWords([record(daysAgo: 0), record(daysAgo: 1)]), 6,
        "words are summed across records"
    )

    Checks.equal(Statistics.totalSpeechSeconds([]), 0, "no records means no speech time")
    Checks.equal(
        Statistics.totalSpeechSeconds([record(daysAgo: 0, seconds: 12.5), record(daysAgo: 1, seconds: 7.5)]),
        20, "speech seconds are summed across records"
    )

    // A brand new user must not be shown "0.0h".
    Checks.equal(Statistics.formattedSpeechTime(seconds: 0), "0m", "no speech reads as zero minutes")
    Checks.equal(Statistics.formattedSpeechTime(seconds: 600), "10m", "under an hour reads in minutes")
    Checks.equal(Statistics.formattedSpeechTime(seconds: 3600), "1.0h", "an hour reads in hours")
    Checks.equal(Statistics.formattedSpeechTime(seconds: 15_120), "4.2h", "hours carry one decimal")

    Checks.equal(Statistics.streak([], today: reference, calendar: calendar), 0,
                 "no records is no streak")
    Checks.equal(
        Statistics.streak([record(daysAgo: 0)], today: reference, calendar: calendar), 1,
        "dictating today alone is a streak of one"
    )
    Checks.equal(
        Statistics.streak(
            [record(daysAgo: 0), record(daysAgo: 1), record(daysAgo: 2)],
            today: reference, calendar: calendar
        ), 3,
        "three consecutive days ending today is a streak of three"
    )

    // The rule that stops a streak zeroing itself every morning: nothing today,
    // but yesterday counts, so the streak is alive and reads back from yesterday.
    Checks.equal(
        Statistics.streak(
            [record(daysAgo: 1), record(daysAgo: 2), record(daysAgo: 3)],
            today: reference, calendar: calendar
        ), 3,
        "a streak survives the day after the last dictation"
    )

    // A whole empty day breaks it.
    Checks.equal(
        Statistics.streak(
            [record(daysAgo: 2), record(daysAgo: 3)],
            today: reference, calendar: calendar
        ), 0,
        "a full day with no dictation breaks the streak"
    )

    // Several dictations in one day are still one day.
    Checks.equal(
        Statistics.streak(
            [record(daysAgo: 0), record(daysAgo: 0), record(daysAgo: 1)],
            today: reference, calendar: calendar
        ), 2,
        "two dictations on the same day count as one day"
    )

    // daysAgo 0,1,2 from 2 March reaches 28 February — the arithmetic must not
    // assume every month has 31 days or that February is fixed length.
    Checks.equal(
        Statistics.streak(
            [record(daysAgo: 0), record(daysAgo: 1), record(daysAgo: 2), record(daysAgo: 3)],
            today: reference, calendar: calendar
        ), 4,
        "a streak counts across a month boundary"
    )

    // A gap in the middle does not extend the streak past it.
    Checks.equal(
        Statistics.streak(
            [record(daysAgo: 0), record(daysAgo: 1), record(daysAgo: 5)],
            today: reference, calendar: calendar
        ), 2,
        "an older cluster does not join the streak across a gap"
    )
}
