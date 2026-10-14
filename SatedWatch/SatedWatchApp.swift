import SwiftUI

/// Sated on Apple Watch: today at a glance, one-tap usuals, and saying what you ate.
/// The iPhone keeps the log; see `WatchStore` and the phone's `WatchBridge`.
@main
struct SatedWatchApp: App {
    @State private var store = WatchStore.shared

    init() {
        WatchStore.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
        }
    }
}

/// Where the home list can go.
enum WatchRoute: Hashable {
    /// Review foods (a usual) before logging them.
    case confirm(foods: [WatchFood], meal: Meal)
    /// Parse dictation on the phone, then review.
    case say(String)
}
