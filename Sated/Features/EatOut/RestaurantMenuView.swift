import SwiftData
import SwiftUI

/// One thing on the plate: a menu item, how it's served, and how many.
nonisolated struct PlateLine: Identifiable, Hashable, Sendable {
    var id = UUID()
    var item: MenuItem
    var serving: MenuServing
    var quantity: Double

    var nutrients: Nutrients { serving.nutrients * quantity }
}

/// A place's menu with nutrition. A saved copy shows at once and is refreshed when it's old;
/// with no connection the saved copy stays up with a note. Places without a published menu
/// get Estimate instead.
struct RestaurantMenuView: View {
    let place: Place
    let meal: Meal
    var onAdded: () -> Void

    @Environment(\.modelContext) private var context
    @State private var result: MenuResult?
    @State private var error: APIError?
    @State private var loading = false
    @State private var query = ""
    @State private var category: String?
    @State private var selected: MenuItem?
    @State private var plate: [PlateLine] = []
    @State private var showsPlate = false
    @State private var usuals: [Usual] = []

    var body: some View {
        Group {
            if let result, !result.menu.hasMenu {
                EstimateMealView(place: place, meal: meal, onAdded: onAdded)
            } else if let result {
                menu(result)
            } else if let error {
                failed(error)
            } else {
                ProgressView("Getting the menu…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                    .navigationTitle(place.name)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await load() }
    }

    // MARK: Loading

    private func load(force: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        usuals = EatingOutHistory.usuals(at: place.ref, in: context)
        if !force, result == nil, let saved = await RestaurantStore.shared.savedMenu(for: place.name) {
            result = saved
            if !RestaurantStore.needsRefresh(saved) { return }
        }
        do {
            let fresh = try await RestaurantStore.shared.menu(for: place.name)
            withAnimation(.snappy) {
                result = fresh
                error = nil
            }
            NearbyPlaces.shared.note(place.name, LookupAnswer(hasMenu: fresh.menu.hasMenu, restaurant: fresh.menu.restaurant))
        } catch is CancellationError {
            return
        } catch {
            let apiError = error as? APIError ?? .unavailable
            if result == nil {
                self.error = apiError
            } else {
                // Keep the saved menu up, and say it may be out of date.
                result?.isOffline = true
            }
        }
    }

    // MARK: Menu

    private var filtered: [MenuItem] {
        guard let items = result?.menu.items else { return [] }
        let text = query.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            !item.servings.isEmpty
                && (category == nil || item.category == category)
                && (text.isEmpty || item.name.localizedStandardContains(text))
        }
    }

    private func menu(_ result: MenuResult) -> some View {
        let restaurant = result.menu.restaurant ?? place.name
        return List {
            Section {
                PlaceHeader(place: place, detail: [place.detail, "Menu nutrition from \(restaurant)"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
                if result.isOffline || result.menu.stale {
                    Label {
                        Text(result.isOffline
                             ? "Showing the menu saved \(result.savedAt.formatted(.relative(presentation: .named))). Pull to try again."
                             : "The menu couldn't be updated just now, so this copy may be a little out of date.")
                    } icon: {
                        Image(systemName: "wifi.exclamationmark")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                InlineSearchField(prompt: "Search the menu", text: $query)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if query.isEmpty, category == nil, !usuals.isEmpty {
                Section(usuals.count == 1 ? "Your Usual" : "Your Usuals") {
                    ForEach(usuals) { usual in
                        UsualRow(usual: usual) { log(usual) }
                    }
                }
            }

            let categories = result.menu.categories
            if categories.count > 1 {
                Section {
                    CategoryChips(categories: categories, selection: $category)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }

            let items = filtered
            if items.isEmpty {
                Section {
                    Text(query.isEmpty ? "Nothing in this part of the menu." : "Nothing on the menu matches “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            } else if category == nil, query.isEmpty, categories.count > 1 {
                ForEach(categories, id: \.self) { name in
                    Section(name) {
                        ForEach(items.filter { $0.category == name }) { row($0) }
                    }
                }
                let uncategorized = items.filter { $0.category == nil }
                if !uncategorized.isEmpty {
                    Section("More") { ForEach(uncategorized) { row($0) } }
                }
            } else {
                Section { ForEach(items) { row($0) } }
            }

            Section {} footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nutrition as \(restaurant) publishes it. Menus change; when something looks off, check with the restaurant.")
                    Link(result.menu.attribution, destination: URL(string: "https://www.fatsecret.com")!)
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .readableWidth(820)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(restaurant)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(force: true) }
        .animation(.snappy, value: category)
        // Screenshot mode (Debug): a bowl and a side already on the plate.
        .task {
            guard ScreenshotMode.isOn, plate.isEmpty else { return }
            plate = result.menu.items
                .filter { ScreenshotMode.plateItemIDs.contains($0.id) }
                .compactMap { item in item.defaultServing.map { PlateLine(item: item, serving: $0, quantity: 1) } }
        }
        .sheet(item: $selected) { item in
            MenuItemSheet(item: item, restaurant: restaurant, meal: meal, place: place.ref, onPlate: { line in
                withAnimation(.snappy) { plate.append(line) }
            }, onAdded: onAdded)
        }
        .sheet(isPresented: $showsPlate) {
            PlateReview(lines: $plate, restaurant: restaurant, meal: meal, place: place.ref, onAdded: onAdded)
        }
        .safeAreaInset(edge: .bottom) {
            if !plate.isEmpty { plateBar }
        }
    }

    private func row(_ item: MenuItem) -> some View {
        Button { selected = item } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).foregroundStyle(.primary)
                Text(item.listDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var plateBar: some View {
        let total = plate.reduce(Nutrients.zero) { $0 + $1.nutrients }
        let count = plate.reduce(0) { $0 + $1.quantity }
        return Button { showsPlate = true } label: {
            HStack {
                Image(systemName: "fork.knife")
                Text("\(count.formatted(.number.precision(.fractionLength(0...1)))) on your plate")
                Spacer()
                Text("\(Int(total.calories.rounded())) kcal").monospacedDigit()
                Image(systemName: "chevron.up").font(.footnote.weight(.semibold))
            }
            .font(.headline)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func log(_ usual: Usual) {
        FoodLog.add(usual.food, servings: usual.servings, meal: meal, place: place.ref, in: context)
        onAdded()
    }

    // MARK: Failure

    private func failed(_ error: APIError) -> some View {
        ContentUnavailableView {
            Label(error == .offline ? "You're Offline" : "Menu Unavailable", systemImage: error == .offline ? "wifi.slash" : "fork.knife")
        } description: {
            Text(error.errorDescription ?? "")
        } actions: {
            if error != .notConfigured {
                Button("Try Again") {
                    self.error = nil
                    Task { await load(force: true) }
                }
                .buttonStyle(.bordered)
            }
            NavigationLink("Estimate Instead", value: EatOutRoute.estimate(place))
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A usual order: what it is, how often, and a Log button that logs it as it was last time.
private struct UsualRow: View {
    var usual: Usual
    var log: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(usual.food.name)
                let amount = usual.servings == 1 ? usual.food.serving : "\(usual.servings.formatted(.number.precision(.fractionLength(0...2)))) × \(usual.food.serving)"
                Text("\(amount) · \(Int((usual.food.calories * usual.servings).rounded())) kcal · \(usual.times == 1 ? "once" : "\(usual.times) times")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Button("Log", action: log)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Log \(usual.food.name)")
        }
        .padding(.vertical, 2)
    }
}

/// Menu sections as chips: All, then each category.
private struct CategoryChips: View {
    var categories: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", value: nil)
                ForEach(categories, id: \.self) { chip($0, value: $0) }
            }
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }

    private func chip(_ title: String, value: String?) -> some View {
        let isOn = selection == value
        return Button(title) { selection = value }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)), in: .capsule)
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One menu item: pick the serving and how many, then log it now or add it to the plate.
struct MenuItemSheet: View {
    let item: MenuItem
    let restaurant: String
    let place: PlaceRef
    var onPlate: (PlateLine) -> Void
    var onAdded: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var serving: MenuServing
    @State private var quantity: Double = 1
    @State private var meal: Meal

    init(item: MenuItem, restaurant: String, meal: Meal, place: PlaceRef, onPlate: @escaping (PlateLine) -> Void, onAdded: @escaping () -> Void) {
        self.item = item
        self.restaurant = restaurant
        self.place = place
        self.onPlate = onPlate
        self.onAdded = onAdded
        _serving = State(initialValue: item.defaultServing ?? MenuServing(id: item.id, description: "1 serving", calories: 0, isDefault: true))
        _meal = State(initialValue: meal)
    }

    private var nutrients: Nutrients { serving.nutrients * quantity }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if item.servings.count > 1 {
                        Picker("Serving", selection: $serving) {
                            ForEach(item.servings) { Text($0.text).tag($0) }
                        }
                    } else {
                        LabeledContent("Serving", value: serving.text)
                    }
                    Stepper(value: $quantity, in: 0.5...20, step: 0.5) {
                        LabeledContent("How Many") {
                            Text(quantity.formatted(.number.precision(.fractionLength(0...1))))
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                        }
                    }
                    Picker("Meal", selection: $meal) {
                        ForEach(Meal.allCases) { Text($0.name).tag($0) }
                    }
                }

                Section {
                    NutritionSummary(nutrients: nutrients, approximate: false)
                } footer: {
                    if serving.protein == nil || serving.carbs == nil || serving.fat == nil {
                        Text("\(restaurant) doesn't list every nutrient for this item; missing ones count as zero.")
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        FoodLog.add(item.food(serving: serving, restaurant: restaurant), servings: quantity, meal: meal, place: place, in: context)
                        dismiss()
                        onAdded()
                    } label: {
                        Text("Add to \(meal.name) · \(Int(nutrients.calories.rounded())) kcal")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    Button("Add to Plate") {
                        onPlate(PlateLine(item: item, serving: serving, quantity: quantity))
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .animation(.snappy, value: quantity)
            .animation(.snappy, value: serving)
        }
        .presentationDetents([.medium, .large])
    }
}

/// The plate: everything picked so far, adjustable, logged together.
struct PlateReview: View {
    @Binding var lines: [PlateLine]
    let restaurant: String
    let place: PlaceRef
    var onAdded: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var meal: Meal

    init(lines: Binding<[PlateLine]>, restaurant: String, meal: Meal, place: PlaceRef, onAdded: @escaping () -> Void) {
        _lines = lines
        self.restaurant = restaurant
        self.place = place
        self.onAdded = onAdded
        _meal = State(initialValue: meal)
    }

    private var total: Nutrients { lines.reduce(.zero) { $0 + $1.nutrients } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($lines) { $line in
                        Stepper(value: $line.quantity, in: 0.5...20, step: 0.5) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.item.name)
                                Text("\(line.quantity.formatted(.number.precision(.fractionLength(0...1)))) × \(line.serving.label) · \(Int(line.nutrients.calories.rounded())) kcal")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .onDelete { lines.remove(atOffsets: $0) }
                }
                Section {
                    Picker("Meal", selection: $meal) {
                        ForEach(Meal.allCases) { Text($0.name).tag($0) }
                    }
                    NutritionSummary(nutrients: total, approximate: false)
                }
            }
            .navigationTitle("Your Plate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear", role: .destructive) {
                        lines = []
                        dismiss()
                    }
                    .tint(.red)
                    .foregroundStyle(.red)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    for line in lines {
                        FoodLog.add(line.item.food(serving: line.serving, restaurant: restaurant), servings: line.quantity, meal: meal, place: place, in: context)
                    }
                    lines = []
                    dismiss()
                    onAdded()
                } label: {
                    Text("Add to \(meal.name) · \(Int(total.calories.rounded())) kcal")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(lines.isEmpty)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .onChange(of: lines.isEmpty) { _, empty in
                if empty { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Calories and the four macros, compactly. `approximate` puts "≈" on every number.
struct NutritionSummary: View {
    var nutrients: Nutrients
    var approximate: Bool

    var body: some View {
        let mark = approximate ? "≈ " : ""
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Text("\(mark)\(Int(nutrients.calories.rounded()).formatted())").font(.title.bold())) \(Text("kcal").foregroundStyle(.secondary))")
                .monospacedDigit()
                .contentTransition(.numericText())
            HStack(spacing: 12) {
                ForEach(Macro.allCases) { macro in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(macro.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(mark)\(Grams.text(macro.value(in: nutrients))) g")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(macro.color)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
