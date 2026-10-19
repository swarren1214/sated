import SwiftData
import SwiftUI

/// Add Food: search the bundled foods, scan, say it, or quick add. It's the tab bar's search
/// tab, so iOS draws it as the separate round + button and opens it with the field ready.
struct AddFoodView: View {
    @Environment(AppRouter.self) private var router
    @Environment(FoodDatabase.self) private var database
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(SettingsKey.goalCalories) private var goalCalories = Goals.defaults.calories
    @AppStorage(SettingsKey.goalProtein) private var goalProtein = Goals.defaults.protein
    @AppStorage(SettingsKey.goalFiber) private var goalFiber = Goals.defaults.fiber
    /// Recent entries; the selected day's are picked out for "Fits what's left".
    @Query private var recentEntries: [FoodEntry]

    @State private var query = ""
    @State private var meal: Meal = .suggested()
    @State private var path = NavigationPath()
    @State private var nearby = NearbyPlaces.shared
    @State private var bigTable = BigTableMeals.shared
    @State private var plannedPick: PlannedPick?
    @State private var showsScanner = false
    @State private var showsVoice = false
    @State private var showsQuickAdd = false
    @State private var purchases = HearthPurchases.shared
    /// A paid feature tapped without Sated Plus or Hearth+.
    @State private var paywallFeature: HearthPaywallFeature?

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

    /// Entries on the day being logged.
    private var dayEntries: [FoodEntry] {
        recentEntries.filter { Calendar.current.isDate($0.date, inSameDayAs: router.day) }
    }

    /// A restaurant BigTable named, as the place it was logged under before (so Your Spots and
    /// "last time here" count it), else as BigTable named it.
    private func known(_ place: Place) -> Place {
        let name = HearthNames.normalized(place.name)
        guard let earlier = recentEntries
                .filter({ HearthNames.normalized($0.placeName ?? "") == name })
                .max(by: { $0.date < $1.date }),
              let placeName = earlier.placeName else { return place }
        return Place(id: earlier.placeID ?? placeName, name: placeName, kind: place.kind)
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
                        // What BigTable planned for this meal, ready to log in a tap; or,
                        // when it planned eating out, that restaurant's menu.
                        if let planned = bigTable.plannedMeal(on: router.day, for: meal),
                           !planned.isLogged(in: dayEntries) {
                            if !purchases.hasHearthPlus {
                                // Logging BigTable's plan is the apps working together: Hearth+.
                                HearthPlusTeaser(from: .bigtable, title: SatedPlans.plannedMealTeaserTitle, detail: SatedPlans.plannedMealTeaserDetail)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                            } else if let place = planned.restaurant {
                                PlannedMealCard(meal: planned, estimate: nil) {
                                    path.append(EatOutRoute.place(known(place)))
                                }
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                            } else if let estimate = bigTable.estimate(for: planned, database: database) {
                                PlannedMealCard(meal: planned, estimate: estimate) {
                                    plannedPick = PlannedPick(meal: planned, estimate: estimate)
                                }
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                            }
                        }

                        QuickActions(
                            scan: { showsScanner = true },
                            voice: OnDeviceModel.isOffered ? {
                                if purchases.isUnlocked { showsVoice = true } else { paywallFeature = SatedPlans.sayIt }
                            } : nil,
                            quickAdd: { showsQuickAdd = true },
                            eatOut: {
                                if purchases.isUnlocked { path.append(EatOutRoute.restaurants) } else { paywallFeature = SatedPlans.restaurantMenus }
                            }
                        )
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)

