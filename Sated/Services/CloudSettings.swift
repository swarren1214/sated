import Foundation

/// Settings that follow the person to their other devices: daily goals, accent, appearance and
/// Coach's settings.
///
/// Views keep reading and writing them with @AppStorage. This mirrors those UserDefaults keys to
/// iCloud key-value storage (NSUbiquitousKeyValueStore), as Hearken does for its highlight
/// legend, so a change on one device reaches the others. Everything else in UserDefaults stays
/// on the device: the Health switches (Health access is granted per device), sign-in state and
/// caches.
enum CloudSettings {
    static let keys: [String] = [
        SettingsKey.goalCalories,
        SettingsKey.goalProtein,
        SettingsKey.goalCarbs,
        SettingsKey.goalFat,
        SettingsKey.goalFiber,
        SettingsKey.appearance,
        SettingsKey.confirmVoiceEntries,
        SettingsKey.spokenReplies,
        SettingsKey.coachVoice,
        SettingsKey.coachPause,
    ]

    private static var observers: [NSObjectProtocol] = []

    static func start() {
        // Screenshot mode writes demo settings that mustn't reach the person's iCloud.
        guard observers.isEmpty, !ScreenshotMode.isOn else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: NSUbiquitousKeyValueStore.default, queue: .main) { note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { pull(changed ?? keys) }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { _ in
            MainActor.assumeIsolated { push() }
        })
        NSUbiquitousKeyValueStore.default.synchronize()
        // What's in iCloud was set on another device and wins; this device's own settings fill
        // in anything iCloud doesn't have yet.
        pull(keys)
        push()
    }

    /// iCloud → UserDefaults, which @AppStorage views follow.
    private static func pull(_ changed: [String]) {
        let cloud = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard
        for key in changed where keys.contains(key) {
            guard let value = cloud.object(forKey: key) else { continue }
            if !same(value, defaults.object(forKey: key)) { defaults.set(value, forKey: key) }
        }
    }

    /// UserDefaults → iCloud. Only values that differ, so a pull doesn't echo back.
    private static func push() {
        let cloud = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            if !same(value, cloud.object(forKey: key)) { cloud.set(value, forKey: key) }
        }
    }

    private static func same(_ a: Any, _ b: Any?) -> Bool {
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }
        return a.isEqual(b)
    }
}
