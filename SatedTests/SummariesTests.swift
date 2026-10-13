import Foundation
import Testing
@testable import Sated

struct SummariesTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    /// Monday, October 12, 2026 at 4 PM in Denver.
    var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 16))! }

    func day(_ offset: Int, hour: Int = 12) -> Date {
        let date = calendar.date(byAdding: .day, value: -offset, to: today)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
    }

    func record(_ offset: Int, calories: Double, protein: Double = 0, fiber: Double = 0, hour: Int = 12) -> EntryRecord {
        EntryRecord(id: UUID(), date: day(offset, hour: hour), meal: .lunch, name: "Food", nutrients: Nutrients(calories: calories, protein: protein, fiber: fiber))
    }

    @Test func daysIncludesEmptyDaysAndSumsEachDay() {
        let records = [record(2, calories: 500), record(2, calories: 700, hour: 19), record(0, calories: 300)]
        let days = Summaries.days(records, from: day(2), through: day(0), calendar: calendar)
        #expect(days.count == 3)
        #expect(days[0].totals.calories == 1200)
        #expect(days[0].entryCount == 2)
        #expect(days[1].isLogged == false)
        #expect(days[2].totals.calories == 300)
    }

    @Test func entriesLateAtNightCountForThatDay() {
        let late = record(1, calories: 400, hour: 23)
        let days = Summaries.days([late], from: day(1), through: day(0), calendar: calendar)
        #expect(days[0].totals.calories == 400)
        #expect(days[1].totals.calories == 0)
    }

    @Test func calorieStatusUsesTenPercentBand() {
        #expect(CalorieStatus(calories: 2400, goal: 2400) == .on)
        #expect(CalorieStatus(calories: 2640, goal: 2400) == .on)
        #expect(CalorieStatus(calories: 2641, goal: 2400) == .over)
        #expect(CalorieStatus(calories: 2159, goal: 2400) == .under)
    }

    @Test func averagesSkipUnloggedDays() {
        let records = [record(3, calories: 2000), record(1, calories: 2600)]
        let days = Summaries.days(records, from: day(3), through: day(1), calendar: calendar)
        let stats = PeriodStats(days: days, goals: Goals())
        #expect(stats.logged.count == 2)
        #expect(stats.average.calories == 2300)
    }

    @Test func goalDayCounts() {
        let records = [
            record(3, calories: 2400, protein: 190, fiber: 36),
            record(2, calories: 3000, protein: 150, fiber: 20),
            record(1, calories: 2300, protein: 181, fiber: 30),
        ]
        let stats = PeriodStats(days: Summaries.days(records, from: day(3), through: day(1), calendar: calendar), goals: Goals())
        #expect(stats.daysOnTarget == 2)
        #expect(stats.proteinGoalDays == 2)
        #expect(stats.fiberGoalDays == 1)
    }

    @Test func streakCountsBackFromToday() {
        let records = [record(0, calories: 1), record(1, calories: 1), record(2, calories: 1), record(4, calories: 1)]
        #expect(Summaries.streak(records, today: today, calendar: calendar) == 3)
    }

    @Test func streakSurvivesAnUnloggedMorning() {
        let records = [record(1, calories: 1), record(2, calories: 1)]
        #expect(Summaries.streak(records, today: today, calendar: calendar) == 2)
    }

    @Test func streakIsZeroAfterAMissedDay() {
        let records = [record(2, calories: 1)]
        #expect(Summaries.streak(records, today: today, calendar: calendar) == 0)
    }

    @Test func dayTextNamesWhatsLeft() {
        let totals = Nutrients(calories: 1278, protein: 113, fiber: 16.6)
        let text = Summaries.dayText(totals: totals, goals: Goals(), openMeals: [.dinner])
        #expect(text.contains("Dinner is still open."))
        #expect(text.contains("1,122 kcal left"))
        #expect(text.contains("67 g protein"))
        #expect(text.contains("18 g fiber"))
    }

    @Test func dayTextWhenOver() {
        let text = Summaries.dayText(totals: Nutrients(calories: 2600, protein: 200, fiber: 40), goals: Goals(), openMeals: [])
        #expect(text.contains("200 kcal over"))
        #expect(text.contains("both met"))
    }

    @Test func weekTextWithNothingLogged() {
        let stats = PeriodStats(days: Summaries.days([], from: day(6), through: day(1), calendar: calendar), goals: Goals())
        #expect(Summaries.weekText(stats, calendar: calendar).hasPrefix("Log a few days"))
    }
}

struct NutrientsTests {
    @Test func arithmetic() {
        let a = Nutrients(calories: 100, protein: 10, carbs: 5, fat: 2, fiber: 1)
        let sum = a + a * 2
        #expect(sum.calories == 300)
        #expect(sum.protein == 30)
        #expect((a / 0) == .zero)
    }

    @Test func calorieSplit() {
        let split = Nutrients(calories: 0, protein: 25, carbs: 25, fat: 0).calorieSplit
        #expect(split.protein == 0.5)
        #expect(split.carbs == 0.5)
        #expect(split.fat == 0)
    }

    @Test func gramText() {
        #expect(Grams.text(6.64) == "6.6")
        #expect(Grams.text(113.4) == "113")
        #expect(Grams.text(4) == "4")
    }
}
