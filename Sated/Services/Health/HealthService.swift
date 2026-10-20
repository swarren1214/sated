import Foundation
import HealthKit
import OSLog

/// Saves logged food to Apple Health and reads today's active energy.
///
/// Each entry becomes up to five dietary samples tagged with the entry's ID, so editing or
/// deleting the entry can find and replace them.
@Observable
final class HealthService {
    static let shared = HealthService()

    /// Today's active energy, for the Today screen. Nil until read, or when Health isn't allowed.
    private(set) var activeEnergyToday: Double?

    private let store = HKHealthStore()
    private let log = Logger(subsystem: "com.stephenwarren.sated", category: "health")
    private static let entryKey = "SatedEntryID"

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var writeTypes: Set<HKSampleType> {
        [
            HKQuantityType(.dietaryEnergyConsumed),
            HKQuantityType(.dietaryProtein),
            HKQuantityType(.dietaryCarbohydrates),
            HKQuantityType(.dietaryFatTotal),
            HKQuantityType(.dietaryFiber),
        ]
    }

    private var readTypes: Set<HKObjectType> { [HKQuantityType(.activeEnergyBurned)] }

    /// Shows the Health permission sheet the first time; afterwards it returns at once.
    func requestAccess() async {
        // Screenshot mode (Debug): no Health permission sheet.
        guard !ScreenshotMode.isOn, isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
        } catch {
            log.error("Health authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save(_ entry: EntryRecord) async {
        guard isAvailable, UserDefaults.standard.object(forKey: SettingsKey.saveToHealth) as? Bool ?? true else { return }
        let metadata: [String: Any] = [
            HKMetadataKeyFoodType: entry.name,
            Self.entryKey: entry.id.uuidString,
        ]
        let values: [(HKQuantityTypeIdentifier, HKUnit, Double)] = [
            (.dietaryEnergyConsumed, .kilocalorie(), entry.nutrients.calories),
            (.dietaryProtein, .gram(), entry.nutrients.protein),
            (.dietaryCarbohydrates, .gram(), entry.nutrients.carbs),
            (.dietaryFatTotal, .gram(), entry.nutrients.fat),
            (.dietaryFiber, .gram(), entry.nutrients.fiber),
        ]
        let samples: [HKSample] = values.compactMap { identifier, unit, amount in
            guard amount > 0 else { return nil }
            let type = HKQuantityType(identifier)
            guard store.authorizationStatus(for: type) == .sharingAuthorized else { return nil }
            return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: amount), start: entry.date, end: entry.date, metadata: metadata)
        }
        guard !samples.isEmpty else { return }
        do {
            try await store.save(samples)
        } catch {
            log.error("Couldn't save to Health: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the samples saved for an entry (on delete, and before re-saving an edit).
    func remove(entryID: UUID) async {
        guard isAvailable else { return }
        let predicate = HKQuery.predicateForObjects(withMetadataKey: Self.entryKey, allowedValues: [entryID.uuidString])
        for type in writeTypes where store.authorizationStatus(for: type) == .sharingAuthorized {
            do {
                _ = try await store.deleteObjects(of: type, predicate: predicate)
            } catch {
                log.error("Couldn't remove from Health: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Settings › Erase Sated Data: removes every sample Sated wrote to Health (anything whose
    /// source is this app), including ones whose entry is already gone. Samples other apps or
    /// the person entered are never touched.
    func removeAll() async {
        guard isAvailable, !ScreenshotMode.isOn else { return }
        let predicate = HKQuery.predicateForObjects(from: HKSource.default())
        for type in writeTypes where store.authorizationStatus(for: type) == .sharingAuthorized {
            do {
                _ = try await store.deleteObjects(of: type, predicate: predicate)
            } catch {
                log.error("Couldn't remove Sated's samples from Health: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func update(_ entry: EntryRecord) async {
        await remove(entryID: entry.id)
        await save(entry)
    }

    /// Reads today's active energy. Health never says whether reading is allowed; a denied read
    /// just comes back empty, which shows as no value.
    func refreshActiveEnergy(calendar: Calendar = .current) async {
        // Screenshot mode (Debug): an afternoon's active energy, without reading Health.
        if ScreenshotMode.isOn {
            activeEnergyToday = 418
            return
        }
        guard isAvailable, UserDefaults.standard.object(forKey: SettingsKey.readActiveEnergy) as? Bool ?? true else {
            activeEnergyToday = nil
            return
        }
        let start = calendar.startOfDay(for: .now)
        let predicate = HKSamplePredicate.quantitySample(
            type: HKQuantityType(.activeEnergyBurned),
            predicate: HKQuery.predicateForSamples(withStart: start, end: .now)
        )
        let query = HKStatisticsQueryDescriptor(predicate: predicate, options: .cumulativeSum)
        do {
            let result = try await query.result(for: store)
            activeEnergyToday = result?.sumQuantity()?.doubleValue(for: .kilocalorie())
        } catch {
            activeEnergyToday = nil
        }
    }
}
