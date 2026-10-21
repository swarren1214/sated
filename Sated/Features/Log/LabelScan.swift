import SwiftData
import SwiftUI
import UIKit

/// The live state of a nutrition-label scan.
///
/// Each camera update: find the panel among everything recognized, read its rows with
/// `LabelParser`, and vote the values across frames. Once calories, fat, carbs and protein
/// have each been read the same way three times and add up, the scan is complete. Numbers
/// that don't add up are read again; if they still don't, the review screen asks the person
/// to check them.
@Observable
final class LabelScanSession {
    /// The panel's outline, in the camera view's coordinates. Nil when no panel is in view.
    private(set) var panelRect: CGRect?
    /// Values confirmed across frames.
    private(set) var confirmed = LabelReading()
    /// The most-read values so far, confirmed or not.
    private(set) var leading = LabelReading()
    private(set) var hint = "Point the camera at the Nutrition Facts panel."
    /// The panel's text, for the model fallback.
    private(set) var panelLines: [String] = []
    /// Set once the values are confirmed (or confirmed but not adding up twice).
    private(set) var isComplete = false
    /// The panel has been in view a while without all the values: offer the fallbacks.
    private(set) var isStuck = false

    @ObservationIgnored private var consensus = LabelConsensus()
    @ObservationIgnored private var lastAnalysis = Date.distantPast
    @ObservationIgnored private var panelSince: Date?
    @ObservationIgnored private var mismatches = 0

    /// Called with everything the camera recognizes, many times a second.
    func update(_ pieces: [TextPiece]) {
        guard !isComplete else { return }
        let now = Date.now
        guard now.timeIntervalSince(lastAnalysis) >= 0.25 else { return }
        lastAnalysis = now

        guard let panel = LabelParser.locatePanel(pieces) else {
            panelRect = nil
            panelSince = nil
            isStuck = false
            hint = pieces.isEmpty
                ? "Point the camera at the Nutrition Facts panel."
                : "Looking for the Nutrition Facts panel…"
            return
        }
        withAnimation(.snappy) { panelRect = panel.rect }
        if panelSince == nil { panelSince = now }

        let lines = LabelParser.rows(panel.pieces)
        panelLines = lines
        consensus.add(LabelParser.parse(lines))
        confirmed = consensus.confirmed()
        leading = consensus.leading()

        if confirmed.hasCore {
            if confirmed.isConsistent || mismatches >= 1 {
                isComplete = true
                hint = confirmed.isConsistent ? "Got it." : "Check these numbers."
            } else {
                // A misread digit, most likely: read it again from scratch.
                mismatches += 1
                consensus = LabelConsensus()
                confirmed = LabelReading()
                hint = "Those numbers don't add up. Hold steady…"
            }
            return
        }

        let missing = [
            ("Calories", leading.calories), ("Fat", leading.fat),
            ("Carbs", leading.carbs), ("Protein", leading.protein),
        ].filter { $0.1 == nil }.map(\.0)
        if missing.isEmpty {
            hint = "Hold steady…"
        } else if missing.count == 4 {
            hint = "Move closer so the numbers are sharp."
        } else {
            hint = "Move so \(missing.formatted(.list(type: .and))) \(missing.count == 1 ? "is" : "are") in view."
        }
        isStuck = now.timeIntervalSince(panelSince ?? now) > 6
    }

    /// The best reading available now: confirmed values, gaps filled with the most-read ones.
    var best: LabelReading { confirmed.filled(from: leading) }

    func reset() {
        consensus = LabelConsensus()
        confirmed = LabelReading()
        leading = LabelReading()
        panelRect = nil
        panelLines = []
        panelSince = nil
        mismatches = 0
        isComplete = false
        isStuck = false
        hint = "Point the camera at the Nutrition Facts panel."
    }
}

/// The outline drawn around the panel once it's found.
struct LabelPanelOutline: View {
    var rect: CGRect?

    var body: some View {
        if let rect {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Accent.color, lineWidth: 3)
                .background(Accent.color.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
                .shadow(color: Accent.color.opacity(0.5), radius: 8)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }
}

/// Which values have been read: a check once confirmed, the value dimmed while it settles.
struct LabelChecklist: View {
    var confirmed: LabelReading
    var leading: LabelReading

    private struct Item: Identifiable {
        var name: String
        var done: Double?
        var seen: Double?
        var unit: String
        var id: String { name }
    }

