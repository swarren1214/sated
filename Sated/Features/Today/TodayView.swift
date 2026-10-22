import SwiftData
import SwiftUI

/// Today: calories left, the four macros, a summary, and the day's meals. The calendar button
/// and a sideways swipe move to other days, so earlier meals can be logged or fixed.
struct TodayView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.hearthDuoPose) private var pose
    @State private var showsCalendar = false
    // iPhone Duo (DUO.md). Kept here, above the pose-specific layouts and outside DayLog (which
    // is rebuilt for each day), so opening, closing or folding the phone never loses them.
    /// The meal whose nutrients show beside the diary in Open wide.
    @State private var selectedMeal: Meal?
    @State private var showsVoiceLog = false
    @State private var showsLabelScan = false
    @State private var showsCoachVoice = false
    @State private var showsBoard = false
    @State private var paywallFeature: HearthPaywallFeature?
    @State private var purchases = HearthPurchases.shared

    /// Say It (paid): the voice logging screen, or the paywall.
    private func sayIt() {
        if purchases.isUnlocked { showsVoiceLog = true } else { paywallFeature = SatedPlans.sayIt }
    }

    /// Talking to Coach (paid): the hands-free voice screen, or the paywall.
    private func askCoach() {
        if purchases.isUnlocked { showsCoachVoice = true } else { paywallFeature = SatedPlans.coach }
    }

    var body: some View {
        DayLog(day: router.day, selectedMeal: $selectedMeal, actions: TodayDuoActions(sayIt: { sayIt() }, askCoach: { askCoach() }))
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
                if pose == .outer {
                    // iPhone Duo, closed: "Just say it". Scan a Label is the rail's one action;
                    // the day, the glance board and Profile wait in the overflow menu.
                    ToolbarItem(placement: .primaryAction) {
                        Button("Scan a Label", systemImage: "text.viewfinder") { showsLabelScan = true }
                            // White over the color header.
                            .tint(.white)
                    }
                    ToolbarItemGroup(placement: .secondaryAction) {
                        Button("Choose Day", menuIcon: "calendar") { showsCalendar = true }
                        Button("What Still Fits", menuIcon: "flame") { showsBoard = true }
                        Button("Profile", menuIcon: "person.crop.circle") { HearthProfilePresenter.shared.show() }
                    }
                } else {
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
                        }
                        // White over the color header.
                        .tint(.white)
                        // The profile photo, last, as in every Hearth app (HearthProfile.swift).
                        HearthProfileButton()
                    }
                    if pose == .openWide {
                        // iPhone Duo, open wide: Add Food and Log by Voice on the trailing rail.
                        ToolbarItemGroup(placement: .primaryAction) {
                            Group {
                                Button("Add Food", systemImage: "plus") { router.addFood(to: selectedMeal) }
                                if OnDeviceModel.isOffered {
                                    Button("Log by Voice", systemImage: "mic") { sayIt() }
                                }
                            }
                            .tint(.white)
                        }
                    }
                    if pose == .laptop {
                        // iPhone Duo, set down: the counter board, for when it's stood up.
                        ToolbarItem(placement: .primaryAction) {
                            HearthGlanceBoardButton(title: "What Still Fits", systemImage: "flame") { showsBoard = true }
                                .tint(.white)
                        }
                    }
                }
            }
            .sheet(isPresented: $showsCalendar) {
                DayPicker()
                    .presentationDetents([.medium, .large])
            }
            // Presented here, above every pose's layout, so a meal half-said on the outer display
            // is still on screen when the phone opens.
            .fullScreenCover(isPresented: $showsVoiceLog) {
                // Open wide: the meal chosen in the diary, as Add Food on the rail does.
                VoiceLogView(meal: pose == .openWide ? (selectedMeal ?? .suggested()) : .suggested(), onType: { router.addFood() })
            }
            .fullScreenCover(isPresented: $showsLabelScan) {
                ScannerView(meal: .suggested(), startingMode: .label)
            }
            .fullScreenCover(isPresented: $showsCoachVoice) {
                CoachVoiceView()
            }
            .fullScreenCover(isPresented: $showsBoard) {
                WhatStillFitsBoard()
            }
            .hearthPaywall(
                isPresented: Binding(get: { paywallFeature != nil }, set: { if !$0 { paywallFeature = nil } }),
                feature: paywallFeature
            )
    }
}

