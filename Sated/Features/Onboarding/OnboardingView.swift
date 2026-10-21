import SwiftUI

/// First run, from the Hearth Onboarding canvas (Sated row): Welcome (Sign in with Apple is
/// optional), the household, a goal, the daily goals it suggests, Apple Health, meal reminders,
/// All Set, then Better with Hearth, which starts the tour or jumps in. Built from the shared
/// HearthKit pieces (HearthOnboarding.swift); always dark, like every Hearth app's onboarding.
///
/// Every step writes the real setting it's about (the goal keys, the Health toggles, the meal
/// reminders), so Profile shows the same values afterwards.
struct OnboardingView: View {
    @Environment(AccountStore.self) private var account
    @Environment(HealthService.self) private var health
    @AppStorage(SettingsKey.onboardingDone) private var onboardingDone = false

    @AppStorage(SettingsKey.goalCalories) private var goalCalories = Goals.defaults.calories
    @AppStorage(SettingsKey.goalProtein) private var goalProtein = Goals.defaults.protein
    @AppStorage(SettingsKey.goalCarbs) private var goalCarbs = Goals.defaults.carbs
    @AppStorage(SettingsKey.goalFat) private var goalFat = Goals.defaults.fat
    @AppStorage(SettingsKey.goalFiber) private var goalFiber = Goals.defaults.fiber
    @AppStorage(SettingsKey.saveToHealth) private var saveToHealth = true
    @AppStorage(SettingsKey.readActiveEnergy) private var readActiveEnergy = true

    @State private var screen: Screen = .welcome
    @State private var isForward = true
    @State private var goal: OnboardingGoal?
    @State private var healthConnected = false
    @State private var isWorking = false
    @State private var reminders: [MealReminder: Bool] = Dictionary(uniqueKeysWithValues: MealReminder.allCases.map { ($0, $0.defaultOn) })
    @State private var times: [MealReminder: Int] = Dictionary(uniqueKeysWithValues: MealReminder.allCases.map { ($0, $0.defaultMinutes) })

    enum Screen: Int, CaseIterable {
        case welcome, household, goal, goals, health, reminders, ready, apps
    }

    /// The screens this device shows (no Apple Health step where Health isn't available).
    private var screens: [Screen] {
        Screen.allCases.filter { $0 != .health || health.isAvailable }
    }

    /// The numbered steps, between the welcome and All Set.
    private var numbered: [Screen] { screens.filter { $0 != .welcome && $0 != .ready && $0 != .apps } }

