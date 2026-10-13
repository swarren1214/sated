import Foundation

/// App-wide settings: iCloud, the food database contact, and links shown in Settings.
enum AppConfig {
    /// Food entries sync through the person's private CloudKit database. Needs the iCloud
    /// (CloudKit), Push Notifications and Background Modes › Remote notifications capabilities.
    /// When false, the log stays on this device.
    static let cloudSyncEnabled = false
    static let cloudKitContainerID = "iCloud.com.stephenwarren.sated"

    /// Open Food Facts asks every app to identify itself as "AppName/Version (ContactEmail)".
    /// Replace the placeholder with a real support address before TestFlight.
    static let contactEmail = "[SUPPORT EMAIL]"

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        return "Sated/\(version) (\(contactEmail))"
    }

    static let foodDataCredit = "Nutrition data from USDA FoodData Central and Open Food Facts (ODbL)."
}