/// What the iPhone Duo layouts inside a day can ask Today to open.
struct TodayDuoActions {
    var sayIt: () -> Void = {}
    var askCoach: () -> Void = {}
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
                    SheetCancelButton("Close") { dismiss() }
                }
                // Not a confirm button, so not in the confirm spot (AGENT.md).
                ToolbarItem(placement: .primaryAction) {
                    Button("Today", systemImage: "arrow.uturn.backward") {
                        router.show(.now)
                        dismiss()
                    }
                    .tint(.primary)
                    .disabled(router.isToday)
                }
            }
        }
    }
}

/// One day's log. Its query is fixed to that day.
private struct DayLog: View {
    let day: Date
    @Binding var selectedMeal: Meal?
    var actions: TodayDuoActions
    @Query private var entries: [FoodEntry]
    @Environment(AppRouter.self) private var router
    @Environment(HealthService.self) private var health
    @Environment(FoodDatabase.self) private var database
    @State private var bigTable = BigTableMeals.shared
    @State private var plannedPick: PlannedPick?
    @State private var purchases = HearthPurchases.shared
    @AppStorage(SettingsKey.goalCalories) private var goalCalories = Goals.defaults.calories
    @AppStorage(SettingsKey.goalProtein) private var goalProtein = Goals.defaults.protein
    @AppStorage(SettingsKey.goalCarbs) private var goalCarbs = Goals.defaults.carbs
    @AppStorage(SettingsKey.goalFat) private var goalFat = Goals.defaults.fat
    @AppStorage(SettingsKey.goalFiber) private var goalFiber = Goals.defaults.fiber

    init(day: Date, selectedMeal: Binding<Meal?>, actions: TodayDuoActions) {
        self.day = day
        _selectedMeal = selectedMeal
        self.actions = actions
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
    @Environment(\.hearthDuoPose) private var pose

    var body: some View {
        poseLayout
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

    /// iPhone Duo: each pose's mode of the same day (DUO.md). Everything else gets `standard`.
    @ViewBuilder
    private var poseLayout: some View {
        switch pose {
        case .outer:
            // Closed: "Just say it". Voice first, then the day's meals.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if OnDeviceModel.isOffered {
                        SayItCard(action: actions.sayIt)
                    }
                    meals
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        case .openWide:
            // Open wide: "Diary and nutrients". The meals lead; the chosen meal's nutrients trail.
            HearthFoldSplit(axes: .horizontal) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        diary
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            } secondary: {
                ScrollView {
                    MealNutrientsPane(meal: shownMeal, entries: entries.filter { $0.meal == shownMeal }, dayTotals: totals, day: day)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
            }
        case .book where OnDeviceModel.isOffered:
            // Partly folded, held: "Meals beside Coach". The day on the left page, Coach on the right.
            HearthFoldSplit {
                ScrollView { standard }
            } secondary: {
                CoachPagePane(askOutLoud: actions.askCoach)
            }
        case .laptop where OnDeviceModel.isOffered:
            // Partly folded, set down: "Coach at the counter".
            CoachCounterView(askOutLoud: actions.askCoach)
        default:
            ScrollView { standard }
        }
    }

    /// The meal the Open wide nutrients pane shows: the chosen one, else the one for now.
    private var shownMeal: Meal { selectedMeal ?? Meal.suggested() }

    /// Today's usual layout: on a wide window the numbers on the left and the meals on the right.
    private var standard: some View {
            Group {
                // Folded (Book), each page is half the screen: the stacked iPhone layout.
                if sizeClass == .regular && !pose.isFolded {
                    // iPad: the day's numbers on the left, its meals on the right.
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        HearthBillingBanner()
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
                        HearthBillingBanner()
                        overview
                        meals
                    }
                }
            }
            .padding(.horizontal, sizeClass == .regular && !pose.isFolded ? 24 : 16)
            .padding(.bottom, 24)
    }

