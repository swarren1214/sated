import SwiftData
import SwiftUI

/// Say what you ate. Speech is transcribed on the iPhone, the on-device model splits it into
/// foods, and the bundled database supplies the numbers. Nothing is logged until confirmed.
/// Laid out like the Voice · Listening and Voice · Confirm designs.
struct VoiceLogView: View {
    let meal: Meal
    var onAdded: () -> Void = {}
    /// Called when the person taps Type Instead: Add Food's search takes over.
    var onType: () -> Void = {}
    /// The restaurant, when saying what was eaten while eating out.
    var place: PlaceRef?

    enum Phase: Equatable {
        case listening
        case parsing
        case review
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(FoodDatabase.self) private var database
    @AppStorage(SettingsKey.confirmVoiceEntries) private var confirmEntries = true
    @State private var dictation = Dictation()
    @State private var phase: Phase = .listening
    @State private var items: [VoiceItem] = []
    @State private var targetMeal: Meal
    @State private var editing = false
    /// Set when the person closes the screen, so stopping the microphone doesn't log anything.
    @State private var closing = false

    init(meal: Meal, place: PlaceRef? = nil, onAdded: @escaping () -> Void = {}, onType: @escaping () -> Void = {}) {
        self.meal = meal
        self.place = place
        self.onAdded = onAdded
        self.onType = onType
        _targetMeal = State(initialValue: meal)
    }

    private var matched: [VoiceItem] { items.filter { $0.food != nil } }
    private var totals: Nutrients { matched.reduce(.zero) { $0 + $1.nutrients } }

    var body: some View {
        ZStack {
            ListeningGlow(active: phase == .listening, level: dictation.level)

            VStack(alignment: .leading, spacing: 0) {
                VoiceTopBar { close() }
                // On a short screen (iPhone Duo's outer display, large text) the transcript and
                // the foods it found scroll rather than clip, so both stay readable to check.
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 24)
                        transcript
                        Spacer(minLength: 24)
                        panel
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            transcript
                            panel
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .readableWidth(640)
        }
        .voiceScreenBackground()
        .task { await listen() }
        .onChange(of: dictation.state) { _, state in
            switch state {
            case .denied:
                phase = .failed(VoiceMessages.denied)
            case .unavailable:
                phase = .failed(VoiceMessages.unavailable)
            case .idle where phase == .listening && !dictation.transcript.isEmpty && !closing:
                Task { await parse() }
            case .idle where phase == .listening && dictation.transcript.isEmpty && !closing:
                phase = .failed("Didn't hear anything. Tap Try Again and say what you ate.")
            default:
                break
            }
        }
    }

    private var transcript: some View {
        LiveTranscript(
            heading: phase == .listening ? "Listening" : "You said",
            text: dictation.transcript,
            placeholder: "Say what you ate, like “two eggs and a slice of toast.”",
            isListening: phase == .listening,
            quoted: true
        )
    }

