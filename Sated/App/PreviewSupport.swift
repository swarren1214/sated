import SwiftData
import SwiftUI

extension View {
    /// Supplies the app's services and an in-memory store with a sample day to SwiftUI previews.
    func previewEnvironment() -> some View {
        modifier(PreviewEnvironment())
    }
}

private struct PreviewEnvironment: ViewModifier {
    @State private var router = AppRouter()
    @State private var container: ModelContainer = {
        let container = Persistence.makeContainer(inMemory: true)
        SampleData.insert(into: container.mainContext)
        return container
    }()

    func body(content: Content) -> some View {
        content
            .environment(router)
            .environment(CoachEngine(data: CoachData(container: container, database: .shared)))
            .environment(FoodDatabase.shared)
            .environment(HealthService.shared)
            .modelContainer(container)
            .tint(AccentOption.orange.color)
    }
}

/// The sample log from the design canvas: today's breakfast, lunch and snack, and six earlier
/// days. Previews only.
enum SampleData {
    static func insert(into context: ModelContext, calendar: Calendar = .current) {
        let db = FoodDatabase.shared
        let today = calendar.startOfDay(for: .now)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let date = calendar.date(byAdding: .day, value: -day, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }
        func add(_ id: String, _ meal: Meal, _ date: Date, _ servings: Double = 1) {
            guard let food = db.food(id: id) else { return }
            context.insert(FoodEntry(date: date, meal: meal, name: food.name, servingLabel: food.servingText, servings: servings, perServing: food.nutrients, source: .usda, foodID: food.id))
        }
        add("usda.greek-yogurt-plain-2", .breakfast, at(0, 7, 12))
        add("usda.blueberries", .breakfast, at(0, 7, 12))
        add("usda.granola", .breakfast, at(0, 7, 12))
        add("usda.chicken-breast-grilled", .lunch, at(0, 12, 18))
        add("usda.jasmine-rice-cooked", .lunch, at(0, 12, 18))
        add("usda.avocado", .lunch, at(0, 12, 18), 0.75)
        add("usda.whey-protein-shake", .snack, at(0, 15, 5))
        add("usda.apple", .snack, at(0, 15, 5))
        for day in 1...6 {
            add("usda.large-egg", .breakfast, at(day, 7), 3)
            add("usda.whole-wheat-bread", .breakfast, at(day, 7), 2)
            add("usda.chicken-breast-grilled", .lunch, at(day, 12))
            add("usda.brown-rice-cooked", .lunch, at(day, 12))
            add("usda.broccoli-steamed", .lunch, at(day, 12))
            add("usda.greek-yogurt-plain-nonfat", .snack, at(day, 15))
            add("usda.almonds", .snack, at(day, 15))
            add(day % 3 == 0 ? "usda.cheese-pizza" : "usda.salmon-fillet-baked", .dinner, at(day, 19), day % 3 == 0 ? 3 : 1)
            add("usda.sweet-potato-baked", .dinner, at(day, 19))
        }
        try? context.save()
    }
}
