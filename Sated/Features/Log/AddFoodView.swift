import SwiftData
import SwiftUI

/// Add Food: search the bundled foods, scan, say it, or quick add. It's the tab bar's search
/// tab, so iOS draws it as the separate round + button and opens it with the field ready.
struct AddFoodView: View {
    @Environment(AppRouter.self) private var router
    @Environment(FoodDatabase.self) private var database
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.goalCalories) private var goalCalories = Goals.defaults.calories
    @AppStorage(SettingsKey.goalProtein) private var goalProtein = Goals.defaults.protein
    @AppStorage(SettingsKey.goalFiber) private var goalFiber = Goals.defaults.fiber
    /// Recent entries; the selected day's are picked out for "Fits what's left".
    @Query private var recentEntries: [FoodEntry]

    @State private var query = ""
    @State private var meal: Meal = .suggested()
    @State private var path: [FoodItem] = []
    @State private var showsScanner = false
    @State private var showsVoice = false
    @State private var showsQuickAdd = false

    init() {
        let start = Calendar.current.date(byAdding: .day, value: -120, to: .now) ?? .now
        _recentEntries = Query(filter: #Predicate<FoodEntry> { $0.date >= start })
    }

    private var remaining: Nutrients {
        let eaten = recentEntries
            .filter { Calendar.current.isDate($0.date, inSameDayAs: router.day) }
            .reduce(Nutrients.zero) { $0 + $1.nutrients }
        var goals = Goals.load()
        goals.calories = goalCalories
        goals.protein = goalProtein
        goals.fiber = goalFiber
        return Nutrients(calories: goals.calories - eaten.calories, protein: goals.protein - eaten.protein, carbs: 0, fat: 0, fiber: goals.fiber - eaten.fiber)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Meal", selection: $meal) {
                        ForEach(Meal.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)

                    if query.isEmpty {
                        QuickActions(
                            scan: { showsScanner = true },
                            voice: OnDeviceModel.isOffered ? { showsVoice = true } : nil,
                            quickAdd: { showsQuickAdd = true }
                        )
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }

                if query.isEmpty {
                    let suggested = database.suggestions(remaining: remaining, goals: Goals.load())
                    if !suggested.isEmpty {
                        Section(router.isToday ? "Fits What's Left Today" : "Fits What Was Left") {
                            ForEach(suggested) { FoodRow(food: $0, meal: meal) }
                        }
                    }
                    let recent = FoodLog.recentFoods(in: context)
                    if !recent.isEmpty {
                        Section("Recent") {
                            ForEach(recent) { FoodRow(food: $0, meal: meal) }
                        }
                    }
                    Section {} footer: {
                        Text("Nutrition from USDA FoodData Central, stored on your iPhone so search works offline.")
                    }
                } else {
                    let results = database.search(query)
                    if results.isEmpty {
                        ContentUnavailableView {
                            Label("No Matches", systemImage: "magnifyingglass")
                        } description: {
                            Text("Try a shorter word, scan the barcode, or use Quick Add.")
                        } actions: {
                            Button("Quick Add") { showsQuickAdd = true }
                        }
                    } else {
                        Section("Foods") {
                            ForEach(results) { FoodRow(food: $0, meal: meal) }
                        }
                    }
                }
            }
            .navigationTitle("Add Food")
            .navigationSubtitle(router.isToday ? "" : "Adding to \(router.day.formatted(.dateTime.weekday(.wide).month().day()))")
            .navigationDestination(for: FoodItem.self) { food in
                FoodDetailView(food: food, meal: meal) { router.finishAdding() }
            }
            .fullScreenCover(isPresented: $showsScanner) {
                ScannerView(meal: meal) { router.finishAdding() }
            }
            .fullScreenCover(isPresented: $showsVoice) {
                VoiceLogView(meal: meal) { router.finishAdding() }
            }
            .sheet(isPresented: $showsQuickAdd) {
                QuickAddView(meal: meal) { router.finishAdding() }
            }
            .onAppear {
                if let preset = router.mealForNextEntry {
                    meal = preset
                    router.mealForNextEntry = nil
                }
            }
        }
        // On the tab's NavigationStack, where iOS 26 expects the search tab's field.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
        .onChange(of: router.tab) { _, tab in
            // Leaving the tab resets it, so the next visit starts at the search.
            if tab != .add {
                path = []
                query = ""
            }
        }
    }
}

private struct QuickActions: View {
    var scan: () -> Void
    var voice: (() -> Void)?
    var quickAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            tile("Scan", symbol: "barcode.viewfinder", colors: [Color(hex: 0x1FA2C9), Color(hex: 0x1F5FD6)], action: scan)
            if let voice {
                tile("Say It", symbol: "waveform", colors: [Color(hex: 0xA44BE0), Color(hex: 0xD6336C)], action: voice)
            }
            tile("Quick Add", symbol: "plus", colors: [Color(hex: 0xF08A1C), Color(hex: 0xD9441A)], action: quickAdd)
        }
        .padding(.vertical, 4)
    }

    /// A gradient tile with a white icon over its label, centered both ways.
    private func tile(_ title: String, symbol: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(height: 30)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: 20)
            )
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

/// A food in a list. Tapping opens its details, where the person picks servings and meal
/// before adding it.
struct FoodRow: View {
    var food: FoodItem
    var meal: Meal

    var body: some View {
        NavigationLink(value: food) {
            VStack(alignment: .leading, spacing: 2) {
                Text(food.name)
                Text(food.listDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 2)
        }
    }
}

#Preview {
    AddFoodView()
        .previewEnvironment()
}
