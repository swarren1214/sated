import SwiftData
import SwiftUI

/// Screenshot mode, for marketing screenshots (scripts/screenshots.sh).
///
/// Launched with `-Screenshots`, Sated runs on an in-memory store filled with about two months
/// of demo meals, shows demo restaurants instead of asking for location, shows a demo Coach
/// conversation, and keeps the Health permission sheet out of the way. Adding `-Screen <name>`
/// opens one screen (see `Screen`). Debug builds only: Release ignores the arguments, so none
/// of this can be reached in the App Store build.
nonisolated enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()

    /// The screens the script captures, by the name passed after `-Screen`.
    nonisolated enum Screen: String, CaseIterable {
        case today, meal, trends, month, day, coach, add, food, eatout, menu, estimate
    }

    static let screen: Screen? = {
        guard isOn else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-Screen"), arguments.indices.contains(index + 1) else { return nil }
        return Screen(rawValue: arguments[index + 1])
    }()

    /// At launch, before anything reads them: the settings the demo log is written for.
    @MainActor
    static func prepareLaunch() {
        guard isOn else { return }
        let defaults = UserDefaults.standard
        let goals = Goals.defaults
        defaults.set(goals.calories, forKey: SettingsKey.goalCalories)
        defaults.set(goals.protein, forKey: SettingsKey.goalProtein)
        defaults.set(goals.carbs, forKey: SettingsKey.goalCarbs)
        defaults.set(goals.fat, forKey: SettingsKey.goalFat)
        defaults.set(goals.fiber, forKey: SettingsKey.goalFiber)
        defaults.set(true, forKey: SettingsKey.readActiveEnergy)
        defaults.set("orange", forKey: SettingsKey.accent)
    }

    // MARK: Demo restaurants

    /// Around a made-up downtown block. All the names are invented.
    private static let latitude = 40.7596
    private static let longitude = -111.8865

    private static func place(_ id: String, _ name: String, _ kind: String, _ north: Double, _ east: Double, _ distance: Double) -> Place {
        Place(id: "demo.\(id)", name: name, kind: kind, latitude: latitude + north, longitude: longitude + east, distance: distance)
    }

    /// Where the demo person eats lunch, and is standing now. Publishes its menu.
    static let harvest = place("harvest-bowl", "Harvest Bowl Co.", "Restaurant", 0.0001, 0.0001, 18)
    /// Friday dinners. No published menu, so it gets Estimate.
    static let nonna = place("nonna-lucia", "Nonna Lucia Trattoria", "Restaurant", 0.0042, -0.0031, 610)
    static let bagels = place("sunrise-bagel", "Sunrise Bagel Bakery", "Bakery", -0.0018, 0.0022, 340)
    static let pho = place("pho-saigon", "Pho Saigon House", "Restaurant", 0.0026, 0.0041, 520)

    static let places: [Place] = [
        harvest,
        place("copper-kettle", "Copper Kettle Coffee", "Café", 0.0009, -0.0012, 160),
        place("bluebird-taqueria", "Bluebird Taqueria", "Restaurant", -0.0011, -0.0019, 230),
        bagels,
        place("olive-fig", "Olive & Fig Mediterranean", "Restaurant", 0.0021, 0.0008, 290),
        place("sakura-ramen", "Sakura Ramen Bar", "Restaurant", -0.0027, 0.0006, 380),
        place("ember-oak", "Ember & Oak Grill", "Restaurant", 0.0012, 0.0036, 450),
        pho,
        nonna,
    ]

    /// Which demo places publish nutrition ("Full menu").
    static let hasMenu: [String: Bool] = Dictionary(uniqueKeysWithValues: places.map { place in
        (place.name, [harvest.name, "Bluebird Taqueria", "Ember & Oak Grill"].contains(place.name))
    })

    /// The menu `RestaurantStore` returns in screenshot mode: Harvest Bowl Co.'s, or "no menu"
    /// for anywhere else, so nothing is fetched.
    static func menu(for name: String) -> RestaurantMenu {
        let fetched = Date.now.ISO8601Format()
        guard RestaurantStore.key(name) == RestaurantStore.key(harvest.name) else {
            return RestaurantMenu(query: name, restaurant: nil, hasMenu: false, items: [], fetchedAt: fetched, stale: false, attribution: "")
        }
        func item(_ id: String, _ name: String, _ category: String, _ serving: String, _ grams: Double,
                  _ calories: Double, _ protein: Double, _ carbs: Double, _ fat: Double, _ fiber: Double) -> MenuItem {
            MenuItem(id: "hb.\(id)", name: name, category: category, servings: [
                MenuServing(id: "hb.\(id).regular", description: serving, grams: grams, calories: calories,
                            protein: protein, carbs: carbs, fat: fat, fiber: fiber, isDefault: true),
            ])
        }
        // Restaurant nil: the place's own name shows, and no chain logo is looked up.
        return RestaurantMenu(query: name, restaurant: nil, hasMenu: true, items: [
            item("pesto", "Chicken Pesto Grain Bowl", "Bowls", "1 bowl", 460, 690, 52, 60, 26, 9),
            item("poke", "Spicy Salmon Poke Bowl", "Bowls", "1 bowl", 430, 640, 42, 66, 20, 6),
            item("harvest", "Harvest Bowl", "Bowls", "1 bowl", 450, 610, 28, 74, 22, 12),
            item("steak", "Chimichurri Steak Bowl", "Bowls", "1 bowl", 470, 720, 48, 62, 30, 8),
            item("kale-caesar", "Kale Caesar with Chicken", "Salads", "1 salad", 340, 520, 41, 22, 30, 6),
            item("greek", "Greek Chopped Salad", "Salads", "1 salad", 320, 440, 18, 28, 30, 9),
            item("lentil", "Lemony Lentil Soup", "Sides", "1 cup", 240, 210, 13, 32, 3, 11),
            item("flatbread", "Warm Flatbread", "Sides", "1 piece", 60, 160, 5, 28, 3, 1),
            item("lemonade", "Mint Lemonade", "Drinks", "16 fl oz", 480, 120, 0, 31, 0, 0),
            item("iced-tea", "Hibiscus Iced Tea", "Drinks", "16 fl oz", 480, 0, 0, 0, 0, 0),
        ], fetchedAt: fetched, stale: false, attribution: "Nutrition published by Harvest Bowl Co.")
    }

    /// What's already on the plate in the menu screenshot.
    static let plateItemIDs = ["hb.pesto", "hb.lentil"]
}

