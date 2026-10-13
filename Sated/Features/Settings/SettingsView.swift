import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Goals, Apple Health, Coach, appearance and data.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(HealthService.self) private var health
    @Environment(CoachEngine.self) private var coach

    @AppStorage(SettingsKey.goalCalories) private var goalCalories = Goals.defaults.calories
    @AppStorage(SettingsKey.goalProtein) private var goalProtein = Goals.defaults.protein
    @AppStorage(SettingsKey.goalCarbs) private var goalCarbs = Goals.defaults.carbs
    @AppStorage(SettingsKey.goalFat) private var goalFat = Goals.defaults.fat
    @AppStorage(SettingsKey.goalFiber) private var goalFiber = Goals.defaults.fiber
    @AppStorage(SettingsKey.saveToHealth) private var saveToHealth = true
    @AppStorage(SettingsKey.readActiveEnergy) private var readActiveEnergy = true
    @AppStorage(SettingsKey.confirmVoiceEntries) private var confirmVoiceEntries = true
    @AppStorage(SettingsKey.spokenReplies) private var spokenReplies = true
    @AppStorage(SettingsKey.coachVoice) private var coachVoice = KokoroVoices.defaultID
    @AppStorage(SettingsKey.coachPause) private var coachPause = CoachPause.medium.seconds
    @State private var model = KokoroModel.shared
    @State private var speaker = CoachSpeaker.shared
    @AppStorage(SettingsKey.accent) private var accent: AccentOption = .orange
    @AppStorage(SettingsKey.appearance) private var appearance: AppearanceOption = .system

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                GoalRow(title: "Calories", unit: "kcal", color: accent.color, value: $goalCalories, range: 1200...6000, step: 50)
                GoalRow(title: "Protein", unit: "g", color: Macro.protein.color, value: $goalProtein, range: 20...400, step: 5)
                GoalRow(title: "Carbs", unit: "g", color: Macro.carbs.color, value: $goalCarbs, range: 20...600, step: 5)
                GoalRow(title: "Fat", unit: "g", color: Macro.fat.color, value: $goalFat, range: 20...250, step: 5)
                GoalRow(title: "Fiber", unit: "g", color: Macro.fiber.color, value: $goalFiber, range: 10...80, step: 1)
            } header: {
                Text("Daily Goals")
            } footer: {
                Text(macroCheck)
            }

            if health.isAvailable {
                Section {
                    Toggle("Save Meals to Health", isOn: $saveToHealth)
                    Toggle("Show Active Energy", isOn: $readActiveEnergy)
                        .onChange(of: readActiveEnergy) { Task { await health.refreshActiveEnergy() } }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Meals appear in Health as dietary energy, protein, carbohydrates, fat and fiber. Change what Sated can read and write in the Health app › Sharing › Apps › Sated.")
                }
            }

            Section {
                LabeledContent("On-Device Model", value: coach.availability.statusText)
                if coach.availability != .available {
                    Text(coach.availability.message).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Confirm Voice Entries", isOn: $confirmVoiceEntries)
                Picker("Answer After a Pause Of", selection: $coachPause) {
                    ForEach(CoachPause.allCases) { pause in
                        Text("\(pause.name) (\(pause.seconds.formatted()) s)").tag(pause.seconds)
                    }
                }
                Toggle("Spoken Replies", isOn: $spokenReplies)
                if spokenReplies {
                    NaturalVoiceRow(model: model)
                    if model.isReady {
                        Picker("Voice", selection: $coachVoice) {
                            ForEach(KokoroVoices.choices) { voice in
                                Text("\(voice.name) · \(voice.detail)").tag(voice.id)
                            }
                        }
                        Button("Play Sample", systemImage: speaker.isActive ? "stop.fill" : "play.fill") {
                            if speaker.isActive {
                                speaker.stop()
                            } else {
                                speaker.speak("Hi, I'm Coach. You have 1,122 calories left today, and dinner is still open.")
                            }
                        }
                    }
                }
            } header: {
                Text("Coach")
            } footer: {
                Text("Coach, your voice and its spoken replies all run on this \(DeviceName.current) and never leave it. When you talk with Coach, it answers once you pause for that long, and you can talk over it to interrupt. The natural voice is a one-time \(KokoroModel.approximateSize) download; until then, Coach speaks with the best Apple voice on your \(DeviceName.current). With Confirm Voice Entries off, foods you say are logged as soon as every one is matched.")
            }

            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceOption.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                AccentPicker(selection: $accent)
            }

            Section {
                LabeledContent("iCloud Sync", value: AppConfig.cloudSyncEnabled ? "On" : "This \(DeviceName.current) only")
                ShareLink(item: CSVExport(text: FoodLog.csv(in: context)), preview: SharePreview("Sated food log")) {
                    Label("Export as CSV", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Your Data")
            } footer: {
                Text("Your log lives on this \(DeviceName.current) and in your private iCloud. When you look up a restaurant, only its name is sent to get the menu; nothing you log ever leaves your devices.")
            }

            Section("About") {
                // The app icon, from the exports in Developer/app-icons (Assets › AppIconImage),
                // light and dark.
                HStack(spacing: 14) {
                    Image("AppIconImage")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 60, height: 60)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sated").font(.headline)
                        Text("Version \(appVersion)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Text("Coach's natural voice is Kokoro (Apache 2.0), run with KokoroSwift (MIT) and MisakiSwift (Apache 2.0).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(AppConfig.foodDataCredit)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Restaurant menu nutrition powered by fatsecret. Places from Apple Maps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Sated is for general wellness and isn't medical advice. Talk with a doctor or registered dietitian before big changes to how you eat.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
            }
        }
    }

    /// Calories implied by the macro goals, so mismatched goals are easy to spot.
    private var macroCheck: String {
        let implied = goalProtein * 4 + goalCarbs * 4 + goalFat * 9
        return "Your protein, carbs and fat goals add up to \(Int(implied.rounded()).formatted()) kcal."
    }
}

