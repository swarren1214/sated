import SwiftData
import SwiftUI
import UIKit

@main
struct SatedApp: App {
    @State private var router = AppRouter.shared
    @State private var coach: CoachEngine
    private let container: ModelContainer

    init() {
        ScreenshotMode.prepareLaunch()
        let container = Persistence.shared
        self.container = container
        _coach = State(initialValue: CoachEngine(data: CoachData(container: container, database: .shared)))
        // Alerts use the system label color rather than the accent. Destructive buttons stay red.
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = .label
        WidgetSync.start(container: container)
        WatchBridge.shared.start(container: container)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .task { await HearthAPI.shared.prepareSession() }
                .environment(router)
                .environment(coach)
                .environment(FoodDatabase.shared)
                .environment(HealthService.shared)
        }
        .modelContainer(container)
        // With a keyboard on iPad: ⌘N adds food, ⌘1 to ⌘3 switch tabs (also in the menu bar).
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Food") {
                    AppRouter.shared.show(.now)
                    AppRouter.shared.addFood()
                }
                .keyboardShortcut("n")
            }
            CommandMenu("Go") {
                Button("Today") { AppRouter.shared.tab = .today }
                    .keyboardShortcut("1")
                Button("Trends") { AppRouter.shared.tab = .trends }
                    .keyboardShortcut("2")
                if OnDeviceModel.isOffered {
                    Button("Coach") { AppRouter.shared.tab = .coach }
                        .keyboardShortcut("3")
                }
            }
        }
    }
}

/// Which tab is showing, the day being logged, and where Add Food should file the next entry.
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var tab: AppTab = .today
    /// The day Today shows and new entries go to. Never later than today.
    var day: Date = Calendar.current.startOfDay(for: .now)
    /// The calendar's today, as last seen, to notice midnight.
    @ObservationIgnored private var lastToday = Calendar.current.startOfDay(for: .now)
    @ObservationIgnored private var dayChangeObserver: NSObjectProtocol?

    init() {
        // Midnight while the app is open: someone on today moves to the new today, so
        // nothing gets filed under yesterday by mistake.
        dayChangeObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rollOverIfNeeded() }
        }
    }

    /// Also called when the app comes back to the foreground.
    func rollOverIfNeeded() {
        let today = Calendar.current.startOfDay(for: .now)
        guard today != lastToday else { return }
        if day == lastToday { day = today }
        lastToday = today
    }
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

    var isToday: Bool { Calendar.current.isDateInToday(day) }

    /// When a new entry happens: now, or the current time of day on an earlier day.
    var entryDate: Date {
        let calendar = Calendar.current
        guard !isToday else { return .now }
        let time = calendar.dateComponents([.hour, .minute, .second], from: .now)
        return calendar.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: time.second ?? 0, of: day) ?? day
    }

    func show(_ date: Date) {
        let calendar = Calendar.current
        day = min(calendar.startOfDay(for: date), calendar.startOfDay(for: .now))
    }

    func move(byDays offset: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: offset, to: day) else { return }
        show(date)
    }

    /// "Today", "Yesterday", or "Saturday, Oct 10".
    var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
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
            // Links from the widgets: sated://today, sated://add, sated://trends.
            .onOpenURL { url in
                let router = AppRouter.shared
                switch url.host() {
                case "add":
                    router.show(.now)
                    router.addFood()
                case "trends":
                    router.tab = .trends
                default:
                    router.show(.now)
                    router.tab = .today
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                AppRouter.shared.rollOverIfNeeded()
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
