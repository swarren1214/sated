import SwiftData
import SwiftUI

/// Chat and voice with the on-device coach.
struct CoachView: View {
    @Environment(CoachEngine.self) private var coach
    @Environment(\.modelContext) private var context
    @State private var draft = ""
    @State private var dictation = Dictation()
    @FocusState private var composerFocused: Bool
    @State private var micProblem: String?
    @AppStorage(SettingsKey.accent) private var accent: AccentOption = .orange

    /// One line of the message field.
    private static let composerHeight: CGFloat = 44
    /// The mic and send buttons: a solid circle inset inside the field's height, like Messages.
    /// (Interactive glass draws larger than its frame, so it isn't used here.)
    private static let buttonSize: CGFloat = 36

    private let starters = ["What should I eat for dinner?", "Summarize my week", "How much protein did I eat yesterday?", "How's my fiber this week?"]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if coach.messages.isEmpty {
                        intro
                    }
                    ForEach(coach.messages) { message in
                        MessageBubble(message: message) {
                            log(message)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Coach")
        .navigationSubtitle("Apple Intelligence")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !coach.messages.isEmpty {
                    Button("Clear") { coach.reset() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .alert("Can't Listen", isPresented: Binding(get: { micProblem != nil }, set: { if !$0 { micProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(micProblem ?? "")
        }
        .onAppear { coach.prewarm() }
        .onChange(of: dictation.transcript) { _, text in
            if dictation.isListening { draft = text }
        }
        .onChange(of: dictation.state) { _, state in
            // Asking out loud sends when you stop talking.
            if state == .idle, !draft.isEmpty { send() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            OnDeviceBadge()
            Text("Ask about what you've eaten, what's left today, or what to eat next. Coach runs on this iPhone and reads only your Sated log.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if coach.availability != .available {
                Text(coach.availability.message)
                    .font(.subheadline)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var composer: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(starters, id: \.self) { starter in
                        Button(starter) {
                            draft = starter
                            send()
                        }
                        .buttonStyle(.glass)
                        .disabled(coach.isThinking)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)

            // The button matches the field's one-line height and stays at the bottom as it grows.
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your food", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(minHeight: Self.composerHeight)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.composerHeight / 2))

                if draft.isEmpty || dictation.isListening {
                    Button {
                        if dictation.isListening {
                            dictation.stop()
                        } else {
                            Task {
                                await dictation.start()
                                switch dictation.state {
                                case .denied: micProblem = "Sated needs microphone and speech recognition access to hear questions. Turn them on in Settings › Sated."
                                case .unavailable: micProblem = "Speech recognition isn't available right now. Type your question instead."
                                default: break
                                }
                            }
                        }
                    } label: {
                        Image(systemName: dictation.isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: Self.buttonSize, height: Self.buttonSize)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(accent.color, in: .circle)
                    .padding(.bottom, (Self.composerHeight - Self.buttonSize) / 2)
                    .accessibilityLabel(dictation.isListening ? "Stop" : "Ask out loud")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: Self.buttonSize, height: Self.buttonSize)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(accent.color, in: .circle)
                    .padding(.bottom, (Self.composerHeight - Self.buttonSize) / 2)
                    .disabled(coach.isThinking)
                    .opacity(coach.isThinking ? 0.5 : 1)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await coach.send(text) }
    }

    private func log(_ message: CoachMessage) {
        let meal = Meal.suggested()
        for food in message.foods {
            FoodLog.add(food, servings: 1, meal: meal, in: context)
        }
        coach.markLogged(message)
    }
}

private struct MessageBubble: View {
    var message: CoachMessage
    var onLog: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(.tint, in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22, bottomTrailingRadius: 6, topTrailingRadius: 22))
            }
        case .coach:
            HStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message.text)
                    if !message.foods.isEmpty {
                        plate
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 6, bottomTrailingRadius: 22, topTrailingRadius: 22))
                Spacer(minLength: 40)
            }
        case .notice:
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(message.foods) { food in
                    HStack {
                        Text(food.name).font(.subheadline)
                        Spacer()
                        Text("\(Int(food.calories.rounded()))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 9)
                    if food.id != message.foods.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .background(.fill.tertiary, in: .rect(cornerRadius: 14))
            Text(message.suggestedTotals.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(message.logged ? "Logged" : "Log to \(Meal.suggested().name)", action: onLog)
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
                .disabled(message.logged)
        }
    }
}

#Preview {
    NavigationStack { CoachView() }
        .previewEnvironment()
}
