import Foundation
import Observation
import SwiftUI

/// Sated's side of sharing with the other Hearth apps on this device (see `HearthShared.swift`):
/// it reads the meals BigTable planned, so Add Food can log the planned meal in a tap.
@MainActor
@Observable
final class BigTableMeals {
    static let shared = BigTableMeals()

    /// BigTable's plan, when BigTable is on this device and has shared one recently.
    private(set) var plan: HearthMealPlan?
    /// This person's name in BigTable's household, to leave out meals they're not eating.
    private(set) var myName: String?

    /// BigTable's red, as a small accent on its meals.
    static let color = Color(hex: 0xD9472B)

    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    /// Estimates already worked out, by meal; cleared when the plan changes.
    @ObservationIgnored private var estimates: [HearthMealPlan.Meal: MealEstimate] = [:]

    /// Reads what's shared now and follows changes while Sated is open. Safe to call again.
    func start() {
        guard changeObserver == nil, !ScreenshotMode.isOn else { return }
        Hearth.startObservingChanges()
        changeObserver = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in BigTableMeals.shared.reload() }
        }
        reload()
    }

    /// Picks up BigTable's latest plan. A plan BigTable hasn't refreshed in two weeks (the app
    /// was deleted, or signed out without cleaning up) isn't shown.
    func reload() {
        guard !ScreenshotMode.isOn else { return }
        let family = Hearth.read(HearthFamily.self, from: .bigtable)?.value
        let me = family?.me.flatMap { id in family?.members.first { $0.id == id }?.name }
        if me != myName { myName = me }
        let latest = Hearth.read(HearthMealPlan.self, from: .bigtable, maxAge: 14 * 24 * 60 * 60)?.value
        if latest != plan {
            plan = latest
            estimates = [:]
        }
    }

    /// BigTable's slot for a Sated meal. BigTable doesn't plan snacks.
    static func slot(for meal: Meal) -> String? {
        switch meal {
        case .breakfast: "breakfast"
        case .lunch: "lunch"
        case .dinner: "dinner"
        case .snack: nil
        }
    }

    /// What BigTable planned for this meal on this day, if anything, unless BigTable says
    /// this person isn't eating it.
    func plannedMeal(on day: Date, for meal: Meal) -> HearthMealPlan.Meal? {
        guard let slot = Self.slot(for: meal), let planned = plan?.meal(slot, on: day) else { return nil }
        return Self.isEating(planned, me: myName) ? planned : nil
    }

    /// False when BigTable lists this person among those not eating the meal.
    nonisolated static func isEating(_ meal: HearthMealPlan.Meal, me: String?) -> Bool {
        guard let me, let notEating = meal.notEating, !notEating.isEmpty else { return true }
        let key = HearthNames.normalized(me)
        return !notEating.contains { HearthNames.normalized($0) == key }
    }

    /// One serving of a planned meal, estimated from its recipes. Nil until the bundled foods
    /// are loaded, for meals without recipes (eating out, "Leftovers"), and when nothing in the
    /// recipes could be estimated.
    func estimate(for meal: HearthMealPlan.Meal, database: FoodDatabase) -> MealEstimate? {
        guard database.isLoaded, let recipes = meal.recipes, !recipes.isEmpty else { return nil }
        if let known = estimates[meal] { return known.perServing.calories >= 1 ? known : nil }
        let estimate = RecipeEstimator.estimate(recipes, in: database)
        estimates[meal] = estimate
        return estimate.perServing.calories >= 1 ? estimate : nil
    }
}