    private func step(_ screen: Screen) -> (number: Int, of: Int)? {
        guard let index = numbered.firstIndex(of: screen) else { return nil }
        return (index + 1, numbered.count)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            page
                .id(screen)
                .transition(.asymmetric(
                    insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
                ))
        }
        .hearthOnboardingStyle(.sated)
        .interactiveDismissDisabled()
        // Signing in on the welcome (or another Hearth app signing in meanwhile) moves on.
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn, screen == .welcome { next() }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch screen {
        case .welcome: welcome
        case .household:
            HearthHouseholdOnboarding(accent: HearthOnboarding.ink(.sated), onContinue: next)
        case .goal: goalPage
        case .goals: goalsPage
        case .health: healthPage
        case .reminders: remindersPage
        case .ready: readyPage
        case .apps:
            HearthOnboardingAppsPage(app: .sated) { tour in
                HearthOnboarding.finish(.sated, tour: tour)
                onboardingDone = true
            }
        }
    }

    // MARK: Navigation

    private func next() {
        guard let index = screens.firstIndex(of: screen), index + 1 < screens.count else { return }
        isForward = true
        withAnimation(.smooth) { screen = screens[index + 1] }
    }

    // MARK: Welcome

    private var welcome: some View {
        HearthOnboardingPage(app: .sated, title: "Sated", subtitle: "Eat well, without the busywork.") {
            VStack(spacing: 20) {
                HearthOnboardingFeature(app: .sated, symbol: "mic.fill", title: "Log in seconds", detail: "Say it, scan it or search it. Sated fills in the nutrition.")
                HearthOnboardingFeature(app: .sated, symbol: "sparkles", title: "A coach on your iPhone", detail: "Ask about your day. Coach runs on this device, so nothing you say leaves it.")
                HearthOnboardingFeature(app: .sated, symbol: "person.2.fill", title: "Better with your family", detail: "Meals from BigTable, and everyone’s allergies from your household.")
            }
        } controls: {
            if case .signedIn(let name, _) = account.status {
                // Already signed in through another Hearth app on this iPhone.
                HearthOnboardingButtons(
                    app: .sated,
                    primary: "Continue", action: next,
                    footnote: name.map { "Signed in as \($0) with your Hearth account." } ?? "Signed in with your Hearth account."
                )
            } else {
                AppleSignInButton()
                HearthOnboardingButtons(
                    app: .sated,
                    secondary: AppConfig.requiresSignIn ? nil : "Continue Without an Account",
                    secondaryAction: continueWithoutAccount,
                    footnote: "Optional. One sign-in for every Hearth app. Your food log stays in your iCloud."
                )
            }
        }
    }

    /// Continue Without an Account, unless this build requires signing in.
    private var continueWithoutAccount: (() -> Void)? {
        guard !AppConfig.requiresSignIn else { return nil }
        return {
            account.skipSignIn()
            next()
        }
    }

    // MARK: Goal

    private var goalPage: some View {
        HearthOnboardingPage(app: .sated, step: step(.goal), symbol: "target", title: "What’s your goal?", subtitle: "Pick one. You can fine-tune every number later in Profile.") {
            ForEach(OnboardingGoal.allCases) { option in
                HearthOnboardingOption(option.title, detail: option.detail, isSelected: goal == option) {
                    goal = option
                    apply(option.goals)
                }
            }
        } controls: {
            HearthOnboardingButtons(app: .sated, primary: "Continue", action: next, secondary: "Skip", secondaryAction: next)
        }
    }

    private func apply(_ goals: Goals) {
        goalCalories = goals.calories
        goalProtein = goals.protein
        goalCarbs = goals.carbs
        goalFat = goals.fat
        goalFiber = goals.fiber
    }

    // MARK: Daily goals

    private var goalsPage: some View {
        HearthOnboardingPage(app: .sated, step: step(.goals), symbol: "chart.bar.fill", title: "Your daily goals", subtitle: goal == nil ? "Change any of them. They’re in Profile too." : "Made from your goal. Change any of them.") {
            HStack {
                Button {
                    goalCalories = max(1200, goalCalories - 50)
                } label: {
                    Image(systemName: "minus").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.primary)
                .accessibilityLabel("Fewer calories")
                Spacer()
                VStack(spacing: 0) {
                    Text(Int(goalCalories).formatted())
                        .font(.system(size: 40, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("calories a day")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Button {
                    goalCalories = min(6000, goalCalories + 50)
                } label: {
                    Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.primary)
                .accessibilityLabel("More calories")
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22, style: .continuous))
            .animation(.snappy, value: goalCalories)

            HearthOnboardingCard {
                macroStepper("Protein", value: $goalProtein, range: 20...400, step: 5)
                macroStepper("Carbs", value: $goalCarbs, range: 20...600, step: 5)
                macroStepper("Fat", value: $goalFat, range: 20...250, step: 5)
                macroStepper("Fiber", value: $goalFiber, range: 10...80, step: 1)
            }
        } controls: {
            HearthOnboardingButtons(app: .sated, primary: "Continue", action: next, secondary: "Skip", secondaryAction: next)
        }
    }

    private func macroStepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            LabeledContent(title) {
                Text("\(Int(value.wrappedValue)) g").monospacedDigit()
            }
        }
    }

    // MARK: Apple Health

    private var healthPage: some View {
        HearthOnboardingPage(app: .sated, step: step(.health), symbol: "heart.fill", title: "Connect Apple Health", subtitle: "Save your meals to Health, and count the energy you burn toward the day.") {
            HearthOnboardingCard {
                Toggle(isOn: $saveToHealth) {
                    HearthOnboardingRowLabel("Save Meals to Health", detail: "Energy, protein, carbs, fat, fiber")
                }
                Toggle(isOn: $readActiveEnergy) {
                    HearthOnboardingRowLabel("Show Active Energy", detail: "From your Apple Watch or iPhone")
                }
            }
            HearthOnboardingNote("Change what Sated reads and writes anytime in the Health app.")
        } controls: {
            HearthOnboardingButtons(
                app: .sated,
                primary: "Connect Apple Health",
                action: {
                    isWorking = true
                    Task {
                        await health.requestAccess()
                        await health.refreshActiveEnergy()
                        healthConnected = true
                        isWorking = false
                        next()
                    }
                },
                secondary: "Not Now",
                secondaryAction: next,
                isWorking: isWorking
            )
        }
    }

    // MARK: Meal reminders

    private var remindersPage: some View {
        HearthOnboardingPage(app: .sated, step: step(.reminders), symbol: "bell.fill", title: "A nudge at mealtime", subtitle: "A reminder to log, at the times you eat. Change them in Profile.") {
            HearthOnboardingCard {
                ForEach(MealReminder.allCases) { meal in
                    HStack(spacing: 12) {
                        Toggle(meal.name, isOn: Binding(
                            get: { reminders[meal] ?? false },
                            set: { reminders[meal] = $0 }
                        ))
                        .fixedSize()
                        Spacer(minLength: 8)
                        DatePicker(
                            "\(meal.name) time",
                            selection: Binding(
                                get: { MealReminders.date(minutes: times[meal] ?? meal.defaultMinutes) },
                                set: { times[meal] = MealReminders.minutes(from: $0) }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .disabled(!(reminders[meal] ?? false))
                    }
                }
            }
        } controls: {
            HearthOnboardingButtons(
                app: .sated,
                primary: "Turn On Reminders",
                action: {
                    isWorking = true
                    Task {
                        let allowed = await MealReminders.requestPermission()
                        saveReminders(on: allowed)
                        isWorking = false
                        next()
                    }
                },
                secondary: "Not Now",
                secondaryAction: {
                    saveReminders(on: false)
                    next()
                },
                isWorking: isWorking
            )
        }
    }

    private func saveReminders(on allowed: Bool) {
        let defaults = UserDefaults.standard
        for meal in MealReminder.allCases {
            defaults.set(allowed && (reminders[meal] ?? false), forKey: meal.enabledKey)
            defaults.set(times[meal] ?? meal.defaultMinutes, forKey: meal.timeKey)
        }
        MealReminders.reschedule()
    }

    // MARK: All set

    private var readyPage: some View {
        HearthOnboardingPage(app: .sated, symbol: "checkmark", title: "You’re all set", subtitle: "Here’s what Sated is keeping track of for you.") {
            VStack(spacing: 14) {
                HearthOnboardingSummaryRow(app: .sated, title: "\(Int(goalCalories).formatted()) calories a day", detail: "With \(Int(goalProtein)) g of protein")
                if health.isAvailable {
                    HearthOnboardingSummaryRow(
                        app: .sated,
                        title: healthConnected ? "Apple Health" : "Apple Health is off",
                        detail: healthConnected ? healthDetail : "Turn it on anytime in Profile"
                    )
                }
                HearthOnboardingSummaryRow(
                    app: .sated,
                    title: MealReminders.summary.map { "\($0) reminders" } ?? "No meal reminders",
                    detail: MealReminders.summary == nil ? "Turn them on anytime in Profile" : "Every day at the times you picked"
                )
                HearthOnboardingSummaryRow(app: .sated, title: "Your household", detail: householdDetail)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22, style: .continuous))
        } controls: {
            HearthOnboardingButtons(app: .sated, primary: "Continue", action: next)
        }
    }

    private var healthDetail: String {
        switch (saveToHealth, readActiveEnergy) {
        case (true, true): "Meals saved, active energy counted"
        case (true, false): "Meals saved to Health"
        case (false, true): "Active energy counted"
        case (false, false): "Connected, nothing shared yet"
        }
    }

    /// Everyone's allergies, from the Hearth household.
    private var householdDetail: String {
        let store = HearthHouseholdStore.shared
        let allergies = Array(Set(store.people.flatMap(\.allergies))).sorted()
        if allergies.isEmpty {
            return store.people.count <= 1 ? "Just you for now" : "\(store.people.count) people, no allergies"
        }
        let list = allergies.prefix(3).map { $0.lowercased() }.formatted(.list(type: .and))
        return "Allergies to \(list), from Hearth"
    }
}

