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
        func add(_ name: String, _ meal: Meal, _ date: Date, _ servings: Double = 1) {
            guard let food = db.foods.first(where: { $0.name == name }) ?? db.search(name, limit: 1).first else { return }
            context.insert(FoodEntry(date: date, meal: meal, name: food.name, servingLabel: food.servingText, servings: servings, perServing: food.nutrients, source: .usda, foodID: food.id))
        }
        add("Yogurt, Greek, whole milk, plain", .breakfast, at(0, 7, 12))
        add("Blueberries, raw", .breakfast, at(0, 7, 12))
        add("Cereal, granola", .breakfast, at(0, 7, 12), 0.5)
        add("Chicken breast, grilled without sauce, skin not eaten", .lunch, at(0, 12, 18))
        add("Rice, white, cooked, no added fat", .lunch, at(0, 12, 18))
        add("Avocado, raw", .lunch, at(0, 12, 18), 3)
        add("Nutritional powder mix, whey based", .snack, at(0, 15, 5))
        add("Apple, raw", .snack, at(0, 15, 5))
        for day in 1...6 {
            add("Egg, whole, fried with oil", .breakfast, at(day, 7), 3)
            add("Bread, whole wheat", .breakfast, at(day, 7), 2)
            add("Chicken breast, grilled without sauce, skin not eaten", .lunch, at(day, 12))
            add("Rice, brown, cooked, no added fat", .lunch, at(day, 12))
            add("Broccoli, fresh, cooked, no added fat", .lunch, at(day, 12))
            add("Yogurt, Greek, nonfat milk, plain", .snack, at(day, 15))
            add("Almonds, unsalted", .snack, at(day, 15))
            add(day % 3 == 0 ? "Pizza, cheese, from restaurant or fast food, medium crust" : "Fish, salmon, baked or broiled", .dinner, at(day, 19), day % 3 == 0 ? 3 : 1)
            add("Sweet potato, baked, no added fat", .dinner, at(day, 19))
        }
        try? context.save()
    }
}
