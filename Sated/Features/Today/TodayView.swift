import SwiftData
import SwiftUI

/// Today: calories left, the four macros, a summary, and the day's meals. The calendar button
/// and a sideways swipe move to other days, so earlier meals can be logged or fixed.
struct TodayView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppRouter.self) private var router
    @State private var showsSettings = false
    @State private var showsCalendar = false

    var body: some View {
        DayLog(day: router.day)
            .id(router.day)
            .transition(.opacity)
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.5,
                              abs(value.translation.width) > 80 else { return }
                        withAnimation(.snappy) { router.move(byDays: value.translation.width > 0 ? -1 : 1) }
                    }
            )
            // The day's name and date are drawn large in the content (see DayLog).
            .colorHeader(router.dayTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Group {
                        StreakBadge()
                    }
                    // White over the color header.
                    .tint(.white)
                }
                // The badge draws its own glass capsule, sized to its contents.
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Group {
                        Button("Choose Day", systemImage: "calendar") { showsCalendar = true }
                        Button("Settings", systemImage: "person.crop.circle") { showsSettings = true }
                    }
                    // White over the color header.
                    .tint(.white)
                }
            }
            .sheet(isPresented: $showsSettings) {
                NavigationStack { SettingsView() }
            }
            .sheet(isPresented: $showsCalendar) {
                DayPicker()
                    .presentationDetents([.medium, .large])
            }
    }
}

/// The calendar sheet: pick any day up to today, or jump back to today.
private struct DayPicker: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
            DatePicker(
                "Day",
                selection: Binding(get: { router.day }, set: { date in
                    router.show(date)
                    dismiss()
                }),
                in: ...Date.now,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
            }
            .navigationTitle("Choose a Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Today") {
                        router.show(.now)
                        dismiss()
                    }
                    .disabled(router.isToday)
                }
            }
        }
    }
}

/// One day's log. Its query is fixed to that day.
private struct DayLog: View {
    let day: Date
    @Query private var entries: [FoodEntry]
    @Environment(AppRouter.self) private var router
    @Environment(HealthService.self) private var health
    @Environment(FoodDatabase.self) private var database
    @State private var bigTable = BigTableMeals.shared
    @State private var plannedPick: PlannedPick?
    @AppStorage(SettingsKey.goalCalories) private var goalCalories = Goals.defaults.calories
    @AppStorage(SettingsKey.goalProtein) private var goalProtein = Goals.defaults.protein
    @AppStorage(SettingsKey.goalCarbs) private var goalCarbs = Goals.defaults.carbs
    @AppStorage(SettingsKey.goalFat) private var goalFat = Goals.defaults.fat
    @AppStorage(SettingsKey.goalFiber) private var goalFiber = Goals.defaults.fiber

    init(day: Date) {
        self.day = day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        _entries = Query(filter: #Predicate<FoodEntry> { $0.date >= day && $0.date < end }, sort: \.date)
    }

    private var goals: Goals {
        Goals(calories: goalCalories, protein: goalProtein, carbs: goalCarbs, fat: goalFat, fiber: goalFiber)
    }

    private var totals: Nutrients { entries.reduce(.zero) { $0 + $1.nutrients } }

    private var openMeals: [Meal] {
        let logged = Set(entries.map(\.meal))
        return Meal.allCases.filter { !logged.contains($0) }
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            Group {
                if sizeClass == .regular {
                    // iPad: the day's numbers on the left, its meals on the right.
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 22) { overview }
                                .frame(maxWidth: .infinity)
                            meals
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .readableWidth(1100)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        overview
                        meals
                    }
                }
            }
            .padding(.horizontal, sizeClass == .regular ? 24 : 16)
            .padding(.bottom, 24)
        }
        // The color header and gray background come from TodayView.
        // Pull to refresh: the latest from iCloud, and BigTable's plan.
        .refreshable {
            bigTable.reload()
            await CloudRefresh.refresh()
        }
        .onAppear {
            // BigTable's plan shows on empty meals; follow it from here on.
            bigTable.start()
            bigTable.reload()
        }
        .sheet(item: $plannedPick) { pick in
            PlannedMealSheet(pick: pick, meal: Meal(rawValue: pick.meal.slot) ?? .dinner) {}
        }
    }

    /// The day's name ("Today", "Yesterday"…) in white over the color header, with its date.
    private var header: some View {
        HeaderTitle(router.dayTitle, subtitle: day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
    }

    /// What BigTable planned for an empty meal, and its estimate when it has recipes.
    private func plan(for meal: Meal, entries: [FoodEntry]) -> (meal: HearthMealPlan.Meal, estimate: MealEstimate?)? {
        guard entries.isEmpty, let planned = bigTable.plannedMeal(on: day, for: meal),
              !planned.isLogged(in: self.entries) else { return nil }
        return (planned, planned.isDineOut ? nil : bigTable.estimate(for: planned, database: database))
    }

    /// Log the planned meal: servings first, or the restaurant's menu when eating out.
    private func logPlanned(_ planned: HearthMealPlan.Meal, estimate: MealEstimate?, as meal: Meal) {
        if let estimate {
            plannedPick = PlannedPick(meal: planned, estimate: estimate)
        } else if let place = planned.restaurant {
            router.restaurantForNextEntry = place
            router.addFood(to: meal)
        } else {
            router.addFood(to: meal)
        }
    }

    @ViewBuilder
    private var overview: some View {
        CalorieCard(totals: totals, goals: goals, active: Calendar.current.isDateInToday(day) ? health.activeEnergyToday : nil)

        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Macros")
            HStack(spacing: 8) {
                ForEach(Macro.allCases) { macro in
                    MacroRingTile(macro: macro, value: macro.value(in: totals), goal: macro.goal(in: goals))
                }
            }
        }

        // The summary talks about what's left, so it's for today only.
        if !entries.isEmpty, Calendar.current.isDateInToday(day) {
            SummaryCard(text: Summaries.dayText(totals: totals, goals: goals, openMeals: openMeals.filter { $0 != .snack }))
        }
    }

    private var meals: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Meals") {
                Button("Add Food", systemImage: "plus") { router.addFood() }
                    .font(.body)
            }
            VStack(spacing: 0) {
                ForEach(Meal.allCases) { meal in
                    let items = entries.filter { $0.meal == meal }
                    if let planned = plan(for: meal, entries: items) {
                        PlannedMealRow(meal: meal, planned: planned.meal, estimate: planned.estimate) {
                            logPlanned(planned.meal, estimate: planned.estimate, as: meal)
                        }
                    } else {
                        MealRow(meal: meal, entries: items, day: day)
                    }
                    if meal != Meal.allCases.last {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        }
    }
}

