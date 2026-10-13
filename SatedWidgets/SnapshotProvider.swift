import WidgetKit

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    /// True before the app has written anything: the widget shows sample numbers, dimmed.
    var isSample = false
}

/// Reads the snapshot the app writes. The app asks for a reload whenever the log changes, so
/// the timeline only needs one more entry: midnight, when the new day starts empty.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(entry(at: .now, preview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date.now
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(3600)
        let entries = [entry(at: now), entry(at: midnight)]
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }

    private func entry(at date: Date, preview: Bool = false) -> SnapshotEntry {
        if let saved = WidgetSnapshot.load() {
            return SnapshotEntry(date: date, snapshot: saved.asOf(date))
        }
        return SnapshotEntry(date: date, snapshot: .sample, isSample: !preview)
    }
}
