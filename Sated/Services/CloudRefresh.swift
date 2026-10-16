import CloudKit
import CoreData

/// Pull to refresh for screens that show the log, which lives in the person's iCloud.
///
/// SwiftData's CloudKit sync (NSPersistentCloudKitContainer underneath) has no public way to
/// fetch on demand: iOS schedules imports itself, at launch, on returning to the foreground and
/// when a silent push says another device changed something. So `refresh()` waits for the next
/// import to finish, or six seconds, whichever comes first. @Query views update on their own
/// once the import is saved.
///
/// Returns at once when sync is off, in screenshot mode, or with no iCloud account.
enum CloudRefresh {
    nonisolated private static let timeout: Duration = .seconds(6)

    static func refresh() async {
        guard AppConfig.cloudSyncEnabled, !ScreenshotMode.isOn else { return }
        let containerID = AppConfig.cloudKitContainerID
        guard await hasAccount(containerID: containerID) else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await nextImport() }
            group.addTask { try? await Task.sleep(for: timeout) }
            // Whichever finishes first; the other is cancelled.
            _ = await group.next()
            group.cancelAll()
        }
    }

    nonisolated private static func hasAccount(containerID: String) async -> Bool {
        let status = try? await CKContainer(identifier: containerID).accountStatus()
        return status == .available
    }

    /// Returns when an import from iCloud finishes, or when the task is cancelled.
    nonisolated private static func nextImport() async {
        let events = NotificationCenter.default.notifications(named: NSPersistentCloudKitContainer.eventChangedNotification)
        for await note in events {
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { continue }
            if event.type == .import, event.endDate != nil { return }
        }
    }
}
