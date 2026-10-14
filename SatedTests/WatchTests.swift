import Foundation
import Testing
@testable import Sated

struct WatchTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    /// Wednesday, October 14, 2026 at noon in Denver.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))! }

    func daysAgo(_ days: Int, hour: Int = 8) -> Date {
        let date = calendar.date(byAdding: .day, value: -days, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
    }

    func food(_ name: String, id: String? = nil, servings: Double = 1, calories: Double = 100, place: String? = nil) -> WatchFood {
        WatchFood(
            id: UUID().uuidString, foodID: id, name: name, serving: "1 serving", servings: servings,
            calories: calories, protein: 10, carbs: 0, fat: 0, fiber: 0, source: "usda", placeName: place
        )
    }

    func logged(_ food: WatchFood, _ days: Int, _ meal: Meal = .breakfast, hour: Int = 8) -> Usuals.Logged {
        Usuals.Logged(date: daysAgo(days, hour: hour), meal: meal, food: food)
    }

    // MARK: Usuals

    @Test func ranksByDaysLoggedAtThatMeal() {
        let eggs = food("Eggs", id: "eggs"), oats = food("Oatmeal", id: "oats")
        let usuals = Usuals.rank([
            logged(eggs, 1), logged(eggs, 2), logged(eggs, 3),
            logged(oats, 1), logged(oats, 2),
        ], now: now, calendar: calendar)
        #expect(usuals[.breakfast]?.map(\.name) == ["Eggs", "Oatmeal"])
    }

    @Test func sameDayTwiceCountsOnce() {
        let coffee = food("Coffee", id: "coffee"), toast = food("Toast", id: "toast")
        let usuals = Usuals.rank([
            logged(coffee, 1, hour: 7), logged(coffee, 1, hour: 9), logged(coffee, 1, hour: 10),
            logged(toast, 1), logged(toast, 2),
        ], now: now, calendar: calendar)
        #expect(usuals[.breakfast]?.first?.name == "Toast")
    }

    @Test func recentBeatsOld() {
        let old = food("Bagel", id: "bagel"), new = food("Smoothie", id: "smoothie")
        let usuals = Usuals.rank([
            logged(old, 60), logged(old, 61), logged(old, 62),
            logged(new, 0), logged(new, 1),
        ], now: now, calendar: calendar)
        #expect(usuals[.breakfast]?.first?.name == "Smoothie")
    }

    @Test func usesTheLatestAmount() {
        let usuals = Usuals.rank([
            logged(food("Eggs", id: "eggs", servings: 2), 5),
            logged(food("Eggs", id: "eggs", servings: 3), 1),
        ], now: now, calendar: calendar)
        #expect(usuals[.breakfast]?.first?.servings == 3)
    }

    @Test func otherMealsAreToppedUpWithFavorites() {
        let usuals = Usuals.rank([logged(food("Eggs", id: "eggs"), 1)], now: now, calendar: calendar)
        #expect(usuals[.dinner]?.map(\.name) == ["Eggs"])
        // IDs are unique per meal, so lists don't collide.
        #expect(usuals[.dinner]?.first?.id != usuals[.breakfast]?.first?.id)
    }

    @Test func sameNameAtDifferentPlacesStaysApart() {
        let usuals = Usuals.rank([
            logged(food("Burrito", place: "Chipotle Mexican Grill"), 1, .lunch),
            logged(food("Burrito", place: "Qdoba"), 2, .lunch),
        ], now: now, calendar: calendar)
        #expect(usuals[.lunch]?.count == 2)
    }

    @Test func ignoresEntriesPastTheLookback() {
        let usuals = Usuals.rank([logged(food("Ancient", id: "x"), Usuals.lookback + 5)], now: now, calendar: calendar)
        #expect(usuals[.breakfast]?.isEmpty == true)
    }

    // MARK: Snapshot totals

    func snapshot(day: Date, calories: Double, applied: [UUID] = []) -> WatchSnapshot {
        var snapshot = WatchSnapshot.empty
        snapshot.day = calendar.startOfDay(for: day)
        snapshot.calories = calories
        snapshot.appliedLogIDs = applied
        return snapshot
    }

    @Test func pendingLogsCountUntilThePhoneFilesThem() {
        let request = WatchLogRequest(date: now, meal: "lunch", foods: [food("Salad", servings: 2, calories: 150)])
        let before = snapshot(day: now, calories: 1000)
        #expect(before.totals(on: now, adding: [request], calendar: calendar).calories == 1300)
        // The phone's new totals include it, so it isn't counted twice.
        let after = snapshot(day: now, calories: 1300, applied: [request.id])
        #expect(after.totals(on: now, adding: [request], calendar: calendar).calories == 1300)
    }

    @Test func newDayStartsFromZero() {
        let yesterday = snapshot(day: daysAgo(1), calories: 2200)
        let stale = WatchLogRequest(date: daysAgo(1), meal: "dinner", foods: [food("Pasta", calories: 600)])
        #expect(yesterday.totals(on: now, adding: [stale], calendar: calendar).calories == 0)
    }

    @Test func payloadsRoundTrip() throws {
        let request = WatchLogRequest(date: now, meal: "snack", foods: [food("Apple", id: "apple")])
        let message = try WatchLink.message(.log, request)
        #expect(WatchLink.kind(of: message) == .log)
        #expect(WatchLink.decode(WatchLogRequest.self, from: WatchLink.payload(of: message)) == request)
    }
}
