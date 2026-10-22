import Combine
import SwiftData
import SwiftUI
import UIKit

@main
struct SatedApp: App {
    /// Registers for CloudKit's silent pushes, so changes from other devices arrive on their own.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var router = AppRouter.shared
    @State private var account = AccountStore.shared
    @State private var coach: CoachEngine
    private let container: ModelContainer

    init() {
        ScreenshotMode.prepareLaunch()
        // Goals and Coach settings follow the person through iCloud key-value storage.
        CloudSettings.start()
        // Follows iCloud sync for the iCloud Sync card in Settings.
        SyncMonitor.shared.start()
        let container = Persistence.shared
        self.container = container
        _coach = State(initialValue: CoachEngine(data: CoachData(container: container, database: .shared)))
        // Alerts use the system label color rather than the accent. Destructive buttons stay red.
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = .label
        WidgetSync.start(container: container)
        WatchBridge.shared.start(container: container)
        // One sign-in for every Hearth app: follow sign-ins and sign-outs in BigTable and Suffice.
        HearthSignIn.start()
        // Sated Plus and Hearth+ (RevenueCat), following the same Hearth sign-in.
        Self.configurePurchases()
    }

    /// Sated Plus or Hearth+ unlock Coach, label scanning, Say It, restaurant menus and all-time
    /// trends; Hearth+ also the BigTable features. Screenshots show everything unlocked.
    private static func configurePurchases() {
        let purchases = HearthPurchases.shared
        if ScreenshotMode.isOn { purchases.previewUnlocked = true }
        guard AppConfig.purchasesConfigured || ScreenshotMode.isOn else { return }
        purchases.configure(
            app: .sated,
            apiKey: AppConfig.revenueCatAPIKey,
            apiBaseURL: AppConfig.apiBaseURL,
            accessToken: {
                // Only a Sign in with Apple session is a Hearth account; an anonymous one isn't.
                await HearthAPI.shared.accessTokenIfSignedIn()
            },
            signInButton: { AnyView(AppleSignInButton().environment(AccountStore.shared)) }
        )
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                // iPhone Duo: reads the pose (closed, open, folded) for every screen below.
                .hearthDuoPose()
                // The Hearth launch splash.
                .hearthSplash(.sated, isEnabled: !ScreenshotMode.isOn)
                .task {
                    await HearthAPI.shared.prepareSession()
                    await AccountStore.shared.refresh()
                }
                // The Hearth household: Coach reads its food rules, and invitations land here.
                .task { if !ScreenshotMode.isOn { HearthHouseholdStore.shared.start(app: .sated) } }
                .hearthHouseholdInvitations()
                .environment(router)
                .environment(account)
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
    /// Set when Today's planned "eating out" meal opens Add Food at that restaurant's menu.
    var restaurantForNextEntry: Place?

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

/// Applies the tint, and keeps Health and the coach warmed up.
struct AppRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HealthService.self) private var health
    @Environment(AccountStore.self) private var account
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.onboardingDone) private var onboardingDone = false
    /// Whether someone who used Sated before onboarding existed has been let through.
    @State private var gateChecked = false

    /// Onboarding's done for this person on another device: none of it here, and "Not now" on
    /// the sign-in stays chosen if they chose it there.
    private func skipOnboarding() {
        HearthOnboarding.finishWithoutSteps(.sated)
        if NSUbiquitousKeyValueStore.default.bool(forKey: SettingsKey.signInSkipped) { account.skipSignIn() }
        onboardingDone = true
    }

    /// A new install: the onboarding flow (it starts with the sign-in, which is optional).
    private var showsOnboarding: Bool {
        gateChecked && !onboardingDone && !ScreenshotMode.isOn && account.status != .unknown
    }

    var body: some View {
        RootTabView()
            .tint(Accent.color)
            // First run: onboarding (Features/Onboarding). Afterwards, Sign in with Apple
            // whenever someone's signed out without having chosen "Not now". Skipped when
            // BigTable or Suffice already signed in on this iPhone.
            .fullScreenCover(isPresented: Binding(get: { showsOnboarding || (onboardingDone && account.showsSignInScreen) }, set: { _ in })) {
                Group {
                    if onboardingDone {
                        SignInView()
                    } else {
                        OnboardingView()
                    }
                }
                .tint(Accent.color)
            }
            .task {
                let entries = (try? context.fetchCount(FetchDescriptor<FoodEntry>())) ?? 0
                OnboardingGate.markDoneForExistingUsers(hasEntries: entries > 0)
                if onboardingDone {
                    // Also for people who onboarded before iCloud remembered it.
                    HearthOnboarding.rememberInCloud(.sated)
                } else if !ScreenshotMode.isOn, await HearthOnboarding.waitForOtherDevices(.sated, timeout: .seconds(3)) {
                    // Done on their other device: not again here.
                    skipOnboarding()
                }
                gateChecked = true
            }
            // Finished on another device while onboarding is showing here.
            .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification).receive(on: RunLoop.main)) { _ in
                if !onboardingDone, !ScreenshotMode.isOn, HearthOnboarding.isDoneOnAnotherDevice(.sated) { skipOnboarding() }
            }
            // Every Hearth app works inside a household; after onboarding (which has its own
            // household step) and sign-in, the household step if there's still none.
            .hearthHouseholdRequired(isActive: onboardingDone && !account.showsSignInScreen && account.status != .unknown && !ScreenshotMode.isOn, accent: Accent.color)
            // Health's permission sheet waits until onboarding (which asks itself) and the
            // sign-in screen are out of the way.
            .task(id: account.status == .unknown || account.showsSignInScreen || !onboardingDone) {
                guard account.status != .unknown, !account.showsSignInScreen, onboardingDone || ScreenshotMode.isOn else { return }
                await health.requestAccess()
                await health.refreshActiveEnergy()
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
                Task { await health.refreshActiveEnergy() }
                Task { await HearthSignIn.follow() }
            }
    }
}
