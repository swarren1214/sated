import SwiftData
import SwiftUI

// iPhone Duo modes that put Coach beside the day (see DUO.md):
// - Book ("Meals beside Coach"): `CoachPagePane` is the right page, the day is the left page.
// - Laptop ("Coach at the counter"): `CoachCounterView`, Coach's suggestion on the upright half,
//   what's left today, the mic and Log to Dinner on the flat half.
// - Tent ("What still fits"): `WhatStillFitsBoard`, two numbers to read from the stove.
// Every mode reads the same CoachEngine conversation and the same SwiftData log, so logging in
// one pose shows in every other one.

extension CoachEngine {
    /// Coach's latest reply that suggested foods (the plate "Log to Dinner" logs).
    var latestSuggestion: CoachMessage? {
        messages.last(where: { $0.role == .coach && !$0.foods.isEmpty })
    }

    /// Coach's latest reply of any kind.
    var latestReply: CoachMessage? {
        messages.last(where: { $0.role == .coach })
    }

    /// Logs a suggested plate to today's current meal (Coach's plates always go to today), one
    /// serving of each food, and marks it logged.
    func logSuggestion(_ message: CoachMessage, in context: ModelContext) {
        guard !message.logged else { return }
        let meal = Meal.suggested()
        for food in message.foods {
            FoodLog.add(food, servings: 1, meal: meal, date: .now, in: context)
        }
        markLogged(message)
    }
}

/// Today's totals against the goals, for the modes that show "what's left today" whatever day
/// Today is showing (Coach's plates always go to today).
private struct TodayLeft {
    var totals: Nutrients
    var goals: Goals

    var calories: Double { goals.calories - totals.calories }
    var protein: Double { goals.protein - totals.protein }
    var carbs: Double { goals.carbs - totals.carbs }
    var fat: Double { goals.fat - totals.fat }
}

// MARK: - Book: the conversation as the right page

/// The Coach conversation as a page: messages above, Ask Coach at the bottom, clear of the fold.
/// Uses the same conversation as the Coach tab.
struct CoachPagePane: View {
    /// Opens the hands-free voice screen (presented by Today, so it survives a change of pose).
    var askOutLoud: () -> Void

    @Environment(CoachEngine.self) private var coach
    @Environment(\.modelContext) private var context
    @State private var purchases = HearthPurchases.shared
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private static let composerHeight: CGFloat = 44
    private static let buttonSize: CGFloat = 36

    init(askOutLoud: @escaping () -> Void) {
        self.askOutLoud = askOutLoud
    }

    var body: some View {
        VStack(spacing: 0) {
            if purchases.isUnlocked {
                messages
                composer
            } else {
                ScrollView {
                    HearthLockedCard(feature: SatedPlans.coach)
                        .padding(16)
                }
            }
        }
        .onAppear { if purchases.isUnlocked { coach.prewarm() } }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if coach.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            OnDeviceBadge()
                            Text("Ask Coach what to eat next. Its suggestions sit beside your day, and Log to \(Meal.suggested().name) adds them right away.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if coach.availability != .available {
                                Text(coach.availability.message)
                                    .font(.subheadline)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(coach.messages) { message in
                        MessageBubble(message: message) {
                            coach.logSuggestion(message, in: context)
                        }
                        .id(message.id)
                    }
                    if coach.isThinking {
                        HStack {
                            ProgressView()
                                .padding(14)
                                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                            Spacer()
                        }
                        .id("thinking")
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: coach.messages.count) {
                guard let last = coach.messages.last?.id else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: coach.isThinking) { _, thinking in
                if thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    /// Ask Coach: the same field and buttons as the Coach tab.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Coach", text: $draft, axis: .vertical)
                .lineLimit(1...3)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(minHeight: Self.composerHeight)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.composerHeight / 2))

            if draft.isEmpty {
                Button {
                    composerFocused = false
                    askOutLoud()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Accent.color, in: .circle)
                .padding(.bottom, (Self.composerHeight - Self.buttonSize) / 2)
                .accessibilityLabel("Ask out loud")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Accent.color, in: .circle)
                .padding(.bottom, (Self.composerHeight - Self.buttonSize) / 2)
                .disabled(coach.isThinking)
                .opacity(coach.isThinking ? 0.5 : 1)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await coach.send(text) }
    }
}

// MARK: - Laptop: Coach at the counter

/// Propped up while cooking: Coach's suggestion reads on the upright half; the flat half has
/// what's left today, the mic (the main way in when hands are busy) and Log to Dinner.
struct CoachCounterView: View {
    var askOutLoud: () -> Void

    @Environment(CoachEngine.self) private var coach
    @Environment(\.modelContext) private var context
    @State private var purchases = HearthPurchases.shared
    @Query private var todayEntries: [FoodEntry]
    @AppStorage(SettingsKey.goalCalories) private var goalCalories = Goals.defaults.calories
    @AppStorage(SettingsKey.goalProtein) private var goalProtein = Goals.defaults.protein
    @AppStorage(SettingsKey.goalCarbs) private var goalCarbs = Goals.defaults.carbs
    @AppStorage(SettingsKey.goalFat) private var goalFat = Goals.defaults.fat
    @AppStorage(SettingsKey.goalFiber) private var goalFiber = Goals.defaults.fiber

