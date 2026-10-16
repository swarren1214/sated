import SwiftUI

// The pieces shared by both voice screens (Say It, and talking to Coach), matching the
// Voice · Listening and Voice · Confirm designs: the app blurred behind, a glowing edge while
// listening, the live transcript in large type, and a glass panel at the bottom.

/// The glowing screen edge shown while the microphone is on. It turns slowly and swells with
/// the voice. Still when Reduce Motion is on.
struct ListeningGlow: View {
    var active: Bool
    var level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !active || reduceMotion)) { timeline in
            let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 40
            let gradient = AngularGradient(
                colors: [Accent.color, .pink, .purple.opacity(0.8), Accent.color, .orange, Accent.color],
                center: .center,
                angle: .degrees(angle)
            )
            let swell = 1 + level * 1.5
            ZStack {
                // A soft wide bloom, then a sharper line on top.
                RoundedRectangle(cornerRadius: 56, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 18 * swell)
                    .blur(radius: 26)
                    .opacity(0.55)
                RoundedRectangle(cornerRadius: 56, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 6 * swell)
                    .blur(radius: 8)
                    .opacity(0.8)
                RoundedRectangle(cornerRadius: 56, style: .continuous)
                    .strokeBorder(gradient, lineWidth: 2)
                    .opacity(0.7)
            }
        }
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.5), value: active)
        .animation(.easeOut(duration: 0.15), value: level)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Close on the left, the "On this iPhone" privacy pill in the middle.
struct VoiceTopBar: View {
    var onClose: () -> Void

    var body: some View {
        HStack {
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
            Spacer()
            Label("On this \(DeviceName.current)", systemImage: "lock")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .glassEffect(.regular, in: .capsule)
                .accessibilityLabel("Runs on this \(DeviceName.current)")
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }
}

/// "Listening" over the words so far, in large type. The last few words stay gray while
/// they're still being recognized, like the design.
struct LiveTranscript: View {
    var heading: String
    var text: String
    var placeholder: String
    var isListening: Bool
    var quoted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isListening ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
            } else if isListening {
                let words = text.split(separator: " ")
                let settled = words.dropLast(min(3, max(words.count - 1, 0))).joined(separator: " ")
                let pending = words.suffix(min(3, max(words.count - 1, 0))).joined(separator: " ")
                Text("\(settled)\(Text(pending.isEmpty ? "" : " " + pending + "…").foregroundStyle(.secondary))")
            } else {
                Text(quoted ? "“\(text)”" : text)
            }
        }
        .font(.system(size: 30, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: text)
        .padding(.horizontal, 12)
    }
}

/// The listening panel: waveform, a hint, Type Instead, and the big stop button.
struct ListeningControls: View {
    var level: Double
    var hint: String
    var canStop: Bool
    var onType: () -> Void
    var onStop: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Waveform(level: level)
                .frame(height: 64)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 28) {
                Button(action: onType) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 52, height: 52)
                        .background(.fill.secondary, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Type instead")

                Button(action: onStop) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white)
                        .frame(width: 26, height: 26)
                        .frame(width: 80, height: 80)
                        .background(Accent.color.gradient, in: .circle)
                        .shadow(color: Accent.color.opacity(0.45), radius: 16, y: 8)
                }
                .buttonStyle(.plain)
                .disabled(!canStop)
                .opacity(canStop ? 1 : 0.6)
                .accessibilityLabel("Done speaking")

                // Balances the keyboard button so the stop button sits in the middle.
                Color.clear.frame(width: 52, height: 52)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The glass card the panels sit in.
struct VoicePanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 36))
    }
}

/// Bars that rise and fall with the microphone level, tallest in the middle.
struct Waveform: View {
    var level: Double
    private let shape: [Double] = [0.15, 0.25, 0.4, 0.3, 0.55, 0.45, 0.7, 0.6, 0.85, 0.7, 1, 0.8, 0.95, 0.75, 1, 0.85, 0.7, 0.9, 0.65, 0.75, 0.5, 0.6, 0.4, 0.5, 0.3, 0.35, 0.22, 0.28, 0.18, 0.12]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(shape.indices, id: \.self) { index in
                Capsule()
                    .fill(Accent.color.opacity(0.55 + shape[index] * 0.45))
                    .frame(width: 4, height: max(6, 64 * shape[index] * max(level, 0.14)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Shows the screen behind through a blur, like the designs.
    func voiceScreenBackground() -> some View {
        presentationBackground(.thinMaterial)
    }
}
