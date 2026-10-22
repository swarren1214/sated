import Foundation
import OSLog
import SwiftUI
import WatchConnectivity

/// The Watch's side of the link to the iPhone.
///
/// Shows the latest `WatchSnapshot` the phone sent (kept on disk, so the app opens with numbers
/// even when the phone is away). Foods logged here are sent with `transferUserInfo`, which the
/// system holds until the phone is in range, and counted into today's totals right away until
/// the phone confirms it filed them.
@Observable
final class WatchStore: NSObject {
    static let shared = WatchStore()

    private(set) var snapshot: WatchSnapshot = .empty
    /// Logged here, not yet confirmed by the phone.
    private(set) var pending: [WatchLogRequest] = []
    private(set) var isReachable = false
    /// False until the phone has sent anything at all.
    var hasSnapshot: Bool { snapshot.day != .distantPast }

    @ObservationIgnored private let logger = Logger(subsystem: "com.stephenwarren.sated.watch", category: "link")

    override init() {
        super.init()
        // Screenshot mode: demo content in memory only; the saved files are never touched.
        if ScreenshotMode.isOn {
            snapshot = ScreenshotMode.snapshot()
            return
        }
        if let saved = Self.load(WatchSnapshot.self, from: Self.snapshotURL) { snapshot = saved }
        pending = Self.load([WatchLogRequest].self, from: Self.pendingURL) ?? []
    }

    func activate() {
        guard !ScreenshotMode.isOn, WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: What the screens show

    func totals(on date: Date) -> WatchTotals { snapshot.totals(on: date, adding: pending) }

    var accent: Color {
        Color(red: snapshot.accent.red, green: snapshot.accent.green, blue: snapshot.accent.blue)
    }

    func usuals(for meal: Meal) -> [WatchFood] { snapshot.usuals(for: meal) }

    // MARK: Logging

    func log(_ foods: [WatchFood], meal: Meal) {
        let foods = foods.filter { $0.servings > 0 }
        guard !foods.isEmpty else { return }
        let request = WatchLogRequest(date: .now, meal: meal.rawValue, foods: foods)
        pending.append(request)
        // Screenshot mode: counted in today's totals, but never saved or sent to the phone.
        guard !ScreenshotMode.isOn else { return }
        savePending()
        send(request)
    }

    private func send(_ request: WatchLogRequest) {
        let session = WCSession.default
        // Before activation finishes, `sendUnsent()` picks it up.
        guard session.activationState == .activated else { return }
        do {
            session.transferUserInfo(try WatchLink.message(.log, request))
        } catch {
            logger.error("Couldn't queue a log for the phone: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-sends pending logs the system isn't already holding, after a relaunch or reactivation.
    /// The phone files each ID once, so a duplicate is harmless.
    private func sendUnsent() {
        let queued = Set(WCSession.default.outstandingUserInfoTransfers.compactMap { transfer -> UUID? in
            guard WatchLink.kind(of: transfer.userInfo) == .log else { return nil }
            return WatchLink.decode(WatchLogRequest.self, from: WatchLink.payload(of: transfer.userInfo))?.id
        })
        for request in pending where !queued.contains(request.id) {
            send(request)
        }
    }

    // MARK: Parsing dictation

    enum ParseError: LocalizedError {
        case phoneAway
        case noAnswer

        var errorDescription: String? {
            switch self {
            case .phoneAway: "Your iPhone needs to be nearby to work out what you said. Usuals still work without it."
            case .noAnswer: "Couldn't reach Sated on your iPhone. Try again."
            }
        }
    }

    /// Asks the phone's on-device model to turn dictation into foods.
    func parse(_ text: String) async throws -> WatchParseReply {
        if ScreenshotMode.isOn { return ScreenshotMode.parseReply }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { throw ParseError.phoneAway }
        let message = try WatchLink.message(.parse, WatchParseRequest(text: text))
        let data: Data? = try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(message, replyHandler: { reply in
                continuation.resume(returning: WatchLink.payload(of: reply))
            }, errorHandler: { error in
                continuation.resume(throwing: error)
            })
        }
        guard let reply = WatchLink.decode(WatchParseReply.self, from: data) else { throw ParseError.noAnswer }
        return reply
    }

    // MARK: Receiving

    fileprivate func receive(_ data: Data?) {
        guard let new = WatchLink.decode(WatchSnapshot.self, from: data) else { return }
        snapshot = new
        Self.save(new, to: Self.snapshotURL)
        // Drop what the phone has filed, and anything stuck for more than two days.
        let applied = Set(new.appliedLogIDs)
        let cutoff = Date.now.addingTimeInterval(-2 * 86_400)
        let kept = pending.filter { !applied.contains($0.id) && $0.date > cutoff }
        if kept != pending {
            pending = kept
            savePending()
        }
    }

    fileprivate func activated() {
        let session = WCSession.default
        isReachable = session.isReachable
        if !session.receivedApplicationContext.isEmpty {
            receive(WatchLink.payload(of: session.receivedApplicationContext))
        }
        sendUnsent()
    }

    fileprivate func reachabilityChanged(_ reachable: Bool) {
        isReachable = reachable
    }

    // MARK: Files

    private func savePending() { Self.save(pending, to: Self.pendingURL) }

    private static var folder: URL { URL.applicationSupportDirectory }
    private static var snapshotURL: URL { folder.appending(path: "watch-snapshot.json") }
    private static var pendingURL: URL { folder.appending(path: "watch-pending.json") }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        WatchLink.decode(type, from: try? Data(contentsOf: url))
    }

    private static func save(_ value: some Encodable, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try WatchLink.encode(value).write(to: url, options: .atomic)
        } catch {
            Logger(subsystem: "com.stephenwarren.sated.watch", category: "link")
                .error("Couldn't save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.activated() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard WatchLink.kind(of: applicationContext) == .snapshot else { return }
        let data = WatchLink.payload(of: applicationContext)
        Task { @MainActor in self.receive(data) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }
}
