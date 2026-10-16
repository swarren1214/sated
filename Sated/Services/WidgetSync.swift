import CoreData
import OSLog
import SwiftData
import UIKit
import WidgetKit

/// Keeps the widgets current. Whenever the log is saved, a setting changes, the day turns over
/// or the app goes to the background, it writes a fresh `WidgetSnapshot` to the shared App
/// Group folder and asks WidgetKit to redraw, but only when something actually changed.
enum WidgetSync {
    private static var container: ModelContainer?
    private static var observers: [NSObjectProtocol] = []
    private static var pending: Task<Void, Never>?
    private static var lastWritten: Data?
    private static let log = Logger(subsystem: "com.stephenwarren.sated", category: "widgets")

    static func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            ModelContext.didSave,
            // Changes imported from iCloud (another device's entries) don't save a context here.
            .NSPersistentStoreRemoteChange,
            UserDefaults.didChangeNotification,
            .NSCalendarDayChanged,
            UIApplication.didEnterBackgroundNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { schedule() }
            })
        }
        schedule()
    }

    /// Coalesces bursts (several entries saved at once, a goal stepper held down).
    static func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    /// Writes the snapshot now instead of after the short wait. For Siri, which may be
    /// suspended right after it logs.
    static func refreshNow() {
        pending?.cancel()
        write()
    }

    private static func write() {
        guard let container, let url = WidgetSnapshot.url else { return }
        do {
            let data = try makeSnapshot(context: container.mainContext).encoded()
            // The Watch has its own snapshot (with usuals) and skips sends that change nothing.
            WatchBridge.shared.schedule()
            guard data != lastWritten else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            lastWritten = data
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            log.error("Couldn't update the widgets: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func makeSnapshot(context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> WidgetSnapshot {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        // A year back is plenty for the streak.
        let since = calendar.date(byAdding: .day, value: -366, to: today) ?? today
        let descriptor = FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.date >= since }, sortBy: [SortDescriptor(\.date)])
        let records = ((try? context.fetch(descriptor)) ?? []).map(\.record)
        let todays = records.filter { calendar.isDate($0.date, inSameDayAs: today) }
        let totals = todays.reduce(Nutrients.zero) { $0 + $1.nutrients }
        let goals = Goals.load()

        let meals = Meal.allCases.map { meal in
            let items = todays.filter { $0.meal == meal }
            return WidgetSnapshot.MealLine(
                name: meal.name,
                symbol: meal.symbol,
                calories: items.reduce(0) { $0 + $1.nutrients.calories },
                logged: !items.isEmpty
            )
        }
        let week = Summaries.days(records, from: weekStart, through: today, calendar: calendar)
            .map { WidgetSnapshot.DayLine(date: $0.date, calories: $0.totals.calories) }

        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(Accent.color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        return WidgetSnapshot(
            day: today,
            calories: totals.calories,
            protein: totals.protein,
            carbs: totals.carbs,
            fat: totals.fat,
            fiber: totals.fiber,
            goalCalories: goals.calories,
            goalProtein: goals.protein,
            goalCarbs: goals.carbs,
            goalFat: goals.fat,
            goalFiber: goals.fiber,
            meals: meals,
            week: week,
            streak: Summaries.streak(records, today: now, calendar: calendar),
            accent: .init(red: Double(red), green: Double(green), blue: Double(blue))
        )
    }
}
