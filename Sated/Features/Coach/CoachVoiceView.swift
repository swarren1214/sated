import SwiftData
import SwiftUI

/// Talking to Coach: the same listening screen as Say It. Stop speaking and Coach answers in
/// the panel, out loud in its natural voice (all on the iPhone); the exchange is also added
/// to the chat.
struct CoachVoiceView: View {
    /// Called when the person taps Type Instead: the chat's text field takes over.
    var onType: () -> Void = {}

    enum Phase: Equatable {
        case listening
        case thinking
        case answered(UUID)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(CoachEngine.self) private var coach
    @AppStorage(SettingsKey.accent) private var accent: AccentOption = .orange
    @AppStorage(SettingsKey.spokenReplies) private var spokenReplies = true
    @State private var dictation = Dictation()
    @State private var speaker = CoachSpeaker.shared
    @State private var model = KokoroModel.shared
    @State private var phase: Phase = .listening
    @State private var question = ""
    /// Set when the screen is closing, so stopping the microphone doesn't send anything.
    @State private var closing = false

    private var reply: CoachMessage? {
        guard case .answered(let id) = phase else { return nil }
        return coach.messages.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            ListeningGlow(active: phase == .listening, level: dictation.level)

            VStack(alignment: .leading, spacing: 0) {
                VoiceTopBar { close() }
                Spacer(minLength: 24)
                LiveTranscript(
                    heading: phase == .listening ? "Listening" : "You asked",
                    text: phase == .listening ? dictation.transcript : question,
                    placeholder: "Ask about your food, like “what should I eat for dinner?”",
                    isListening: phase == .listening,
                    quoted: true
                )
                Spacer(minLength: 24)
                VoicePanel { panel }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .voiceScreenBackground()
        .task {
            speaker.prewarm()
            await listen()
        }
        .onDisappear { speaker.stop() }
        .onChange(of: dictation.state) { _, state in
            switch state {
            case .denied: phase = .failed(VoiceMessages.denied)
            case .unavailable: phase = .failed(VoiceMessages.unavailable)
            case .idle where phase == .listening && !dictation.transcript.isEmpty && !closing:
                Task { await ask() }
            case .idle where phase == .listening && dictation.transcript.isEmpty && !closing:
                phase = .failed("Didn't hear anything. Tap Try Again and ask your question.")
            default: break
            }
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch phase {
        case .listening:
            ListeningControls(
                level: dictation.level,
                hint: "Ask about what you've eaten, what's left today, or what to eat next.",
                canStop: !dictation.transcript.isEmpty,
                onType: {
                    closing = true
                    dictation.stop()
                    dismiss()
                    onType()
                },
                onStop: {
                    dictation.stop()
                    Task { await ask() }
                }
            )
        case .thinking:
            HStack(spacing: 12) {
                ProgressView()
                Text("Coach is thinking…")
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .answered:
            if let reply {
                answer(reply)
            }
        case .failed(let message):
            Text(message).font(.subheadline)
            buttons(primary: "Try Again")
        }
    }

    @ViewBuilder
    private func answer(_ reply: CoachMessage) -> some View {
        HStack {
            Label("Coach", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent.color)
            Spacer()
            if spokenReplies {
                speakingControl(reply)
            }
        }
        Text(reply.text)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
        if reply.role == .coach, !reply.foods.isEmpty {
            VStack(spacing: 0) {
                ForEach(reply.foods) { food in
                    HStack {
                        Text(food.name)
                        Spacer()
                        Text("\(Int(food.calories.rounded()))").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    if food.id != reply.foods.last?.id { Divider().padding(.leading, 16) }
                }
            }
            .background(.fill.tertiary, in: .rect(cornerRadius: 20))
            Text(reply.suggestedTotals.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                let meal = Meal.suggested()
                for food in reply.foods { FoodLog.add(food, servings: 1, meal: meal, date: .now, in: context) }
                coach.markLogged(reply)
            } label: {
                Text(reply.logged ? "Logged" : "Log to \(Meal.suggested().name)")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .font(.headline)
            .foregroundStyle(.white)
            .background(accent.color.gradient, in: .capsule)
            .disabled(reply.logged)
            .opacity(reply.logged ? 0.5 : 1)
        }
        if spokenReplies {
            naturalVoiceOffer
        }
        buttons(primary: "Ask Another")
    }

    /// Replay, or stop while it's talking.
    @ViewBuilder
    private func speakingControl(_ reply: CoachMessage) -> some View {
        switch speaker.state {
        case .preparing:
            ProgressView().controlSize(.small)
        case .speaking:
            Button {
                speaker.stop()
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(accent.color)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop speaking")
        case .idle:
            Button {
                speaker.speak(reply.text)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Say it again")
        }
    }

    /// Until the natural voice is on the phone, a one-line offer to get it.
    @ViewBuilder
    private var naturalVoiceOffer: some View {
        switch model.state {
        case .notDownloaded, .failed:
            Button {
                model.download()
            } label: {
                Label("Get Coach's natural voice (\(KokoroModel.approximateSize), runs on this iPhone)", systemImage: "arrow.down.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(accent.color)
            }
            .buttonStyle(.plain)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).tint(accent.color)
                Text("\(Int(fraction * 100))%").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        case .ready, .unavailable:
            EmptyView()
        }
    }
    private func buttons(primary: String) -> some View {
        HStack(spacing: 10) {
            Button { close() } label: {
                Text("Done").frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .font(.headline)
            .background(.fill.secondary, in: .capsule)

            Button {
                speaker.stop()
                phase = .listening
                Task { await listen() }
            } label: {
                Label(primary, systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .font(.headline)
            .foregroundStyle(accent.color)
            .background(accent.color.opacity(0.15), in: .capsule)
        }
    }

    private func close() {
        closing = true
        speaker.stop()
        dictation.stop()
        dismiss()
    }

    private func listen() async {
        await dictation.start()
        switch dictation.state {
        case .denied: phase = .failed(VoiceMessages.denied)
        case .unavailable: phase = .failed(VoiceMessages.unavailable)
        default: break
        }
    }

    private func ask() async {
        guard phase == .listening, !closing else { return }
        let text = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = text
        withAnimation(.snappy) { phase = .thinking }
        let before = coach.messages.count
        await coach.send(text)
        // The coach's answer, or the notice it gave instead (Apple Intelligence off, and so on).
        if let answer = coach.messages.dropFirst(before).last(where: { $0.role != .user }) {
            withAnimation(.snappy) { phase = .answered(answer.id) }
            if spokenReplies, answer.role == .coach, !closing { speaker.speak(answer.text) }
        } else {
            phase = .failed("Coach couldn't answer just now. Try asking again.")
        }
    }
}
