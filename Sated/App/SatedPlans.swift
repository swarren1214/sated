import SwiftUI

/// What Sated Plus and Hearth+ add, as the paywall and the locked cards name it.
///
/// Free, always: logging by search, barcode and Quick Add, Today, meal times, the last 30 days
/// of trends, Apple Health, export and iCloud sync. Sated Plus or Hearth+: the features below.
/// Hearth+ only: the apps working together (BigTable's planned meals, the household's food
/// rules in Coach). See hearthkit's MONETIZATION.md.
nonisolated enum SatedPlans {
    static let coach = HearthPaywallFeature(
        "Coach",
        detail: "Ask what to eat next, how your week went or where your protein's at, by text or out loud. Private, on this device.",
        symbol: "bubble.left.and.text.bubble.right.fill"
    )

    static let labelScanning = HearthPaywallFeature(
        "Nutrition label scanning",
        detail: "Point the camera at a Nutrition Facts panel and Sated reads it for you. Barcodes stay free.",
        symbol: "text.viewfinder"
    )

    static let sayIt = HearthPaywallFeature(
        "Say It",
        detail: "Say or type what you ate, like “two eggs and toast”, and it's logged.",
        symbol: "waveform"
    )

    static let restaurantMenus = HearthPaywallFeature(
        "Restaurant menus",
        detail: "Log from the nutrition chains publish, and keep your usual orders a tap away.",
        symbol: "fork.knife"
    )

    static let allTimeTrends = HearthPaywallFeature(
        "Trends beyond 30 days",
        detail: "Every month you've logged, your all-time averages, and how this month compares.",
        symbol: "chart.bar.fill"
    )

    /// Where BigTable's planned meal would be, without Hearth+.
    static let plannedMealTeaserTitle = "Log BigTable's planned meals in a tap"
    static let plannedMealTeaserDetail = "With Hearth+, what BigTable planned shows up here, ready to log."
}
