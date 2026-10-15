import AppIntents
import Foundation

// Siri, Shortcuts, Spotlight and the Action button.
//
// The intents are `nonisolated` value types that only hold parameters; the work happens on the
// main actor in `IntentActions`. Everything runs without opening the app, except Open Add Food.

// MARK: - Meal

nonisolated enum MealOption: String, AppEnum {
    case breakfast, lunch, snack, dinner

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meal"
    static let caseDisplayRepresentations: [MealOption: DisplayRepresentation] = [
        .breakfast: DisplayRepresentation(title: "Breakfast", image: .init(systemName: "sunrise.fill")),
        .lunch: DisplayRepresentation(title: "Lunch", image: .init(systemName: "sun.max.fill")),
        .snack: DisplayRepresentation(title: "Snack", image: .init(systemName: "carrot.fill")),
        .dinner: DisplayRepresentation(title: "Dinner", image: .init(systemName: "moon.stars.fill")),
    ]

    var meal: Meal { Meal(rawValue: rawValue) ?? .snack }
}

// MARK: - Usual food

/// One of the person's usual foods, as Siri and Shortcuts see it.
nonisolated struct UsualFoodEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Usual Food"
    static let defaultQuery = UsualFoodQuery()

    var id: String
    var food: WatchFood

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(food.name)",
            subtitle: "\(food.amountText) · \(Int(food.totalCalories.rounded())) kcal"
        )
    }

    init(_ food: WatchFood) {
        id = food.id
        self.food = food
    }
}

nonisolated struct UsualFoodQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [UsualFoodEntity] {
        await IntentActions.usuals(ids: identifiers).map(UsualFoodEntity.init)
    }

    /// The usuals for the meal it is now, offered first in Shortcuts and Spotlight.
    func suggestedEntities() async throws -> [UsualFoodEntity] {
        await IntentActions.usuals(for: .suggested()).map(UsualFoodEntity.init)
    }
}

// MARK: - Log my usual

nonisolated struct LogUsualIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Usual"
    static let description = IntentDescription("Logs one of the foods you usually have at a meal.")
    /// Not from the Lock Screen: Apple Health can't be written while the phone is locked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Meal")
    var meal: MealOption?

    @Parameter(title: "Food")
    var food: UsualFoodEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Log usual \(\.$food) for \(\.$meal)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let meal = meal?.meal ?? .suggested()
        let chosen: WatchFood
        if let food {
            chosen = food.food
        } else {
            let usuals = await IntentActions.usuals(for: meal).prefix(6).map(UsualFoodEntity.init)
            switch usuals.count {
            case 0:
                return .result(dialog: "You don't have a usual \(meal.name.lowercased()) yet. Log a few and I'll learn it.")
            case 1:
                chosen = usuals[0].food
            default:
                let picked: UsualFoodEntity? = try await $food.requestDisambiguation(
                    among: usuals,
                    dialog: "Which usual \(meal.name.lowercased())?"
                )
                guard let picked else { throw $food.needsValueError() }
                chosen = picked.food
            }
        }
        let status = await IntentActions.log([chosen], meal: meal)
        return .result(dialog: "Logged \(chosen.name), \(Int(chosen.totalCalories.rounded())) calories. \(status.spoken)")
    }
}

// MARK: - Log food by saying it

nonisolated struct LogFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Food"
    static let description = IntentDescription("Logs what you ate from a description, like “two eggs and toast for breakfast”.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "What You Ate", requestValueDialog: "What did you eat?")
    var text: String

    @Parameter(title: "Meal")
    var meal: MealOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$text)") {
            \.$meal
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await IntentActions.parse(text)
        if let error = reply.error {
            return .result(dialog: "\(error)")
        }
        guard !reply.foods.isEmpty else {
            let missing = ListFormatter.localizedString(byJoining: reply.unmatched)
            return .result(dialog: missing.isEmpty
                ? "I didn't catch any foods in that. Try naming each food and how much."
                : "I couldn't find \(missing). Try saying it another way.")
        }
        let target = meal?.meal ?? reply.meal.flatMap(Meal.init(rawValue:)) ?? .suggested()
        let question = SpokenFoods.confirmation(reply.foods, meal: target, unmatched: reply.unmatched)
        try await requestConfirmation(result: .result(dialog: "\(question)"), confirmationActionName: .add)
        let status = await IntentActions.log(reply.foods, meal: target)
        return .result(dialog: "Logged. \(status.spoken)")
    }
}

// MARK: - Calories left

nonisolated struct CaloriesLeftIntent: AppIntent {
    static let title: LocalizedStringResource = "Calories Left Today"
    static let description = IntentDescription("Tells you how many calories and how much protein you have left today.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let status = await IntentActions.today()
        return .result(value: Int(status.caloriesLeft.rounded()), dialog: "\(status.spoken)")
    }
}

// MARK: - Open Add Food

nonisolated struct OpenAddFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Add Food"
    static let description = IntentDescription("Opens Sated to Add Food.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AppRouter.shared.show(.now)
            AppRouter.shared.addFood()
        }
        return .result()
    }
}

// MARK: - Siri phrases

nonisolated struct SatedShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogUsualIntent(),
            phrases: [
                "Log my usual \(\.$meal) in \(.applicationName)",
                "Log my usual \(\.$meal) with \(.applicationName)",
                "Log my usual in \(.applicationName)",
                "\(.applicationName) log my usual",
            ],
            shortTitle: "Log Usual",
            systemImageName: "star.fill"
        )
        AppShortcut(
            intent: LogFoodIntent(),
            phrases: [
                "Log food in \(.applicationName)",
                "Log a meal in \(.applicationName)",
                "Tell \(.applicationName) what I ate",
                "\(.applicationName) log food",
            ],
            shortTitle: "Log Food",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: CaloriesLeftIntent(),
            phrases: [
                "How many calories do I have left in \(.applicationName)",
                "How am I doing in \(.applicationName)",
                "\(.applicationName) calories left",
            ],
            shortTitle: "Calories Left",
            systemImageName: "flame.fill"
        )
        AppShortcut(
            intent: OpenAddFoodIntent(),
            phrases: [
                "Open Add Food in \(.applicationName)",
                "Add food in \(.applicationName)",
            ],
            shortTitle: "Add Food",
            systemImageName: "plus.circle.fill"
        )
    }
}