private struct CalorieCard: View {
    var totals: Nutrients
    var goals: Goals
    var active: Double?

    private var left: Double { goals.calories - totals.calories }

    var body: some View {
        Card(padding: 20) {
            HStack(spacing: 20) {
                ProgressRing(progress: goals.calories > 0 ? totals.calories / goals.calories : 0, lineWidth: 16, color: left < 0 ? .over : nil) {
                    VStack(spacing: 2) {
                        Text(Int(abs(left).rounded()).formatted())
                            .font(.title.bold())
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(left >= 0 ? "KCAL LEFT" : "KCAL OVER")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 136, height: 136)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Calories")
                .accessibilityValue("\(Int(totals.calories.rounded())) of \(Int(goals.calories)) eaten, \(Int(abs(left).rounded())) \(left >= 0 ? "left" : "over")")

                VStack(alignment: .leading, spacing: 12) {
                    stat("Eaten", totals.calories)
                    stat("Goal", goals.calories)
                    if let active {
                        stat("Active · Health", active, symbol: "heart.fill")
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: Double, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.pink).imageScale(.small)
                }
                Text(title)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text("\(Text(Int(value.rounded()).formatted()).font(.title3.weight(.semibold))) \(Text("kcal").font(.footnote).foregroundStyle(.secondary))")
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SummaryCard: View {
    var text: String
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            router.tab = OnDeviceModel.isOffered ? .coach : .trends
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("SUMMARY", systemImage: "sparkles")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tint)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MealRow: View {
    var meal: Meal
    var entries: [FoodEntry]
    var day: Date
    @Environment(AppRouter.self) private var router

    private var calories: Double { entries.reduce(0) { $0 + $1.nutrients.calories } }

    var body: some View {
        if entries.isEmpty {
            Button { router.addFood(to: meal) } label: { row }
                .buttonStyle(.plain)
                .accessibilityLabel("Add food to \(meal.name)")
        } else {
            NavigationLink { MealView(meal: meal, day: day) } label: { row }
                .buttonStyle(.plain)
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            SymbolTile(systemName: meal.symbol)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meal.name)
                    Spacer()
                    if !entries.isEmpty {
                        Text("\(Int(calories.rounded())) kcal")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // An empty meal shows a plus (the whole row adds to it); a logged one opens.
            if entries.isEmpty {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .contentShape(.rect)
    }

    private var subtitle: String {
        guard let first = entries.first else { return "Not logged yet" }
        return "\(first.date.formatted(date: .omitted, time: .shortened)) · " + entries.map(\.name).joined(separator: ", ")
    }
}

/// An empty meal BigTable planned: its photo, "Dinner", and "Sheet-Pan Fajitas · ≈ 540 kcal".
/// The row logs the planned meal; the plus adds something else.
private struct PlannedMealRow: View {
    var meal: Meal
    var planned: HearthMealPlan.Meal
    var estimate: MealEstimate?
    var log: () -> Void
    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            Button(action: log) {
                HStack(spacing: 12) {
                    PlannedMealArtwork(meal: planned, cornerRadius: 10)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(meal.name)
                            Text("BigTable")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(BigTableMeals.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(BigTableMeals.color.opacity(0.14), in: Capsule())
                        }
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(meal.name), planned in BigTable: \(planned.displayTitle)")
            .accessibilityHint(planned.isDineOut ? "Opens the menu" : "Log it")

            Button { router.addFood(to: meal) } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add something else to \(meal.name)")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    /// "Sheet-Pan Fajitas · ≈ 540 kcal", or "Eating out · Café Rio".
    private var subtitle: String {
        if planned.isDineOut { return "Eating out · \(planned.displayTitle)" }
        guard let estimate else { return planned.title }
        return "\(planned.title) · ≈ \(Int(estimate.perServing.calories.rounded())) kcal"
    }
}

/// Days in a row with something logged.
private struct StreakBadge: View {
    @Query private var recent: [FoodEntry]

    init() {
        let start = Calendar.current.date(byAdding: .day, value: -120, to: .now) ?? .now
        _recent = Query(filter: #Predicate<FoodEntry> { $0.date >= start })
    }

    var body: some View {
        let streak = Summaries.streak(recent.map(\.record))
        // Its own capsule, so it widens with the number instead of squeezing into a circle.
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
            Text("\(streak)")
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.body.weight(.semibold))
        // White, like the other controls over the color header.
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(minWidth: 72, minHeight: 44)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Logging streak")
        .accessibilityValue("\(streak) day\(streak == 1 ? "" : "s")")
    }
}

#Preview {
    NavigationStack { TodayView() }
        .previewEnvironment()
}