    /// Open wide's leading pane: the day's numbers in one line, then the meals to choose from.
    private var diary: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Diary")
            Text("\(Int(totals.calories.rounded()).formatted()) of \(Int(goals.calories).formatted()) kcal · \(Grams.text(totals.protein)) g protein")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Meal.allCases) { meal in
                    let items = entries.filter { $0.meal == meal }
                    Button {
                        selectedMeal = meal
                    } label: {
                        DiaryMealRow(meal: meal, entries: items, isSelected: meal == shownMeal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(meal == shownMeal ? .isSelected : [])
                    if meal != Meal.allCases.last {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        }
    }

    /// The day's name ("Today", "Yesterday"…) in white over the color header, with its date.
    private var header: some View {
        HeaderTitle(router.dayTitle, subtitle: day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
    }

    /// Whether BigTable planned anything still open today, for the Hearth+ teaser.
    private var hasOpenPlannedMeal: Bool {
        Meal.allCases.contains { meal in
            guard entries.allSatisfy({ $0.meal != meal }), let planned = bigTable.plannedMeal(on: day, for: meal) else { return false }
            return !planned.isLogged(in: entries)
        }
    }

    /// What BigTable planned for an empty meal, and its estimate when it has recipes. Logging
    /// BigTable's plan is the apps working together, so it's Hearth+.
    private func plan(for meal: Meal, entries: [FoodEntry]) -> (meal: HearthMealPlan.Meal, estimate: MealEstimate?)? {
        guard purchases.hasHearthPlus, entries.isEmpty, let planned = bigTable.plannedMeal(on: day, for: meal),
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
            .hearthTourTarget(SatedTour.today)

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
                    .tint(.primary)
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
            // Without Hearth+, one quiet note where BigTable's plan would have shown.
            if !purchases.hasHearthPlus, hasOpenPlannedMeal {
                HearthPlusTeaser(from: .bigtable, title: SatedPlans.plannedMealTeaserTitle, detail: SatedPlans.plannedMealTeaserDetail)
                    .padding(.top, 8)
            }
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
                            .foregroundStyle(.secondary)
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

// MARK: - iPhone Duo pieces

/// Closed (outer display): "Just say it". One big target that opens Say It, so a meal can be
/// logged one-handed. The transcript and the foods it found stay on screen in Say It to check.
private struct SayItCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Accent.color.gradient, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Say What You Ate")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Like “two eggs and toast for breakfast”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

/// Open wide's diary row: a meal, its calories and foods, highlighted when chosen.
private struct DiaryMealRow: View {
    var meal: Meal
    var entries: [FoodEntry]
    var isSelected: Bool

    private var calories: Double { entries.reduce(0) { $0 + $1.nutrients.calories } }

    var body: some View {
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
                Text(entries.isEmpty ? "Not logged yet" : entries.map(\.name).joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(isSelected ? Color(.tertiarySystemFill) : .clear)
        .contentShape(.rect)
    }
}

/// Open wide's trailing pane: the chosen meal's nutrients in an even two-column grid (at every
/// width), its foods, and the meal screen one level deeper.
private struct MealNutrientsPane: View {
    var meal: Meal
    var entries: [FoodEntry]
    var dayTotals: Nutrients
    var day: Date

    private var totals: Nutrients { entries.reduce(.zero) { $0 + $1.nutrients } }

    private var shareOfDay: String {
        guard dayTotals.calories > 0 else { return "0%" }
        return (totals.calories / dayTotals.calories).formatted(.percent.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(meal.name)
            // Always two columns, so the grid never splits a tile at the fold.
            LazyVGrid(columns: HearthEvenColumns.flexible(2), spacing: 12) {
                tile("Calories", Int(totals.calories.rounded()).formatted(), unit: "kcal", color: nil)
                tile("Share of Day", shareOfDay, unit: "", color: nil)
                ForEach(Macro.allCases) { macro in
                    tile(macro.name, Grams.text(macro.value(in: totals)), unit: "g", color: macro.color)
                }
            }
            if entries.isEmpty {
                Text("Not logged yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).lineLimit(1)
                                Text(entry.amountText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(Int(entry.nutrients.calories.rounded()))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        if entry.id != entries.last?.id { Divider().padding(.leading, 16) }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                NavigationLink {
                    MealView(meal: meal, day: day)
                } label: {
                    Label("Edit \(meal.name)", systemImage: "pencil")
                }
                .tint(.primary)
                .padding(.horizontal, 4)
            }
        }
        .padding(.top, 8)
    }

    private func tile(_ title: String, _ value: String, unit: String, color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let color {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                }
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("\(Text(value).font(.title2.bold())) \(Text(unit).font(.footnote).foregroundStyle(.secondary))")
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
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