/// The goal step's choices, and the goals each one starts from.
enum OnboardingGoal: String, CaseIterable, Identifiable {
    case healthier, lose, muscle, steady

    var id: String { rawValue }

    var title: String {
        switch self {
        case .healthier: "Eat healthier"
        case .lose: "Lose weight"
        case .muscle: "Build muscle"
        case .steady: "Keep things steady"
        }
    }

    var detail: String {
        switch self {
        case .healthier: "Balanced goals, without counting pressure"
        case .lose: "A gentle calorie deficit"
        case .muscle: "More protein, a little more energy"
        case .steady: "Maintain where you are"
        }
    }

    var goals: Goals {
        switch self {
        case .healthier: Goals(calories: 2100, protein: 120, carbs: 240, fat: 70, fiber: 30)
        case .lose: Goals(calories: 1800, protein: 140, carbs: 170, fat: 60, fiber: 30)
        case .muscle: Goals(calories: 2600, protein: 180, carbs: 280, fat: 80, fiber: 35)
        case .steady: Goals(calories: 2200, protein: 120, carbs: 250, fat: 75, fiber: 30)
        }
    }
}

nonisolated extension SettingsKey {
    /// First-run onboarding finished (or skipped for someone who used Sated before it existed).
    static let onboardingDone = "onboarding.done"
}

/// Who sees onboarding: a new install. Someone who used Sated before onboarding existed (they
/// chose "Not now" on the old sign-in screen, or have food logged) is treated as done.
enum OnboardingGate {
    static func markDoneForExistingUsers(hasEntries: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SettingsKey.onboardingDone) == nil else { return }
        if hasEntries || defaults.bool(forKey: SettingsKey.signInSkipped) {
            defaults.set(true, forKey: SettingsKey.onboardingDone)
            // They've used Sated already: no first-run tour either (Profile › Take the Tour).
            defaults.set(true, forKey: HearthTour.doneKey(for: .sated))
        }
    }
}
