import SwiftData
import SwiftUI
import VisionKit

/// How big the restaurant's portion was, against the food database's usual serving.
/// Restaurant portions run large, so Regular is one and a half servings.
enum PortionSize: String, CaseIterable, Identifiable {
    case small, regular, large

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var factor: Double {
        switch self {
        case .small: 1
        case .regular: 1.5
        case .large: 2
        }
    }
}

/// Estimate a meal at a place that doesn't publish nutrition: dishes likely on its menu,
/// what was logged here last time, search, scanning the menu, or saying it. Every number is
/// marked "≈".
struct EstimateMealView: View {
    let place: Place
    let meal: Meal
    var onAdded: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(FoodDatabase.self) private var database
    @State private var query = ""
    @State private var chosen: FoodItem?
    @State private var lastVisit: [FoodEntry] = []
    @State private var visits = 0
    @State private var showsScanner = false
    @State private var showsVoice = false
    @State private var commonDishes: [FoodItem] = []

    private var cuisine: Cuisine? { Cuisine.guess(name: place.name, kind: place.kind) }

    /// "Italian · 0.7 mi · 6 visits"
    private var headerDetail: String {
        var parts: [String] = []
        if !place.detail.isEmpty { parts.append(place.detail) }
        if visits > 1 { parts.append("\(visits) visits") }
        return parts.joined(separator: " · ")
    }

    /// Dishes likely on the menu, found in the food database.
    private func findCommonDishes() -> [FoodItem] {
        var seen = Set<String>()
        return (cuisine?.dishes ?? Cuisine.generalDishes).compactMap { term in
            database.search(term, limit: 1).first.flatMap { seen.insert($0.id).inserted ? $0 : nil }
        }
    }

    var body: some View {
        List {
            Section {
                PlaceHeader(place: place, detail: headerDetail)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
                HStack(alignment: .top, spacing: 12) {
                    Text("≈")
                        .font(.title.bold())
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    Text("\(place.name) doesn't publish nutrition, so Sated estimates from USDA food data. Treat these numbers as a close guess.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                if DataScannerViewController.isSupported || OnDeviceModel.isOffered {
                    HStack(spacing: 8) {
                        if DataScannerViewController.isSupported {
                            action("Scan the Menu", symbol: "text.viewfinder") { showsScanner = true }
                        }
                        if OnDeviceModel.isOffered {
                            action("Say What You Had", symbol: "waveform") { showsVoice = true }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                InlineSearchField(prompt: "Search dishes", text: $query)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                if !lastVisit.isEmpty {
                    Section {
                        ForEach(lastVisit) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text("\(entry.amountText) · \(Int(entry.nutrients.calories.rounded())) kcal")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } header: {
                        HStack {
                            Text("Last Time Here")
                            Spacer()
                            Button("Log Again", action: logLastVisit)
                                .font(.subheadline.weight(.semibold))
                                .textCase(nil)
                        }
                    }
                }

                if !commonDishes.isEmpty {
                    Section(cuisine.map { "Common \($0.name) Dishes" } ?? "Common Dishes") {
                        ForEach(commonDishes) { dishRow($0) }
                    }
                }
            } else {
                let results = database.search(query, limit: 25)
                Section("Dishes") {
                    if results.isEmpty {
                        Text("No matches. Try a simpler name, like “burrito” or “pad thai”.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(results) { dishRow($0) }
                    }
                }
            }
        }
        .readableWidth(820)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Estimate a Meal")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: database.isLoaded) {
            if database.isLoaded { commonDishes = findCommonDishes() }
        }
        .task {
            lastVisit = EatingOutHistory.lastVisit(at: place.ref, in: context)
            visits = EatingOutHistory.spots(in: context, limit: 50).first { RestaurantStore.key($0.place.name) == RestaurantStore.key(place.name) }?.visits ?? 0
        }
        .sheet(item: $chosen) { food in
            EstimateSheet(food: food, place: place.ref, meal: meal, onAdded: onAdded)
        }
        .sheet(isPresented: $showsScanner) {
            MenuTextScanner { text in
                query = text
                showsScanner = false
            }
        }
        .fullScreenCover(isPresented: $showsVoice) {
            VoiceLogView(meal: meal, place: place.ref, onAdded: onAdded)
        }
    }

    private func dishRow(_ food: FoodItem) -> some View {
        Button { chosen = food } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(food.name).foregroundStyle(.primary)
                Text("Regular ≈ \(Int((food.calories * PortionSize.regular.factor).rounded())) kcal · \(food.servingText) each")
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

    private func action(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private func logLastVisit() {
        for entry in lastVisit {
            FoodLog.add(EatingOutHistory.food(from: entry), servings: entry.servings, meal: meal, place: place.ref, in: context)
        }
        onAdded()
    }
}

/// One dish to estimate: portion size, how many, meal.
private struct EstimateSheet: View {
    let food: FoodItem
    let place: PlaceRef
    var onAdded: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var portion: PortionSize = .regular
    @State private var quantity: Double = 1
    @State private var meal: Meal

    init(food: FoodItem, place: PlaceRef, meal: Meal, onAdded: @escaping () -> Void) {
        self.food = food
        self.place = place
        self.onAdded = onAdded
        _meal = State(initialValue: meal)
    }

    private var servings: Double { portion.factor * quantity }
    private var nutrients: Nutrients { food.nutrients * servings }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Portion", selection: $portion) {
                        ForEach(PortionSize.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Restaurant portions run large: Regular is about \(PortionSize.regular.factor.formatted()) × \(food.servingText).")
                }
                Section {
                    Stepper(value: $quantity, in: 1...10, step: 1) {
                        LabeledContent("How Many") {
                            Text(quantity.formatted())
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
                    NutritionSummary(nutrients: nutrients, approximate: true)
                }
            }
            .navigationTitle(food.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    var estimate = food
                    // Its own ID, so Recent keeps the plain food separate from the estimate.
                    estimate.id = "estimate.\(food.id)"
                    estimate.source = .estimate
                    estimate.brand = place.name
                    FoodLog.add(estimate, servings: servings, meal: meal, place: place, in: context)
                    dismiss()
                    onAdded()
                } label: {
                    Text("Add to \(meal.name) · ≈ \(Int(nutrients.calories.rounded())) kcal")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .animation(.snappy, value: servings)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Point the camera at a printed menu and tap a dish; its name becomes the search.
struct MenuTextScanner: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isAvailable {
                    MenuScannerRepresentable(onPick: onPick)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("Camera Unavailable", systemImage: "camera", description: Text("Allow camera access for Sated in Settings to scan a menu."))
                }
            }
            .navigationTitle("Tap a Dish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

private struct MenuScannerRepresentable: UIViewControllerRepresentable {
    var onPick: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPick = onPick
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPick: (String) -> Void

        init(onPick: @escaping (String) -> Void) {
            self.onPick = onPick
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard case .text(let text) = item else { return }
            // A menu line often carries a price or description; keep the dish name.
            let name = text.transcript
                .components(separatedBy: .newlines).first?
                .replacingOccurrences(of: "\\$?\\d+([.,]\\d{2})?", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) ?? ""
            guard !name.isEmpty else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onPick(name)
        }
    }
}