/// The natural voice: download it, watch it download, or remove it.
private struct NaturalVoiceRow: View {
    var model: KokoroModel

    var body: some View {
        switch model.state {
        case .unavailable:
            LabeledContent("Natural Voice", value: "Needs a real device")
        case .notDownloaded:
            Button {
                model.download()
            } label: {
                LabeledContent("Natural Voice") {
                    Text("Download \(KokoroModel.approximateSize)").foregroundStyle(.tint)
                }
            }
            .foregroundStyle(.primary)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Natural Voice") {
                    Button("Cancel") { model.cancelDownload() }
                }
                ProgressView(value: fraction)
            }
        case .ready:
            LabeledContent("Natural Voice", value: "On this \(DeviceName.current)")
                .swipeActions {
                    Button(role: .destructive) { model.remove() } label: {
                        Image(systemName: "trash").accessibilityLabel("Remove")
                    }
                    .tint(.red)
                }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Natural Voice") {
                    Button("Try Again") { model.download() }
                }
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct GoalRow: View {
    var title: String
    var unit: String
    var color: Color
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
                Text(title)
                Spacer()
                Text("\(Int(value).formatted()) \(unit)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct AccentPicker: View {
    @Binding var selection: AccentOption

    var body: some View {
        HStack {
            ForEach(AccentOption.allCases) { option in
                Button {
                    selection = option
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if option == selection {
                                Image(systemName: "checkmark")
                                    .font(.footnote.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(3)
                        .overlay(Circle().strokeBorder(option == selection ? option.color : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(option == selection ? .isSelected : [])
                if option != AccentOption.allCases.last { Spacer(minLength: 0) }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The log as a .csv file for the share sheet.
nonisolated struct CSVExport: Transferable {
    var text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { export in
            Data(export.text.utf8)
        }
        .suggestedFileName("Sated Food Log.csv")
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .previewEnvironment()
}
