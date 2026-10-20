import Foundation
import OSLog
import SwiftData

/// Settings › Your Data › Erase Sated Data, and the last step of Delete Account.
///
/// Erases everything Sated keeps about the person:
/// - every food entry (SwiftData, whose CloudKit sync deletes them from iCloud and the person's
///   other devices),
/// - the samples Sated wrote to Apple Health,
/// - goals and settings, in UserDefaults and iCloud key-value storage (`CloudSettings`),
/// - cached restaurant menus, lookups and logos.
///
/// The widgets and the Watch follow on their own (the context save rebuilds their snapshots).
/// It never touches the Hearth household, the Hearth sign-in or the downloaded natural voice
/// (shared with the other Hearth apps).
enum SatedDataEraser {
    private static let log = Logger(subsystem: "com.stephenwarren.sated", category: "erase")

    /// Settings that stay on this device (not in `CloudSettings.keys`).
    private static let deviceSettingKeys = [
        SettingsKey.saveToHealth,
        SettingsKey.readActiveEnergy,
    ]

    static func eraseAll(in context: ModelContext) async {
        // Food entries, one by one so each deletion syncs to iCloud.
        do {
            let entries = try context.fetch(FetchDescriptor<FoodEntry>())
            for entry in entries { context.delete(entry) }
            try context.save()
        } catch {
            log.error("Couldn't erase the food log: \(error.localizedDescription, privacy: .public)")
        }

        // Everything Sated wrote to Apple Health.
        await HealthService.shared.removeAll()

        // Goals and settings, here and in iCloud.
        CloudSettings.erase()
        for key in deviceSettingKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Caches.
        await RestaurantStore.shared.clear()
        await LogoStore.shared.clear()

        WidgetSync.refreshNow()
        await HealthService.shared.refreshActiveEnergy()
    }
}
