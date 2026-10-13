import Foundation
import FoundationModels
import OSLog
import SwiftData

// MARK: - What the coach can look up

/// Answers the coach's tool calls from the person's own log and the bundled food list.
/// Everything stays on the iPhone.
@MainActor
final class CoachData {
    private let container: ModelContainer
    private let database: FoodDatabase

    init(container: ModelContainer, database: FoodDatabase) {
        self.container = container
        self.database = database
    }

    private var goals: Goals { Goals.load() }

    private func records(daysBack: Int, calendar: Calendar = .current) -> [EntryRecord] {
        let from = calendar.date(byAdding: .day, value: -daysBack, to: .now) ?? .now
        return Persistence.entries(from: from, through: .now, in: container.mainContext).map(\.record)
    }

    func day(daysAgo: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        let entries = Persistence.entries(from: date, through: date, in: container.mainContext)
        let goals = goals
        let totals = entries.reduce(Nutrients.zero) { $0 + $1.nutrients }
        let label = daysAgo == 0 ? "Today" : daysAgo == 1 ? "Yesterday" : date.formatted(.dateTime.weekday(.wide).month().day())
        guard !entries.isEmpty else { return "\(label): nothing logged." }
        var lines = ["\(label) totals: \(totals.summary)."]
        lines.append("Goals: \(Int(goals.calories)) kcal, \(Int(goals.protein)) g protein, \(Int(goals.carbs)) g carbs, \(Int(goals.fat)) g fat, \(Int(goals.fiber)) g fiber.")
        if daysAgo == 0 {
            lines.append("Left today: \(Int((goals.calories - totals.calories).rounded())) kcal, \(Grams.text(goals.protein - totals.protein)) g protein, \(Grams.text(goals.fiber - totals.fiber)) g fiber.")
            let logged = Set(entries.map(\.meal))
            let open = Meal.allCases.filter { !logged.contains($0) }
            if !open.isEmpty { lines.append("Meals not logged yet: \(open.map(\.name).joined(separator: ", ")).") }
        }
        for meal in Meal.allCases {
            let items = entries.filter { $0.meal == meal }
            guard !items.isEmpty else { continue }
            lines.append("\(meal.name): " + items.map { "\($0.name) (\($0.amountText), \(Int($0.nutrients.calories.rounded())) kcal)" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    func week(calendar: Calendar = .current) -> String {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: .now) ?? .now
        let start = calendar.date(byAdding: .day, value: -6, to: yesterday) ?? yesterday
        let days = Summaries.days(records(daysBack: 7), from: start, through: yesterday, calendar: calendar)
        let stats = PeriodStats(days: days, goals: goals)
        var lines = days.map { day in
            "\(day.date.formatted(.dateTime.weekday(.abbreviated))): " + (day.isLogged ? day.totals.summary : "not logged")
        }
        lines.append("Summary: " + Summaries.weekText(stats, calendar: calendar))
        return lines.joined(separator: "\n")
    }

    func foods(matching query: String) -> String {
        let matches = database.search(query, limit: 4)
        guard !matches.isEmpty else { return "No foods match \"\(query)\"." }
        return matches.map { "\($0.name), \($0.servingText): \($0.nutrients.summary)" }.joined(separator: "\n")
    }

    func food(named name: String) -> FoodItem? {
        database.food(id: name) ?? database.search(name, limit: 1).first
    }
}

// MARK: - Tools

nonisolated struct DayTotalsTool: Tool {
    let name = "getDayTotals"
    let description = "Gets the person's logged food and totals for one day, compared with their goals."
    let data: CoachData

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "0 for today, 1 for yesterday, up to 30", .range(0...30))
        var daysAgo: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await data.day(daysAgo: arguments.daysAgo)
    }
}

nonisolated struct WeekTool: Tool {
    let name = "getLastSevenDays"
    let description = "Gets daily totals for the last 7 finished days, with averages and the biggest gap."
    let data: CoachData

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Always true")
        var includeAverages: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        await data.week()
    }
}

nonisolated struct FoodLookupTool: Tool {
    let name = "lookupFood"
    let description = "Looks up nutrition for a food in the USDA database. Use it before suggesting any food or giving any food's numbers."
    let data: CoachData

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "A short generic food name, for example \"salmon\" or \"black beans\"")
        var food: String
    }

    func call(arguments: Arguments) async throws -> String {
        await data.foods(matching: arguments.food)
    }
}