/// Screens pushed only in screenshot mode (the app reaches them through inline links).
nonisolated enum ScreenshotRoute: Hashable, Sendable {
    case meal(Meal, day: Date)
}

extension View {
    /// Destinations for `ScreenshotRoute`, added to Today's root view.
    func screenshotDestinations() -> some View {
        navigationDestination(for: ScreenshotRoute.self) { route in
            switch route {
            case .meal(let meal, let day): MealView(meal: meal, day: day)
            }
        }
    }

    /// Screenshot mode: fills the store with demo meals, then opens the requested screen.
    /// Does nothing otherwise.
    func screenshotStage(todayPath: Binding<NavigationPath>) -> some View {
        modifier(ScreenshotStage(todayPath: todayPath))
    }
}

private struct ScreenshotStage: ViewModifier {
    @Binding var todayPath: NavigationPath

    @Environment(AppRouter.self) private var router
    @Environment(CoachEngine.self) private var coach
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        if ScreenshotMode.isOn {
            content.task { await stage() }
        } else {
            content
        }
    }

    private func stage() async {
        ScreenshotSeed.seed(context: modelContext, coach: coach)
        // Let the first screen settle before moving on from it.
        try? await Task.sleep(for: .milliseconds(400))
        guard let screen = ScreenshotMode.screen else { return }
        switch screen {
        case .today:
            router.tab = .today
        case .meal:
            router.tab = .today
            todayPath.append(ScreenshotRoute.meal(.breakfast, day: Calendar.current.startOfDay(for: .now)))
        case .trends, .month, .day:
            // TrendsView picks the range for .month and .day.
            router.tab = .trends
        case .coach:
            router.tab = .coach
        case .add, .food, .eatout, .menu, .estimate:
            // AddFoodView pushes the screen for .food, .eatout, .menu and .estimate.
            router.tab = .add
        }
    }
}

