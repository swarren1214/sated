import Foundation

/// One calendar day's totals.
nonisolated struct DaySummary: Identifiable, Hashable, Sendable {
    var date: Date
    var totals: Nutrients
    var entryCount: Int

    var id: Date { date }
    var isLogged: Bool { entryCount > 0 }
}

/// How a day's calories compare with the goal: within 10% is on target.
nonisolated enum CalorieStatus: Sendable {
    case under, on, over

    init(calories: Double, goal: Double) {
        if calories > goal * 1.1 { self = .over }
        else if calories < goal * 0.9 { self = .under }
        else { self = .on }
    }
}

/// Averages and hit rates over a run of finished days. The numbers in every summary come from
/// here; the on-device model only words them.
nonisolated struct PeriodStats: Sendable {
    var days: [DaySummary]
    var goals: Goals

    /// Days with at least one entry. Unlogged days are left out of averages.
    var logged: [DaySummary] { days.filter(\.isLogged) }

    var average: Nutrients {
        let logged = logged
        return logged.reduce(Nutrients.zero) { $0 + $1.totals } / Double(logged.count)
    }

    var daysOnTarget: Int { logged.count(where: { CalorieStatus(calories: $0.totals.calories, goal: goals.calories) == .on }) }
    var proteinGoalDays: Int { logged.count(where: { $0.totals.protein >= goals.protein }) }
    var fiberGoalDays: Int { logged.count(where: { $0.totals.fiber >= goals.fiber }) }

    /// Average calories on Saturdays and Sundays, and on the other days.
    func weekdaySplit(calendar: Calendar = .current) -> (weekdays: Nutrients?, weekend: Nutrients?) {
        let weekend = logged.filter { calendar.isDateInWeekend($0.date) }
        let weekdays = logged.filter { !calendar.isDateInWeekend($0.date) }
        func avg(_ list: [DaySummary]) -> Nutrients? {
            list.isEmpty ? nil : list.reduce(Nutrients.zero) { $0 + $1.totals } / Double(list.count)
        }
        return (avg(weekdays), avg(weekend))
    }
}

nonisolated enum Summaries {
    /// One summary per calendar day from `from` through `through`, including days with no entries.
    static func days(_ records: [EntryRecord], from: Date, through: Date, calendar: Calendar = .current) -> [DaySummary] {
        var byDay: [Date: (Nutrients, Int)] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.date)
            let current = byDay[day] ?? (.zero, 0)
            byDay[day] = (current.0 + record.nutrients, current.1 + 1)
        }
        var result: [DaySummary] = []
        var day = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: through)
        while day <= last {
            let value = byDay[day] ?? (.zero, 0)
            result.append(DaySummary(date: day, totals: value.0, entryCount: value.1))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        return result
    }

    /// Consecutive days with at least one entry, counting back from today. A day not yet logged
    /// today doesn't break the streak until it's over.
    static func streak(_ records: [EntryRecord], today: Date = .now, calendar: Calendar = .current) -> Int {
        let logged = Set(records.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: today)
        if !logged.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while logged.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    // MARK: - Written summaries

    /// Today's summary: what's left, and what would close the gaps.
    static func dayText(totals: Nutrients, goals: Goals, openMeals: [Meal]) -> String {
        let caloriesLeft = goals.calories - totals.calories
        let proteinLeft = goals.protein - totals.protein
        let fiberLeft = goals.fiber - totals.fiber
        var parts: [String] = []
        if let next = openMeals.first {
            parts.append("\(next.name) is still open.")
        }
        if caloriesLeft >= 0 {
            parts.append("You have \(Int(caloriesLeft.rounded()).formatted()) kcal left.")
        } else {
            parts.append("You're \(Int((-caloriesLeft).rounded()).formatted()) kcal over today.")
        }
        switch (proteinLeft > 0, fiberLeft > 0) {
        case (true, true):
            parts.append("You need \(Grams.text(proteinLeft)) g protein and \(Grams.text(fiberLeft)) g fiber to reach your goals.")
        case (true, false):
            parts.append("Fiber is done. You need \(Grams.text(proteinLeft)) g more protein.")
        case (false, true):
            parts.append("Protein is done. You need \(Grams.text(fiberLeft)) g more fiber.")
        case (false, false):
            parts.append("Protein and fiber goals are both met.")
        }
        return parts.joined(separator: " ")
    }

    /// The Trends › Week summary, from finished days only.
    static func weekText(_ stats: PeriodStats, calendar: Calendar = .current) -> String {
        let logged = stats.logged
        guard !logged.isEmpty else { return "Log a few days and your weekly summary appears here." }
        let average = stats.average
        let difference = average.calories - stats.goals.calories
        var text = "You averaged \(Int(average.calories.rounded()).formatted()) kcal over \(logged.count) logged day\(logged.count == 1 ? "" : "s"), \(Int(abs(difference).rounded()).formatted()) \(difference >= 0 ? "over" : "under") your goal."
        let split = stats.weekdaySplit(calendar: calendar)
        if let weekdays = split.weekdays, let weekend = split.weekend, abs(weekend.calories - weekdays.calories) > 150 {
            text += " Weekdays averaged \(Int(weekdays.calories.rounded()).formatted()) and the weekend \(Int(weekend.calories.rounded()).formatted())."
        }
        let proteinGap = stats.goals.protein - average.protein
        let fiberGap = stats.goals.fiber - average.fiber
        if fiberGap > 0, fiberGap / stats.goals.fiber >= proteinGap / stats.goals.protein {
            text += " Fiber is your biggest gap at \(Grams.text(average.fiber)) g a day against \(Grams.text(stats.goals.fiber)) g."
        } else if proteinGap > 0 {
            text += " Protein is your biggest gap at \(Grams.text(average.protein)) g a day against \(Grams.text(stats.goals.protein)) g."
        } else {
            text += " You met your protein and fiber averages."
        }
        return text
    }

    /// The Trends › Month summary.
    static func monthText(_ stats: PeriodStats, previousAverage: Double?, calendar: Calendar = .current) -> String {
        let logged = stats.logged
        guard !logged.isEmpty else { return "Nothing logged this month yet." }
        let average = stats.average
        var text = "You've averaged \(Int(average.calories.rounded()).formatted()) kcal this month"
        if let previousAverage, previousAverage > 0 {
            let direction = average.calories <= previousAverage ? "down" : "up"
            text += ", \(direction) from \(Int(previousAverage.rounded()).formatted()) last month"
        }
        text += ", and landed in range on \(stats.daysOnTarget) of \(logged.count) days."
        let misses = logged.filter { CalorieStatus(calories: $0.totals.calories, goal: stats.goals.calories) != .on }
        let missDays = Set(misses.map { calendar.component(.weekday, from: $0.date) })
        if misses.count >= 2, missDays.count == 1, let weekday = missDays.first {
            text += " Every miss was a \(calendar.weekdaySymbols[weekday - 1])."
        }
        text += " Fiber averaged \(Grams.text(average.fiber)) g, and you reached \(Grams.text(stats.goals.fiber)) g on \(stats.fiberGoalDays) day\(stats.fiberGoalDays == 1 ? "" : "s")."
        return text
    }
}
