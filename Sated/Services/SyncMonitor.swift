import CloudKit
import CoreData
import Observation
import UIKit

/// What the iCloud Sync card in Settings shows: whether iCloud is available, whether SwiftData's
/// CloudKit sync (NSPersistentCloudKitContainer underneath) is sending or fetching right now,
/// when it last finished, and the last error in words a person can act on.
///
/// SwiftData doesn't say how many changes are waiting to go up, so `pendingChanges` stays nil.
@MainActor @Observable
final class SyncMonitor {
    static let shared = SyncMonitor()

    private(set) var snapshot = HearthSyncSnapshot()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Sync events that have started and not finished, by `event.identifier`.
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// Bumped by each account check, so an older answer arriving late doesn't win.
    @ObservationIgnored private var accountCheck = 0

    private static let lastSyncedKey = "sync.lastSynced"

    private init() {
        snapshot.lastSynced = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date
    }

    func start() {
        guard observers.isEmpty else { return }
        // Screenshot mode runs on an in-memory store with no iCloud: show sync as working.
        if ScreenshotMode.isOn {
            snapshot = HearthSyncSnapshot(account: .available, lastSynced: .now.addingTimeInterval(-4 * 60))
            return
        }
        guard AppConfig.cloudSyncEnabled else {
            snapshot.account = .unavailable("iCloud sync is turned off in this build.")
            return
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            let id = event.identifier
            let isSync = event.type == .import || event.type == .export
            let endDate = event.endDate
            let succeeded = event.succeeded
            let message = event.error.flatMap { Self.message(for: $0) }
            MainActor.assumeIsolated {
                self?.handleEvent(id: id, isSync: isSync, endDate: endDate, succeeded: succeeded, message: message)
            }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccount() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccount() }
        })
        checkAccount()
    }

    /// The card's Sync Now: sends settings to iCloud key-value storage, then waits for the next
    /// import of the log (see `CloudRefresh`).
    func syncNow() async {
        checkAccount()
        if AppConfig.cloudSyncEnabled, !ScreenshotMode.isOn {
            NSUbiquitousKeyValueStore.default.synchronize()
        }
        await CloudRefresh.refresh()
    }

    // MARK: Account

    private func checkAccount() {
        guard AppConfig.cloudSyncEnabled, !ScreenshotMode.isOn else { return }
        accountCheck += 1
        let check = accountCheck
        let containerID = AppConfig.cloudKitContainerID
        Task {
            let status = await Self.accountStatus(containerID: containerID)
            guard check == accountCheck else { return }
            if let status {
                snapshot.account = account(for: status)
            } else if snapshot.account == .checking {
                // Couldn't ask; keep the last answer when there is one.
                snapshot.account = .unavailable(nil)
            }
        }
    }

    nonisolated private static func accountStatus(containerID: String) async -> CKAccountStatus? {
        try? await CKContainer(identifier: containerID).accountStatus()
    }

    private func account(for status: CKAccountStatus) -> HearthSyncSnapshot.Account {
        switch status {
        case .available:
            return .available
        case .noAccount:
            return .unavailable("Sign in to iCloud in Settings to keep your log on all your devices.")
        case .restricted:
            return .unavailable("iCloud is restricted on this \(DeviceName.current).")
        default:
            return .unavailable(nil)
        }
    }

    // MARK: Events

    private func handleEvent(id: UUID, isSync: Bool, endDate: Date?, succeeded: Bool, message: String?) {
        guard let endDate else {
            inFlight.insert(id)
            snapshot.isSyncing = true
            return
        }
        inFlight.remove(id)
        snapshot.isSyncing = !inFlight.isEmpty
        if succeeded {
            snapshot.errorMessage = nil
            if isSync {
                snapshot.lastSynced = endDate
                UserDefaults.standard.set(endDate, forKey: Self.lastSyncedKey)
            }
        } else {
            snapshot.errorMessage = message
        }
    }

    /// A failed event's error in words a person can act on, or nil when the card already says
    /// it (offline, signed out).
    nonisolated private static func message(for error: Error) -> String? {
        guard let code = cloudKitCode(of: error as NSError) else {
            if (error as NSError).domain == NSURLErrorDomain { return nil }
            return "iCloud couldn’t sync right now. Sated will try again on its own."
        }
        switch code {
        case .quotaExceeded:
            return "iCloud storage is full, so new changes can’t be saved there. Free up space in Settings › [your name] › iCloud."
        case .networkUnavailable, .networkFailure, .notAuthenticated:
            return nil
        default:
            return "iCloud couldn’t sync right now. Sated will try again on its own."
        }
    }

    /// The CloudKit error code inside an error, looking through Core Data's wrapping and into
    /// the first item of a partial failure.
    nonisolated private static func cloudKitCode(of error: NSError, depth: Int = 0) -> CKError.Code? {
        guard depth < 4 else { return nil }
        if error.domain == CKErrorDomain, let code = CKError.Code(rawValue: error.code) {
            if code == .partialFailure,
               let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any],
               let first = partial.values.first as? NSError {
                return cloudKitCode(of: first, depth: depth + 1) ?? code
            }
            return code
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return cloudKitCode(of: underlying, depth: depth + 1)
        }
        return nil
    }
}