    var body: some View {
        let items = [
            Item(name: "Calories", done: confirmed.calories, seen: leading.calories, unit: ""),
            Item(name: "Fat", done: confirmed.fat, seen: leading.fat, unit: " g"),
            Item(name: "Carbs", done: confirmed.carbs, seen: leading.carbs, unit: " g"),
            Item(name: "Protein", done: confirmed.protein, seen: leading.protein, unit: " g"),
            Item(name: "Fiber", done: confirmed.fiber, seen: leading.fiber, unit: " g"),
        ]
        HStack(spacing: 6) {
            ForEach(items) { item in
                VStack(spacing: 3) {
                    Image(systemName: item.done != nil ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(item.done != nil ? AnyShapeStyle(Accent.color) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                    Text(item.name)
                        .font(.caption2.weight(.semibold))
                    Text((item.done ?? item.seen).map { Grams.text($0) + item.unit } ?? "–")
                        .font(.caption2)
                        .foregroundStyle(item.done != nil ? .primary : .secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.snappy, value: confirmed)
    }
}

/// What a finished scan becomes: the values to check, the picture they came from, and
/// whether they added up.
struct LabelDraft: Identifiable {
    let id = UUID()
    var reading: LabelReading
    var photo: UIImage?
    var source: Source

    enum Source { case camera, model, manual }

    var needsCheck: Bool { !reading.hasCore || !reading.isConsistent }
}

/// The last step: every value editable, next to the label it was read from.
struct LabelReviewView: View {
    let draft: LabelDraft
    let meal: Meal
    var onAdded: () -> Void
    var onRescan: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var serving = ""
    @State private var grams: Double?
    @State private var calories: Double?
    @State private var fat: Double?
    @State private var carbs: Double?
    @State private var protein: Double?
    @State private var fiber: Double?

    init(draft: LabelDraft, meal: Meal, onAdded: @escaping () -> Void, onRescan: @escaping () -> Void) {
        self.draft = draft
        self.meal = meal
        self.onAdded = onAdded
        self.onRescan = onRescan
        let reading = draft.reading
        _serving = State(initialValue: reading.servingText ?? "")
        _grams = State(initialValue: reading.servingGrams)
        _calories = State(initialValue: reading.calories)
        _fat = State(initialValue: reading.fat)
        _carbs = State(initialValue: reading.carbs)
        _protein = State(initialValue: reading.protein)
        _fiber = State(initialValue: reading.fiber ?? (reading.hasCore ? 0 : nil))
    }

    private var current: LabelReading {
        LabelReading(servingText: serving, servingGrams: grams, calories: calories, fat: fat, carbs: carbs, protein: protein, fiber: fiber)
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    if let photo = draft.photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 120, maxHeight: 180)
                            .clipShape(.rect(cornerRadius: 10))
                            .accessibilityLabel("The scanned label")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Label(sourceTitle, systemImage: current.isConsistent ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(current.isConsistent ? .green : .orange)
                        Text(current.isConsistent
                             ? "Check the values against the label, then add it."
                             : "The calories don't match the fat, carbs and protein. Check the highlighted values against the label.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section("Food") {
                TextField("Name (optional)", text: $name)
                TextField("Serving, like 2/3 cup (55g)", text: $serving)
                number("Serving weight", $grams, unit: "g")
            }

            Section {
                number("Calories", $calories, unit: "kcal", flagged: !current.isConsistent)
                number("Total Fat", $fat, unit: "g", flagged: !current.isConsistent)
                number("Total Carbohydrate", $carbs, unit: "g", flagged: !current.isConsistent)
                number("Protein", $protein, unit: "g", flagged: !current.isConsistent)
                number("Dietary Fiber", $fiber, unit: "g")
            } header: {
                Text("Per Serving")
            }
        }
        .navigationTitle("Check the Label")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Scan Again") {
                    dismiss()
                    onRescan()
                }
                .tint(.primary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                add()
            } label: {
                Text("Add to \(meal.name)\(calories.map { " · \(Int($0.rounded())) kcal" } ?? "")")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(calories == nil)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var sourceTitle: String {
        switch draft.source {
        case .camera: "Read from the label"
        case .model: "Read with the on-device model"
        case .manual: "Enter what the label says"
        }
    }

    private func number(_ title: String, _ value: Binding<Double?>, unit: String, flagged: Bool = false) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 90)
                Text(unit).foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
                .foregroundStyle(flagged ? .orange : .primary)
        }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let food = FoodItem(
            id: "label.\(UUID().uuidString)",
            name: trimmed.isEmpty ? "Scanned food" : trimmed,
            serving: serving.trimmingCharacters(in: .whitespaces).isEmpty ? "1 serving" : serving,
            grams: grams,
            nutrients: Nutrients(calories: calories ?? 0, protein: protein ?? 0, carbs: carbs ?? 0, fat: fat ?? 0, fiber: fiber ?? 0),
            source: .label
        )
        FoodLog.add(food, servings: 1, meal: meal, in: context)
        dismiss()
        onAdded()
    }
}

enum LabelPhoto {
    /// The part of a captured photo under `rect` (in the camera view's coordinates). The
    /// preview fills the view, so the photo is scaled and centered the same way first.
    static func crop(_ image: UIImage, to rect: CGRect, viewSize: CGSize) -> UIImage {
        guard viewSize.width > 0, viewSize.height > 0, image.size.width > 0, image.size.height > 0 else { return image }
        let scale = max(viewSize.width / image.size.width, viewSize.height / image.size.height)
        let offset = CGPoint(
            x: (viewSize.width - image.size.width * scale) / 2,
            y: (viewSize.height - image.size.height * scale) / 2
        )
        let crop = CGRect(
            x: (rect.minX - offset.x) / scale,
            y: (rect.minY - offset.y) / scale,
            width: rect.width / scale,
            height: rect.height / scale
        ).intersection(CGRect(origin: .zero, size: image.size))
        guard !crop.isNull, crop.width > 20, crop.height > 20 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: crop.size, format: format).image { _ in
            image.draw(at: CGPoint(x: -crop.minX, y: -crop.minY))
        }
    }
}