// MARK: - Demo content

/// The demo person: two months of home cooking, weekday lunches at Harvest Bowl Co., Sunday
/// bagels, the odd night out, and a protein shake after weekday workouts. Logged every day for
/// the last five weeks. Today has breakfast, lunch and a snack, with dinner still open.
@MainActor
enum ScreenshotSeed {
    /// The food in the food screenshot: grilled chicken breast, skin not eaten.
    static let detailFoodID = "usda.2705968"

    private static var seeded = false

    static func seed(context: ModelContext, coach: CoachEngine) {
        guard ScreenshotMode.isOn, !seeded else { return }
        seeded = true
        seedLog(context: context)
        try? context.save()
        NearbyPlaces.shared.showScreenshotPlaces(ScreenshotMode.places, here: ScreenshotMode.harvest, hasMenu: ScreenshotMode.hasMenu)
        coach.showScreenshotConversation(conversation(context: context))
    }

    // MARK: Foods

    private struct Dish {
        var name: String
        var serving: String
        var nutrients: Nutrients
        var servings: Double = 1
        var source: FoodSource = .quickAdd
        var place: Place? = nil
        var foodID: String? = nil
    }

    private static func dish(_ name: String, _ serving: String, _ calories: Double, _ protein: Double, _ carbs: Double,
                             _ fat: Double, _ fiber: Double, servings: Double = 1, source: FoodSource = .usda,
                             place: Place? = nil, foodID: String? = nil) -> Dish {
        Dish(name: name, serving: serving, nutrients: Nutrients(calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber),
             servings: servings, source: source, place: place, foodID: foodID)
    }

    private static let breakfasts: [[Dish]] = [
        [dish("Greek yogurt, plain", "1 cup", 130, 23, 9, 0.9, 0),
         dish("Blueberries", "1 cup", 84, 1.1, 21, 0.5, 3.6),
         dish("Honey almond granola", "1/3 cup", 200, 5, 30, 7, 3)],
        [dish("Overnight oats with chia", "1 jar", 380, 14, 52, 12, 10),
         dish("Cold brew with oat milk", "12 fl oz", 60, 1, 9, 2.5, 1)],
        [dish("Scrambled eggs", "3 eggs", 270, 19, 2, 20, 0),
         dish("Sourdough toast", "1 slice", 140, 5, 27, 1, 1),
         dish("Avocado", "1/2 avocado", 120, 1.5, 6, 11, 5)],
        [dish("Banana peanut butter protein smoothie", "1 large", 450, 38, 48, 13, 6)],
        [dish("Oatmeal with walnuts and banana", "1 bowl", 410, 11, 62, 14, 8),
         dish("Latte", "12 fl oz", 150, 10, 15, 6, 0)],
    ]

    private static let bagelBreakfast: [Dish] = [
        dish("Everything bagel with lox", "1 bagel", 520, 28, 62, 17, 3, source: .estimate, place: ScreenshotMode.bagels),
        dish("Oat milk latte", "16 fl oz", 190, 3, 26, 8, 1, source: .estimate, place: ScreenshotMode.bagels),
    ]

    private static let harvestLunches: [[Dish]] = [
        [dish("Chicken Pesto Grain Bowl", "1 bowl", 690, 52, 60, 26, 9, source: .restaurant, place: ScreenshotMode.harvest, foodID: "hb.pesto.regular")],
        [dish("Spicy Salmon Poke Bowl", "1 bowl", 640, 42, 66, 20, 6, source: .restaurant, place: ScreenshotMode.harvest, foodID: "hb.poke.regular")],
    ]

    private static let lunches: [[Dish]] = [
        [dish("Turkey avocado wrap", "1 wrap", 560, 40, 44, 23, 8),
         dish("Apple", "1 medium", 95, 0.5, 25, 0.3, 4.4)],
        [dish("Chicken burrito bowl", "1 bowl", 680, 44, 72, 20, 13)],
        [dish("Chicken Caesar salad", "1 large", 560, 42, 18, 34, 4)],
        [dish("Lentil soup", "1 1/2 cups", 330, 18, 50, 4, 15),
         dish("Turkey and Swiss on rye", "1 sandwich", 430, 30, 36, 17, 4)],
    ]

