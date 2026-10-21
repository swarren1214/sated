import Foundation
import UserNotifications

/// A daily nudge at each meal the person picked (onboarding, Profile › Meal Reminders). Plain
/// repeating local notifications: they come every day at that time, logged or not.
nonisolated enum MealReminder: String, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    /// Whether this reminder is on.
    var enabledKey: String { "reminders.\(rawValue).on" }
    /// Minutes after midnight.
    var timeKey: String { "reminders.\(rawValue).minutes" }

    var defaultMinutes: Int {
        switch self {
        case .breakfast: 8 * 60
        case .lunch: 12 * 60 + 30
        case .dinner: 18 * 60 + 30
        }
    }

    /// Breakfast and lunch on, dinner off, as onboarding suggests.
    var defaultOn: Bool { self != .dinner }

    var isOn: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    var minutes: Int {
        UserDefaults.standard.object(forKey: timeKey) as? Int ?? defaultMinutes
    }

    var body: String {
        switch self {
        case .breakfast: "What did you have for breakfast? Say it or snap it."
        case .lunch: "Time to log lunch."
        case .dinner: "Log dinner while it's fresh."
        }
    }

    fileprivate var identifier: String { "sated.reminder.\(rawValue)" }
}

enum MealReminders {
    /// Asks for permission once. False when notifications are off for Sated.
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { return true }
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Replaces every meal reminder with the ones that are on now.
    static func reschedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: MealReminder.allCases.map(\.identifier))
        for meal in MealReminder.allCases where meal.isOn {
            let content = UNMutableNotificationContent()
            content.title = meal.name
            content.body = meal.body
            content.sound = .default
            var time = DateComponents()
            time.hour = meal.minutes / 60
            time.minute = meal.minutes % 60
            let trigger = UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
            center.add(UNNotificationRequest(identifier: meal.identifier, content: content, trigger: trigger))
        }
    }

    /// The time as a Date today, for a DatePicker.
    static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }

    static func minutes(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// "Breakfast and lunch", for All Set; nil when none are on.
    static var summary: String? {
        let on = MealReminder.allCases.filter(\.isOn).map(\.name)
        guard !on.isEmpty else { return nil }
        return on.formatted(.list(type: .and))
    }
}
