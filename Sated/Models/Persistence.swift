import Foundation
import OSLog
import SwiftData

enum Persistence {
    static let schema = Schema([FoodEntry.self])

    private static let log = Logger(subsystem: "com.stephenwarren.sated", category: "persistence")

    /// The app's one store. The app, Siri and the Watch bridge all use it, so there's never a
    /// second container syncing the same file.
    /// Screenshot mode (Debug only) runs on an in-memory store of demo meals.
    static let shared = makeContainer(inMemory: ScreenshotMode.isOn)

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        // Previews and tests use an in-memory store and never touch iCloud.
        let syncs = AppConfig.cloudSyncEnabled && !inMemory
        let configuration = ModelConfiguration(
            "Sated",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: syncs ? .private(AppConfig.cloudKitContainerID) : .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Never crash on launch over the store. Set the unreadable one aside (kept for
            // recovery) and start fresh; with sync on, iCloud fills it back in.
            log.fault("Couldn't open the data store, starting a fresh one: \(error.localizedDescription, privacy: .public)")
            setAside(configuration.url)
            if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
                return container
            }
            log.fault("The fresh store failed too; running in memory this launch")
            let memory = ModelConfiguration("Sated", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [memory])
            } catch {
                fatalError("Could not create even an in-memory Sated store: \(error)")
            }
        }
    }

    /// Renames the store and its journal files with a timestamp, so a fresh store can be made.
    private static func setAside(_ url: URL) {
        let stamp = Int(Date.now.timeIntervalSince1970)
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard manager.fileExists(atPath: file.path) else { continue }
            let aside = URL(fileURLWithPath: url.path + ".unreadable-\(stamp)" + suffix)
            try? manager.moveItem(at: file, to: aside)
        }
    }

    /// Entries from the start of `from` up to (not including) the start of the day after `through`.
    static func entries(from: Date, through: Date, in context: ModelContext, calendar: Calendar = .current) -> [FoodEntry] {
        let start = calendar.startOfDay(for: from)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through)) ?? through
        let descriptor = FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            log.error("Couldn't fetch entries: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