    private static let snacks: [[Dish]] = [
        [dish("Apple with peanut butter", "1 apple, 2 tbsp", 285, 8, 32, 16, 6)],
        [dish("Chocolate protein bar", "1 bar", 210, 20, 23, 7, 10)],
        [dish("Cottage cheese with pineapple", "1 cup", 220, 24, 22, 2.5, 1)],
        [dish("Hummus and carrots", "1/4 cup, 1 cup", 200, 6, 22, 10, 7)],
        [dish("Trail mix", "1/4 cup", 175, 5, 16, 11, 2)],
        [dish("Almonds", "1 oz", 165, 6, 6, 14, 3.5)],
    ]

    private static let shake = dish("Whey protein shake", "1 scoop, 12 fl oz milk", 160, 30, 6, 2, 1)
    private static let dessert = dish("Dark chocolate gelato", "1/2 cup", 240, 4, 28, 13, 1)

    private static let dinners: [[Dish]] = [
        [dish("Salmon, baked", "6 oz", 400, 40, 0, 24, 0),
         dish("Roasted sweet potato", "1 medium", 160, 3, 37, 0, 6),
         dish("Steamed broccoli", "1 cup", 55, 4, 11, 0.6, 5)],
        [dish("Turkey chili", "1 1/2 cups", 450, 36, 40, 15, 12),
         dish("Cornbread", "1 piece", 190, 4, 29, 6, 1)],
        [dish("Chicken stir-fry with jasmine rice", "1 plate", 680, 52, 76, 16, 5)],
        [dish("Spaghetti with turkey meatballs", "1 plate", 720, 42, 86, 20, 8),
         dish("Side salad", "1 bowl", 120, 2, 8, 9, 3)],
        [dish("Steak tacos", "3 tacos", 660, 42, 54, 30, 7),
         dish("Black beans", "1/2 cup", 115, 7.5, 20, 0.5, 7.5)],
        [dish("Grilled chicken with quinoa and roasted vegetables", "1 plate", 640, 56, 54, 19, 8)],
    ]

    private static let nonnaDinner: [Dish] = [
        dish("Chicken parmesan", "1 serving", 520, 38, 32, 26, 3, servings: 1.5, source: .estimate, place: ScreenshotMode.nonna),
        dish("Garlic bread", "1 slice", 190, 5, 24, 8, 1, source: .estimate, place: ScreenshotMode.nonna),
        dish("Tiramisu", "1 piece", 420, 7, 45, 24, 1, source: .estimate, place: ScreenshotMode.nonna),
    ]

    private static let phoDinner: [Dish] = [
        dish("Beef pho", "1 large bowl", 620, 38, 78, 14, 4, source: .estimate, place: ScreenshotMode.pho),
        dish("Fresh spring rolls", "2 rolls", 160, 5, 20, 6, 2, source: .estimate, place: ScreenshotMode.pho),
    ]

    /// Today: breakfast and lunch out, a snack, and dinner still to come.
    private static let todayMeals: [(Meal, Double, [Dish])] = [
        (.breakfast, 7.4, [
            dish("Scrambled eggs", "3 eggs", 270, 19, 2, 20, 0),
            dish("Sourdough toast", "1 slice", 140, 5, 27, 1, 1),
            dish("Avocado", "1/2 avocado", 120, 1.5, 6, 11, 5),
            dish("Cold brew with oat milk", "12 fl oz", 60, 1, 9, 2.5, 1),
        ]),
        (.lunch, 12.3, harvestLunches[0]),
        (.snack, 15.6, snacks[1]),
    ]

    // MARK: The log

    private static func seedLog(context: ModelContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ day: Date, _ hour: Double) -> Date {
            day.addingTimeInterval(hour * 3600)
        }
        func add(_ dishes: [Dish], _ meal: Meal, _ date: Date) {
            for (index, dish) in dishes.enumerated() {
                let entry = FoodEntry(
                    date: date.addingTimeInterval(Double(index) * 60),
                    meal: meal,
                    name: dish.name,
                    brand: dish.place?.name,
                    servingLabel: dish.serving,
                    servings: dish.servings,
                    perServing: dish.nutrients,
                    source: dish.source,
                    foodID: dish.foodID,
                    place: dish.place?.ref
                )
                context.insert(entry)
            }
        }

