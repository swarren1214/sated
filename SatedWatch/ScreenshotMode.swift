import Foundation

/// Screenshot mode, for marketing screenshots of the Watch app.
///
/// Launched with `-Screenshots`, the Watch app shows a demo `WatchSnapshot` kept in memory
/// instead of the phone's: today's breakfast, lunch and snack logged with dinner still open (the
/// same day as the iPhone app's screenshots), and a full set of usuals. It doesn't activate
/// WatchConnectivity, and it never reads or writes the saved snapshot or pending logs, so the
/// real data is untouched. Adding `-Screen <name>` opens one screen (see `Screen`). Debug builds
/// only: Release ignores the arguments, so none of this can be reached in the App Store build.
nonisolated enum ScreenshotMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-Screenshots")
        #else
        return false
        #endif
    }()

    /// The screens the script captures, by the name passed after `-Screen`, in order.
    nonisolated enum Screen: String, CaseIterable {
        /// Home: calories left, Say What You Ate, and the usuals for dinner.
        case home
        /// Reviewing a dinner usual before logging it.
        case usual
        /// What was said, worked out into foods and ready to log.
        case say
    }

    static let screen: Screen? = {
        guard isOn else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-Screen"), arguments.indices.contains(index + 1) else { return nil }
        return Screen(rawValue: arguments[index + 1])
    }()

    /// The meal Home shows: dinner, the one still open in the demo day.
    static let meal = Meal.dinner

    /// Where Home goes for the requested screen, pushed once it has settled.
    @MainActor
    static var route: WatchRoute? {
        switch screen {
        case .usual:
            guard let usual = usuals[meal.rawValue]?.first else { return nil }
            return .confirm(foods: [usual], meal: meal)
        case .say:
            return .say(spoken)
        case .home, nil:
            return nil
        }
    }

    // MARK: Demo content

    /// Today, as the phone would send it after the demo person's breakfast, lunch and snack.
    static func snapshot(now: Date = .now, calendar: Calendar = .current) -> WatchSnapshot {
        var snapshot = WatchSnapshot.empty
        snapshot.day = calendar.startOfDay(for: now)
        snapshot.calories = 1490
        snapshot.protein = 98.5
        snapshot.carbs = 127
        snapshot.fat = 67.5
        snapshot.fiber = 26
        snapshot.usuals = usuals
        return snapshot
    }

    /// What's said in the Say It screenshot.
    static let spoken = "Baked salmon with a sweet potato and broccoli"

    /// The phone's answer to `spoken`, given at once in screenshot mode.
    static let parseReply = WatchParseReply(
        meal: Meal.dinner.rawValue,
        foods: [
            food("said.salmon", "Salmon, baked", "6 oz", 400, 40, 0, 24, 0),
            food("said.sweet-potato", "Roasted sweet potato", "1 medium", 160, 3, 37, 0, 6),
            food("said.broccoli", "Steamed broccoli", "1 cup", 55, 4, 11, 0.6, 5),
        ]
    )

    private static let harvest = (id: "demo.harvest-bowl", name: "Harvest Bowl Co.")
    private static let bagels = (id: "demo.sunrise-bagel", name: "Sunrise Bagel Bakery")
    private static let pho = (id: "demo.pho-saigon", name: "Pho Saigon House")

    private static func food(_ id: String, _ name: String, _ serving: String, _ calories: Double, _ protein: Double,
                             _ carbs: Double, _ fat: Double, _ fiber: Double, source: String = "usda",
                             place: (id: String, name: String)? = nil, foodID: String? = nil) -> WatchFood {
        WatchFood(id: "demo.\(id)", foodID: foodID, name: name, brand: place?.name, serving: serving, servings: 1,
                  calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber, source: source,
                  placeID: place?.id, placeName: place?.name)
    }

    /// The demo person's usuals, from the same meals as the iPhone app's demo log.
    private static let usuals: [String: [WatchFood]] = [
        Meal.breakfast.rawValue: [
            food("eggs", "Scrambled eggs", "3 eggs", 270, 19, 2, 20, 0),
            food("yogurt", "Greek yogurt, plain", "1 cup", 130, 23, 9, 0.9, 0),
            food("oats", "Overnight oats with chia", "1 jar", 380, 14, 52, 12, 10),
            food("toast", "Sourdough toast", "1 slice", 140, 5, 27, 1, 1),
            food("avocado", "Avocado", "1/2 avocado", 120, 1.5, 6, 11, 5),
            food("cold-brew", "Cold brew with oat milk", "12 fl oz", 60, 1, 9, 2.5, 1),
            food("bagel", "Everything bagel with lox", "1 bagel", 520, 28, 62, 17, 3, source: "estimate", place: bagels),
            food("latte", "Latte", "12 fl oz", 150, 10, 15, 6, 0),
        ],
        Meal.lunch.rawValue: [
            food("pesto", "Chicken Pesto Grain Bowl", "1 bowl", 690, 52, 60, 26, 9, source: "restaurant", place: harvest, foodID: "hb.pesto.regular"),
            food("poke", "Spicy Salmon Poke Bowl", "1 bowl", 640, 42, 66, 20, 6, source: "restaurant", place: harvest, foodID: "hb.poke.regular"),
            food("wrap", "Turkey avocado wrap", "1 wrap", 560, 40, 44, 23, 8),
            food("burrito-bowl", "Chicken burrito bowl", "1 bowl", 680, 44, 72, 20, 13),
            food("caesar", "Chicken Caesar salad", "1 large", 560, 42, 18, 34, 4),
            food("lentil", "Lentil soup", "1 1/2 cups", 330, 18, 50, 4, 15),
            food("apple", "Apple", "1 medium", 95, 0.5, 25, 0.3, 4.4),
        ],
        Meal.snack.rawValue: [
            food("shake", "Whey protein shake", "1 scoop, 12 fl oz milk", 160, 30, 6, 2, 1),
            food("bar", "Chocolate protein bar", "1 bar", 210, 20, 23, 7, 10),
            food("apple-pb", "Apple with peanut butter", "1 apple, 2 tbsp", 285, 8, 32, 16, 6),
            food("cottage", "Cottage cheese with pineapple", "1 cup", 220, 24, 22, 2.5, 1),
            food("almonds", "Almonds", "1 oz", 165, 6, 6, 14, 3.5),
            food("hummus", "Hummus and carrots", "1/4 cup, 1 cup", 200, 6, 22, 10, 7),
        ],
        Meal.dinner.rawValue: [
            food("quinoa-chicken", "Grilled chicken with quinoa and roasted vegetables", "1 plate", 640, 56, 54, 19, 8),
            food("salmon", "Salmon, baked", "6 oz", 400, 40, 0, 24, 0),
            food("chili", "Turkey chili", "1 1/2 cups", 450, 36, 40, 15, 12),
            food("stir-fry", "Chicken stir-fry with jasmine rice", "1 plate", 680, 52, 76, 16, 5),
            food("tacos", "Steak tacos", "3 tacos", 660, 42, 54, 30, 7),
            food("sweet-potato", "Roasted sweet potato", "1 medium", 160, 3, 37, 0, 6),
            food("broccoli", "Steamed broccoli", "1 cup", 55, 4, 11, 0.6, 5),
            food("pho", "Beef pho", "1 large bowl", 620, 38, 78, 14, 4, source: "estimate", place: pho),
        ],
    ]
}