    @ViewBuilder
    private var panel: some View {
        VoicePanel {
            switch phase {
            case .listening:
                ListeningControls(
                    level: dictation.level,
                    hint: "Say what you ate and how much. Sated fills in the rest.",
                    canStop: !dictation.transcript.isEmpty,
                    onType: {
                        closing = true
                        dictation.stop()
                        dismiss()
                        onType()
                    },
                    onStop: {
                        dictation.stop()
                        Task { await parse() }
                    }
                )
            case .parsing:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Finding those foods…")
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .review:
                review
            case .failed(let message):
                Text(message).font(.subheadline)
                HStack(spacing: 10) {
                    Button("Close") { close() }
                        .buttonStyle(.glass)
                        .tint(.primary)
                        .frame(maxWidth: .infinity)
                    Button("Try Again") {
                        phase = .listening
                        Task { await listen() }
                    }
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
    }

    /// The confirm card: meal and item count, the matched foods, totals with Edit, then
    /// Discard and Log.
    @ViewBuilder
    private var review: some View {
        HStack(alignment: .firstTextBaseline) {
            Menu {
                Picker("Meal", selection: $targetMeal) {
                    ForEach(Meal.allCases) { Text($0.name).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(targetMeal.name).font(.title3.bold())
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .tint(.primary)
            Spacer()
            Text("\(matched.count) item\(matched.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
        }

        VStack(spacing: 0) {
            ForEach($items) { $item in
                VoiceItemRow(item: $item, editing: editing)
                if item.id != items.last?.id { Divider().padding(.leading, 16) }
            }
        }
        .background(.fill.tertiary, in: .rect(cornerRadius: 20))

        HStack {
            Text("\(Int(totals.calories.rounded())) kcal · \(Grams.text(totals.protein)) g protein · \(Grams.text(totals.fat)) g fat")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(editing ? "Done" : "Edit") {
                withAnimation(.snappy) { editing.toggle() }
            }
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
        }
        .font(.subheadline)
        .padding(.horizontal, 4)

        HStack(spacing: 10) {
            Button { close() } label: {
                Text("Discard").frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .font(.headline)
            .background(.fill.secondary, in: .capsule)
            .frame(maxWidth: 130)

            Button { logAll() } label: {
                Text("Log to \(targetMeal.name)").frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .font(.headline)
            .foregroundStyle(.white)
            .background(Accent.color.gradient, in: .capsule)
            .disabled(matched.isEmpty)
            .opacity(matched.isEmpty ? 0.5 : 1)
        }
    }

    private func close() {
        closing = true
        dictation.stop()
        dismiss()
    }

    /// Starts the microphone, and shows why when it can't (onChange won't fire for a repeat failure).
    private func listen() async {
        await dictation.start()
        switch dictation.state {
        case .denied: phase = .failed(VoiceMessages.denied)
        case .unavailable: phase = .failed(VoiceMessages.unavailable)
        default: break
        }
    }

    private func parse() async {
        guard phase == .listening, !closing else { return }
        let transcript = dictation.transcript
        guard !transcript.isEmpty else { return }
        phase = .parsing
        do {
            let result = try await MealParser.parse(transcript, database: database)
            items = result.items
            if let spokenMeal = result.meal { targetMeal = spokenMeal }
            guard !items.isEmpty else {
                phase = .failed("Didn't catch any foods in that. Try naming each food and how much.")
                return
            }
            if !confirmEntries, items.allSatisfy({ $0.food != nil }) {
                logAll()
            } else {
                withAnimation(.snappy) { phase = .review }
            }
        } catch {
            phase = .failed("Couldn't work out the foods. Try again, or search instead.")
        }
    }

    private func logAll() {
        for item in matched {
            guard let food = item.food else { continue }
            FoodLog.add(food, servings: item.servings, meal: targetMeal, place: place, in: context)
        }
        dismiss()
        onAdded()
    }
}

/// The things both voice screens say when the microphone can't start.
enum VoiceMessages {
    static let denied = "Sated needs microphone and speech recognition access. Turn them on in Settings › Sated."
    static let unavailable = "Speech recognition isn't available right now. Check that Siri & Dictation languages are downloaded, then try again."
}

/// A matched food: "Large egg / 2 eggs · 12.6 g protein / 144". Edit shows a servings stepper.
private struct VoiceItemRow: View {
    @Binding var item: VoiceItem
    var editing: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let food = item.food {
                    Text(food.name)
                    Text("\(amount(food)) · \(Grams.text(item.nutrients.protein)) g protein")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(item.spoken.capitalized)
                    Text("No match. Add it with search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.food != nil {
                if editing {
                    Stepper("Servings", value: $item.servings, in: 0.25...20, step: 0.25)
                        .labelsHidden()
                }
                Text("\(Int(item.nutrients.calories.rounded()))")
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func amount(_ food: FoodItem) -> String {
        let count = item.servings.formatted(.number.precision(.fractionLength(0...2)))
        // "1 egg" × 2 reads as "2 eggs"; other servings read as "2 × 1 cup".
        let serving = food.serving
        let unitWord = serving.dropFirst(2)
        if serving.hasPrefix("1 "), !serving.contains("("), !["medium", "large", "small", "serving"].contains(String(unitWord)) {
            let unit = String(serving.dropFirst(2))
            return item.servings == 1 ? "1 \(unit)" : "\(count) \(unit.hasSuffix("s") ? unit : unit + "s")"
        }
        return item.servings == 1 ? serving : "\(count) × \(serving)"
    }
}