    init(askOutLoud: @escaping () -> Void) {
        self.askOutLoud = askOutLoud
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        _todayEntries = Query(filter: #Predicate<FoodEntry> { $0.date >= start && $0.date < end }, sort: \.date)
    }

    private var left: TodayLeft {
        TodayLeft(
            totals: todayEntries.reduce(.zero) { $0 + $1.nutrients },
            goals: Goals(calories: goalCalories, protein: goalProtein, carbs: goalCarbs, fat: goalFat, fiber: goalFiber)
        )
    }

    private static let starter = "What should I eat for dinner?"

    var body: some View {
        HearthFoldOverlay {
            controls
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HeaderTitle("Coach", subtitle: "At the counter")
                    suggestion
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .onAppear { if purchases.isUnlocked { coach.prewarm() } }
    }

    /// The upright half: Coach's latest suggestion, in large type.
    @ViewBuilder
    private var suggestion: some View {
        if !purchases.isUnlocked {
            HearthLockedCard(feature: SatedPlans.coach)
        } else if coach.isThinking {
            Card {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Coach is thinking…").font(.title3)
                }
            }
        } else if let message = coach.latestSuggestion {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message.text)
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(message.foods) { food in
                            HStack {
                                Text(food.name).font(.headline)
                                Spacer()
                                Text("\(Int(food.calories.rounded())) kcal")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 9)
                            if food.id != message.foods.last?.id { Divider() }
                        }
                    }
                    Text(message.suggestedTotals.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let reply = coach.latestReply {
            Card {
                Text(reply.text)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ask Coach what to make with what's left today. Tap the mic and talk; your hands can stay busy.")
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    if coach.availability != .available {
                        Text(coach.availability.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(Self.starter) {
                            Task { await coach.send(Self.starter) }
                        }
                        .buttonStyle(.glass)
                        .tint(.primary)
                    }
                }
            }
        }
    }

    /// The flat half: what's left today, the mic, and Log to Dinner.
    private var controls: some View {
        let message = coach.latestSuggestion
        let remaining = self.left
        return VStack(alignment: .leading, spacing: 14) {
            Text("Left Today")
                .font(.headline)
            HStack(spacing: 8) {
                LeftFigure(title: "Calories", value: remaining.calories, unit: "kcal")
                LeftFigure(title: "Protein", value: remaining.protein, unit: "g")
                LeftFigure(title: "Carbs", value: remaining.carbs, unit: "g")
                LeftFigure(title: "Fat", value: remaining.fat, unit: "g")
            }
            HStack(spacing: 16) {
                Button(action: askOutLoud) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Accent.color.gradient, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(!purchases.isUnlocked)
                .opacity(purchases.isUnlocked ? 1 : 0.5)
                .accessibilityLabel("Ask Coach out loud")

                Button {
                    if let message { coach.logSuggestion(message, in: context) }
                } label: {
                    Label(message?.logged == true ? "Logged" : "Log to \(Meal.suggested().name)", systemImage: "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(message == nil || message?.logged == true)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// "1,160 kcal / Calories": one number of what's left today.
private struct LeftFigure: View {
    var title: String
    var value: Double
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Text(Int(value.rounded()).formatted()).font(.title2.bold())) \(Text(unit).font(.footnote).foregroundStyle(.secondary))")
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tent: what still fits

/// The board for the outer display standing on the counter: calories and protein left today,
/// readable from the stove. The check logs Coach's latest suggestion.
struct WhatStillFitsBoard: View {
    @Environment(CoachEngine.self) private var coach
    @Environment(\.modelContext) private var context
    @Query private var todayEntries: [FoodEntry]
    @AppStorage(SettingsKey.goalCalories) private var goalCalories = Goals.defaults.calories
    @AppStorage(SettingsKey.goalProtein) private var goalProtein = Goals.defaults.protein

    init() {
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        _todayEntries = Query(filter: #Predicate<FoodEntry> { $0.date >= start && $0.date < end }, sort: \.date)
    }

    private var totals: Nutrients { todayEntries.reduce(.zero) { $0 + $1.nutrients } }

    /// Coach's latest suggestion, while it's still to be logged.
    private var pending: CoachMessage? {
        guard let message = coach.latestSuggestion, !message.logged else { return nil }
        return message
    }

    /// Calories and protein left today, as two big figures.
    @ViewBuilder
    private func figures(caloriesLeft: Double, proteinLeft: Double) -> some View {
        HearthGlanceFigure(
            value: Int(abs(caloriesLeft).rounded()).formatted(),
            label: caloriesLeft >= 0 ? "kcal left" : "kcal over"
        )
        HearthGlanceFigure(
            value: Int(max(proteinLeft, 0).rounded()).formatted(),
            label: "g protein to go"
        )
    }

    var body: some View {
        let caloriesLeft = goalCalories - totals.calories
        let proteinLeft = goalProtein - totals.protein
        HearthGlanceBoard("What Still Fits", color: Accent.color) {
            VStack(spacing: 16) {
                GeometryReader { proxy in
                    if proxy.size.width > proxy.size.height {
                        HStack(spacing: 32) { figures(caloriesLeft: caloriesLeft, proteinLeft: proteinLeft) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 24) { figures(caloriesLeft: caloriesLeft, proteinLeft: proteinLeft) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let pending {
                    Text("Coach suggests \(pending.foods.map(\.name).joined(separator: ", ")) · \(Int(pending.suggestedTotals.calories.rounded())) kcal")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
        } actions: {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    if let pending { coach.logSuggestion(pending, in: context) }
                } label: {
                    Label("Log Coach's Suggestion to \(Meal.suggested().name)", systemImage: "checkmark")
                }
                .disabled(pending == nil)
            }
        }
    }
}
