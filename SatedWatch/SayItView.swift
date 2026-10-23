import SwiftUI

/// Sends what was said to the iPhone, which works out the foods on device, then shows them
/// for review.
struct SayItView: View {
    let text: String
    let onLogged: () -> Void

    @Environment(WatchStore.self) private var store
    @State private var phase: Phase = .working
    /// The review screen pushes a meal picker; coming back mustn't parse again and undo edits.
    @State private var started = false

    private enum Phase {
        case working
        case ready(WatchParseReply)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .working:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("“\(text)”")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                    Text("Looking it up on your iPhone…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .navigationTitle("Say It")
            case .ready(let reply):
                ConfirmView(
                    foods: reply.foods,
                    meal: reply.meal.flatMap(Meal.init(rawValue:)) ?? .suggested(),
                    unmatched: reply.unmatched,
                    approximate: Set(reply.approximate ?? []),
                    daysAgo: reply.daysAgo ?? 0,
                    onLogged: onLogged
                )
            case .failed(let message):
                ScrollView {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        Text(message)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            Task { await run() }
                        }
                    }
                }
                .navigationTitle("Say It")
            }
        }
        .task {
            guard !started else { return }
            started = true
            await run()
        }
    }

    private func run() async {
        phase = .working
        do {
            let reply = try await store.parse(text)
            if let error = reply.error {
                phase = .failed(error)
            } else if reply.foods.isEmpty {
                let missing = reply.unmatched.joined(separator: ", ")
                phase = .failed(missing.isEmpty
                    ? "Didn't catch any foods in that. Try naming each food and how much."
                    : "Couldn't find \(missing). Try saying it another way.")
            } else {
                phase = .ready(reply)
            }
        } catch {
            // The store's own errors already say what to do; never show the connection error itself.
            phase = .failed((error as? WatchStore.ParseError)?.errorDescription ?? "Couldn't reach Sated on your iPhone. Keep it nearby and try again.")
        }
    }
}