        for (meal, hour, dishes) in todayMeals {
            add(dishes, meal, at(today, hour))
        }

        for daysAgo in 1...62 {
            // Two missed days, before the current streak.
            if daysAgo == 39 || daysAgo == 53 { continue }
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)  // 1 is Sunday
            let lastMonth = !calendar.isDate(day, equalTo: today, toGranularity: .month)
            let minutes = Double(daysAgo % 3) / 6

            add(weekday == 1 ? bagelBreakfast : breakfasts[(daysAgo * 2) % breakfasts.count], .breakfast, at(day, 7.3 + minutes + (weekday == 1 ? 2 : 0)))
            let lunch = weekday == 3 || weekday == 5 ? harvestLunches[daysAgo % 2] : lunches[daysAgo % lunches.count]
            add(lunch, .lunch, at(day, 12.2 + minutes))

            var snack = daysAgo == 6 ? [] : snacks[(daysAgo * 3) % snacks.count]
            if daysAgo % 4 == 0 { snack += snacks[(daysAgo + 1) % snacks.count] }
            if (2...6).contains(weekday) { snack.append(shake) }
            add(snack, .snack, at(day, 15.5 + minutes))

            let dinner: [Dish]
            if weekday == 6 && (daysAgo / 7) % 2 == 0 {
                dinner = nonnaDinner
            } else if weekday == 7 {
                dinner = phoDinner
            } else {
                dinner = dinners[(daysAgo * 5) % dinners.count]
            }
            add(dinner, .dinner, at(day, 18.75 + minutes))
            // Last month had more dessert; this month's average is lower.
            if lastMonth && [0, 2, 3].contains(daysAgo % 5) {
                add([dessert], .snack, at(day, 20.5))
            }
        }
    }

    // MARK: Coach

    /// A finished conversation whose numbers come from the demo log, as the coach's tools would give them.
    private static func conversation(context: ModelContext) -> [CoachMessage] {
        let calendar = Calendar.current
        let goals = Goals.load()
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekStart = calendar.date(byAdding: .day, value: -6, to: yesterday) ?? yesterday
        let records = Persistence.entries(from: weekStart, through: yesterday, in: context).map(\.record)
        let week = PeriodStats(days: Summaries.days(records, from: weekStart, through: yesterday, calendar: calendar), goals: goals)

        let eaten = Persistence.entries(from: today, through: today, in: context).reduce(Nutrients.zero) { $0 + $1.nutrients }
        let caloriesLeft = Int((goals.calories - eaten.calories).rounded())
        let proteinLeft = goals.protein - eaten.protein

        let plate = [
            FoodItem(id: "demo.salmon", name: "Salmon, baked", serving: "6 oz", grams: 170,
                     nutrients: Nutrients(calories: 400, protein: 40, carbs: 0, fat: 24, fiber: 0), source: .usda),
            FoodItem(id: "demo.sweet-potato", name: "Sweet potato, roasted", serving: "1 medium", grams: 150,
                     nutrients: Nutrients(calories: 160, protein: 3, carbs: 37, fat: 0, fiber: 6), source: .usda),
            FoodItem(id: "demo.broccoli", name: "Broccoli, steamed", serving: "1 cup", grams: 156,
                     nutrients: Nutrients(calories: 55, protein: 4, carbs: 11, fat: 0.6, fiber: 5), source: .usda),
        ]
        let plateTotals = plate.reduce(Nutrients.zero) { $0 + $1.nutrients }

        return [
            CoachMessage(role: .user, text: "Summarize my week"),
            CoachMessage(role: .coach, text: Summaries.weekText(week, calendar: calendar)),
            CoachMessage(role: .user, text: "What should I eat for dinner?"),
            CoachMessage(role: .coach, text: "You have \(caloriesLeft.formatted()) kcal and \(Grams.text(proteinLeft)) g protein left today. Baked salmon with a roasted sweet potato and broccoli comes to \(Int(plateTotals.calories.rounded())) kcal and \(Grams.text(plateTotals.protein)) g protein, and finishes off your fiber.",
                         foods: plate),
        ]
    }
}
