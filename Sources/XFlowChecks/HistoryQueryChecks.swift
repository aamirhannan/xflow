import Foundation
import XFlowCore

func checkHistoryQuery() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let reference = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12))!

    func record(daysAgo: Int, raw: String, cleaned: String) -> DictationRecord {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: reference)!
        return DictationRecord(
            timestamp: day, durationSeconds: 10, rawText: raw, cleanedText: cleaned
        )
    }

    let rbac = record(daysAgo: 0, raw: "मुझे RBAC चाहिए", cleaned: "Mujhe RBAC chahiye")
    let audit = record(daysAgo: 1, raw: "the audit trail", cleaned: "The audit trail.")
    let cafe = record(daysAgo: 4, raw: "meet at the cafe", cleaned: "Meet at the café.")
    let all = [rbac, audit, cafe]

    Checks.equal(HistoryQuery.matching("", in: all), all, "an empty query returns everything")
    Checks.equal(HistoryQuery.matching("   ", in: all), all,
                 "a whitespace-only query returns everything")

    Checks.equal(HistoryQuery.matching("rbac", in: all), [rbac],
                 "matching ignores case")
    Checks.equal(HistoryQuery.matching("cafe", in: all), [cafe],
                 "matching ignores diacritics, so cafe finds café")

    // The whole point of storing both transcripts: a phrase remembered in the
    // original script still finds the record the list shows romanized.
    Checks.equal(HistoryQuery.matching("मुझे", in: all), [rbac],
                 "a phrase present only in the raw transcript still matches")

    Checks.equal(HistoryQuery.matching("nothing here", in: all), [],
                 "a query matching nothing returns nothing")

    let groups = HistoryQuery.groupedByDay(all, today: reference, calendar: calendar)
    Checks.equal(groups.count, 3, "three different days make three groups")
    Checks.equal(groups.map(\.title).prefix(2).map { $0 }, ["Today", "Yesterday"],
                 "the two most recent days are named rather than dated")
    // The third title is a formatted date, which depends on the machine locale,
    // so assert only what is stable about it.
    Checks.check(
        groups.count == 3 && !groups[2].title.isEmpty
            && groups[2].title != "Today" && groups[2].title != "Yesterday",
        "an older day gets a formatted date rather than a name"
    )
    Checks.equal(groups.map(\.records.count), [1, 1, 1], "each day holds its own record")

    // Order must survive grouping: the store hands over newest first and the
    // screen shows newest first.
    Checks.equal(groups.first?.records.first?.id, rbac.id,
                 "the newest record stays first")

    let twoToday = [
        record(daysAgo: 0, raw: "first", cleaned: "First."),
        record(daysAgo: 0, raw: "second", cleaned: "Second."),
        audit,
    ]
    let sameDay = HistoryQuery.groupedByDay(twoToday, today: reference, calendar: calendar)
    Checks.equal(sameDay.count, 2, "two records on one day make one group, not two")
    Checks.equal(sameDay.first?.records.count, 2, "both of that day's records land in it")

    Checks.equal(HistoryQuery.groupedByDay([], today: reference, calendar: calendar), [],
                 "no records means no groups")
}
