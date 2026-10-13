import SwiftData
import SwiftUI

/// Say what you ate. Speech is transcribed on the iPhone, the on-device model splits it into
/// foods, and the bundled database supplies the numbers. Nothing is logged until confirmed.
struct VoiceLogView: View {
    let meal: Meal
    var onAdded: () -> Void = {}

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
    /// Set when the person closes the screen, so stopping the microphone doesn't log anything.
    @State private var closing = false

    init(meal: Meal, onAdded: @escaping () -> Void = {}) {
        self.meal = meal
        self.onAdded = onAdded
        _targetMeal = State(initialValue: meal)
    }

    private var matched: [VoiceItem] { items.filter { $0.food != nil } }
    private var totals: Nutrients { matched.reduce(.zero) { $0 + $1.nutrients } }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            RoundedRectangle(cornerRadius: 56)
                .strokeBorder(AngularGradient(colors: [.orange, .pink, .orange.opacity(0.6), .orange], center: .center), lineWidth: phase == .listening ? 4 : 0)
                .blur(radius: 6)
                .ignoresSafeArea()
                .opacity(phase == .listening ? 0.9 : 0)
                .animation(.easeInOut(duration: 0.4), value: phase)

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button("Close", systemImage: "xmark") {
                        closing = true
                        dictation.stop()
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    Spacer()
                    OnDeviceBadge()
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }

                Spacer(minLength: 20)
                transcriptView
                Spacer()
                panel
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .task { await listen() }
        .onChange(of: dictation.state) { _, state in
            switch state {
            case .denied:
                phase = .failed("Sated needs microphone and speech recognition access. Turn them on in Settings › Sated.")
            case .unavailable:
                phase = .failed("Speech recognition isn't available on this iPhone right now. Try again, or search instead.")
            case .idle where phase == .listening && !dictation.transcript.isEmpty && !closing:
                Task { await parse() }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(phase == .listening ? "Listening" : "You said")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(phase == .listening ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(dictation.transcript.isEmpty ? "Say what you ate, like “two eggs and a slice of toast.”" : "“\(dictation.transcript)”")
                .font(.title.weight(.semibold))
                .foregroundStyle(dictation.transcript.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.snappy, value: dictation.transcript)
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch phase {
            case .listening:
                Waveform(level: dictation.level)
                    .frame(height: 64)
                HStack {
                    Spacer()
                    Button {
                        dictation.stop()
                        Task { await parse() }
                    } label: {
                        RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 24, height: 24)
                            .frame(width: 76, height: 76)
                            .background(.tint, in: .circle)
                    }
                    .accessibilityLabel("Done speaking")
                    .disabled(dictation.transcript.isEmpty)
                    Spacer()
                }
            case .parsing:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Finding those foods…")
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            case .review:
                review
            case .failed(let message):
                Text(message).font(.subheadline)
                HStack(spacing: 10) {
                    Button("Close") { dismiss() }
                        .buttonStyle(.glass)
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
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
    }

    @ViewBuilder
    private var review: some View {
        HStack(alignment: .firstTextBaseline) {
            Picker("Meal", selection: $targetMeal) {
                ForEach(Meal.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            .font(.title3.bold())
            Spacer()
            Text("\(matched.count) item\(matched.count == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
        VStack(spacing: 0) {
            ForEach($items) { $item in
                VoiceItemRow(item: $item)
                if item.id != items.last?.id { Divider() }
            }
        }
        .padding(.horizontal, 14)
        .background(.fill.tertiary, in: .rect(cornerRadius: 18))
        Text("\(Int(totals.calories.rounded())) kcal · \(Grams.text(totals.protein)) g protein · \(Grams.text(totals.fat)) g fat")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        HStack(spacing: 10) {
            Button("Discard") { dismiss() }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
            Button("Log to \(targetMeal.name)") { logAll() }
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
                .disabled(matched.isEmpty)
        }
        .controlSize(.large)
    }

    /// Starts the microphone, and shows why when it can't (onChange won't fire for a repeat failure).
    private func listen() async {
        await dictation.start()
        switch dictation.state {
        case .denied:
            phase = .failed("Sated needs microphone and speech recognition access. Turn them on in Settings › Sated.")
        case .unavailable:
            phase = .failed("Speech recognition isn't available on this iPhone right now. Try again, or search instead.")
        default:
            break
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
                phase = .review
            }
        } catch {
            phase = .failed("Couldn't work out the foods. Try again, or search instead.")
        }
    }

    private func logAll() {
        for item in matched {
            guard let food = item.food else { continue }
            FoodLog.add(food, servings: item.servings, meal: targetMeal, in: context)
        }
        dismiss()
        onAdded()
    }
}

private struct VoiceItemRow: View {
    @Binding var item: VoiceItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let food = item.food {
                    Text(food.name)
                    Text("\(item.servings.formatted(.number.precision(.fractionLength(0...2)))) × \(food.servingText)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(item.spoken)
                    Text("No match. Add it with search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.food != nil {
                Stepper("Servings", value: $item.servings, in: 0.25...20, step: 0.25)
                    .labelsHidden()
                Text("\(Int(item.nutrients.calories.rounded()))")
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
    }
}

/// Bars that rise and fall with the microphone level.
private struct Waveform: View {
    var level: Double
    private let shape: [Double] = [0.2, 0.35, 0.55, 0.4, 0.7, 0.9, 0.6, 0.45, 0.8, 1, 0.75, 0.5, 0.35, 0.55, 0.85, 1, 0.8, 0.6, 0.45, 0.65, 0.9, 0.7, 0.5, 0.35, 0.25, 0.45, 0.6, 0.5, 0.3, 0.2]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(shape.indices, id: \.self) { index in
                Capsule()
                    .fill(.tint)
                    .frame(width: 4, height: max(6, 64 * shape[index] * max(level, 0.12)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}