// MARK: - Replies

@Generable
nonisolated struct CoachReply {
    @Guide(description: "The reply to show, in 1 to 4 short, friendly sentences. Every number must come from a tool result.")
    var text: String

    @Guide(description: "When recommending foods to eat, the exact food names from lookupFood results, as written there before the comma. Otherwise empty.", .maximumCount(4))
    var suggestedFoods: [String]
}

struct CoachMessage: Identifiable, Hashable {
    enum Role { case user, coach, notice }

    let id = UUID()
    var role: Role
    var text: String
    /// Foods the coach suggested, which the person can log in one tap.
    var foods: [FoodItem] = []
    var logged = false

    var suggestedTotals: Nutrients { foods.reduce(.zero) { $0 + $1.nutrients } }
}

/// The Coach conversation, on Apple's on-device model with tools over the person's log.
@Observable
final class CoachEngine {
    private(set) var messages: [CoachMessage] = []
    private(set) var isThinking = false

    private let data: CoachData
    private var session: LanguageModelSession?
    private let log = Logger(subsystem: "com.stephenwarren.sated", category: "coach")

    init(data: CoachData) {
        self.data = data
    }

    var availability: OnDeviceModel.Availability { OnDeviceModel.availability }

    static let instructions = """
    You are Coach, the nutrition assistant inside Sated, a calorie and macro tracking app. \
    You help one person understand what they've eaten and plan what to eat next.

    Rules:
    - Get every number from a tool. Call getDayTotals, getLastSevenDays or lookupFood before stating any calorie or gram amount. Never estimate or invent numbers.
    - Before suggesting foods, call lookupFood for each one and fit the suggestion to what's left today.
    - Keep replies short, plain and encouraging. No lectures.
    - Don't diagnose, treat or give medical advice. If asked about a medical condition, eating disorder, pregnancy or medication, suggest talking with a doctor or registered dietitian.
    - Never recommend eating below 1,200 kcal a day or skipping meals to make up for a big day.
    - Only discuss food, nutrition and the person's log.
    """

    func prewarm() {
        guard availability == .available, session == nil else { return }
        let session = makeSession()
        session.prewarm()
        self.session = session
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            tools: [DayTotalsTool(data: data), WeekTool(data: data), FoodLookupTool(data: data)],
            instructions: Self.instructions
        )
    }

    func send(_ text: String) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        messages.append(CoachMessage(role: .user, text: question))

        guard availability == .available else {
            messages.append(CoachMessage(role: .notice, text: availability.message))
            return
        }
        isThinking = true
        defer { isThinking = false }

        do {
            let reply = try await respond(to: question, retrying: true)
            let foods = reply.suggestedFoods.compactMap { data.food(named: $0) }
            messages.append(CoachMessage(role: .coach, text: reply.text, foods: foods))
        } catch {
            log.error("Coach failed: \(String(describing: error), privacy: .public)")
            messages.append(CoachMessage(role: .notice, text: Self.message(for: error)))
        }
    }

    private func respond(to question: String, retrying: Bool) async throws -> CoachReply {
        let session = self.session ?? makeSession()
        self.session = session
        do {
            return try await session.respond(to: question, generating: CoachReply.self, options: GenerationOptions(temperature: 0.4)).content
        } catch {
            // A long conversation filled the model's context: start a fresh session and ask again.
            guard retrying, Self.isContextFull(error) else { throw error }
            self.session = makeSession()
            return try await respond(to: question, retrying: false)
        }
    }

    private static func isContextFull(_ error: Error) -> Bool {
        guard let error = error as? LanguageModelSession.GenerationError else { return false }
        if case .exceededContextWindowSize = error { return true }
        return false
    }

    static func message(for error: Error) -> String {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                return "Coach can't help with that one. Ask about your food, your goals or what to eat next."
            case .exceededContextWindowSize:
                return "This conversation got too long. Tap Clear and ask again."
            default:
                break
            }
        }
        return "Coach couldn't answer just now. Try asking again."
    }

    func markLogged(_ message: CoachMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].logged = true
    }

    func reset() {
        messages = []
        session = nil
    }
}
