import SwiftData
import SwiftUI
import UIKit

@main
struct SatedApp: App {
    @State private var router = AppRouter()
    @State private var coach: CoachEngine
    private let container: ModelContainer

    init() {
        let container = Persistence.makeContainer()
        self.container = container
        _coach = State(initialValue: CoachEngine(data: CoachData(container: container, database: .shared)))
        // Alerts use the system label color rather than the accent. Destructive buttons stay red.
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = .label
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(router)
                .environment(coach)
                .environment(FoodDatabase.shared)
                .environment(HealthService.shared)
        }
        .modelContainer(container)
    }
}

/// Which tab is showing, and where Add Food should file the next entry.
@Observable
final class AppRouter {
    var tab: AppTab = .today
    /// Set when "+" on a meal opens Add Food, so the meal is preselected.
    var mealForNextEntry: Meal?

    func addFood(to meal: Meal? = nil) {
        mealForNextEntry = meal
        tab = .add
    }

    /// After something is logged: leave Add Food and show Today.
    func finishAdding() {
        tab = .today
    }
}

/// Applies the accent and appearance, and keeps Health and the coach warmed up.
struct AppRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HealthService.self) private var health
    @AppStorage(SettingsKey.accent) private var accent: AccentOption = .orange
    @AppStorage(SettingsKey.appearance) private var appearance: AppearanceOption = .system

    var body: some View {
        RootTabView()
            .tint(accent.color)
            .task {
                await health.requestAccess()
                await health.refreshActiveEnergy()
            }
            .onChange(of: appearance, initial: true) { _, option in
                applyAppearance(option)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                applyAppearance(appearance)
                Task { await health.refreshActiveEnergy() }
            }
    }

    /// Sets the style on every window, so sheets and full-screen covers follow it too.
    private func applyAppearance(_ option: AppearanceOption) {
        let style: UIUserInterfaceStyle = switch option {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
