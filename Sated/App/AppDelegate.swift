import UIKit

/// What SwiftUI doesn't cover: registering for the silent pushes CloudKit sends when the log
/// changes on another device, so SwiftData imports the change without the person doing anything.
/// Needs the Push Notifications capability (aps-environment) and Background Modes › Remote
/// notifications, both already set.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if AppConfig.cloudSyncEnabled {
            application.registerForRemoteNotifications()
        }
        return true
    }

    /// Household invitations (iCloud) arrive through the scene delegate.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = HearthHouseholdSceneDelegate.self
        return configuration
    }
}