                        if purchases.isUnlocked, let here = nearby.here {
                            HereCard(place: here, hasMenu: nearby.hasMenu[here.name])
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .transition(.opacity)
                        }
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
                        Text("Nutrition from USDA FoodData Central, stored on your \(DeviceName.current) so search works offline.")
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
            // A comfortable width on iPad, on the same background as the list.
            .frame(maxWidth: sizeClass == .regular ? 820 : .infinity)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
            // Recent and "Fits what's left" come from the log in iCloud.
            .refreshable { await CloudRefresh.refresh() }
            .navigationTitle("Add Food")
            .navigationSubtitle(router.isToday ? "" : "Adding to \(router.day.formatted(.dateTime.weekday(.wide).month().day()))")
            .navigationDestination(for: FoodItem.self) { food in
                FoodDetailView(food: food, meal: meal) { router.finishAdding() }
            }
            .navigationDestination(for: EatOutRoute.self) { route in
                switch route {
                case .restaurants:
                    if purchases.isUnlocked { RestaurantsView() } else { EatOutLockedView(place: nil) }
                case .place(let place):
                    RestaurantMenuView(place: place, meal: meal) { router.finishAdding() }
                case .estimate(let place):
                    EstimateMealView(place: place, meal: meal) { router.finishAdding() }
                }
            }
            .task {
                // "You're at…" only when location is already allowed: Add Food never asks.
                // Menus are Sated Plus or Hearth+, so nobody else is asked about places.
                if Places.isAuthorized, purchases.isUnlocked { await nearby.refresh() }
            }
            .animation(.snappy, value: nearby.here)
            .fullScreenCover(isPresented: $showsScanner) {
                ScannerView(meal: meal) { router.finishAdding() }
            }
            .fullScreenCover(isPresented: $showsVoice) {
                VoiceLogView(meal: meal, onAdded: { router.finishAdding() })
            }
            .sheet(isPresented: $showsQuickAdd) {
                QuickAddView(meal: meal) { router.finishAdding() }
            }
            .sheet(item: $plannedPick) { pick in
                PlannedMealSheet(pick: pick, meal: meal) { router.finishAdding() }
            }
            .hearthPaywall(
                isPresented: Binding(get: { paywallFeature != nil }, set: { if !$0 { paywallFeature = nil } }),
                feature: paywallFeature
            )
            .onAppear {
                // Follows BigTable's plan from here on, and picks up changes made while away.
                bigTable.start()
                bigTable.reload()
                if let preset = router.mealForNextEntry {
                    meal = preset
                    router.mealForNextEntry = nil
                }
                // Today's planned "eating out" row: straight to that restaurant's menu.
                if let place = router.restaurantForNextEntry {
                    router.restaurantForNextEntry = nil
                    path = NavigationPath([EatOutRoute.place(known(place))])
                }
            }
        }
        // On the tab's NavigationStack, where iOS 26 expects the search tab's field.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
        .onChange(of: router.tab) { _, tab in
            // Leaving the tab resets it, so the next visit starts at the search.
            if tab != .add {
                path = NavigationPath()
                query = ""
            }
        }
        // Screenshot mode (Debug): the keyboard put away, and the requested screen pushed.
        .task {
            guard ScreenshotMode.isOn else { return }
            try? await Task.sleep(for: .milliseconds(600))
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            switch ScreenshotMode.screen {
            case .food?:
                meal = .dinner
                for _ in 0..<50 where !database.isLoaded {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let food = database.food(id: ScreenshotSeed.detailFoodID) { path.append(food) }
            case .eatout?:
                path.append(EatOutRoute.restaurants)
            case .menu?:
                meal = .lunch
                path.append(EatOutRoute.place(ScreenshotMode.harvest))
            case .estimate?:
                meal = .dinner
                path.append(EatOutRoute.estimate(ScreenshotMode.nonna))
            default:
                break
            }
        }
    }
}

private struct QuickActions: View {
    var scan: () -> Void
    var voice: (() -> Void)?
    var quickAdd: () -> Void
    var eatOut: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            tile("Scan", symbol: "barcode.viewfinder", colors: [Color(hex: 0x1FA2C9), Color(hex: 0x1F5FD6)], action: scan)
            if let voice {
                tile("Say It", symbol: "waveform", colors: [Color(hex: 0xA44BE0), Color(hex: 0xD6336C)], action: voice)
            }
            tile("Quick Add", symbol: "plus", colors: [Color(hex: 0xF08A1C), Color(hex: 0xD9441A)], action: quickAdd)
            tile("Eat Out", symbol: "fork.knife", colors: [Color(hex: 0x30C48D), Color(hex: 0x0E8A8A)], action: eatOut)
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

/// "You're at Casa Verde": one tap to its menu, or to Estimate when it doesn't publish one.
private struct HereCard: View {
    var place: Place
    var hasMenu: Bool?

    var body: some View {
        NavigationLink(value: EatOutRoute.place(place)) {
            HStack(spacing: 12) {
                PlaceBadge(place: place, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're at")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(place.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(hasMenu == false ? "Estimate your meal" : "Log from the menu")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
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
