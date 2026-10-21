import SwiftUI

/// Sated's stops on the shared tour (HearthTour.swift): Today, Trends, Coach and Add Food. It
/// shows once on a new install and again from Profile › Take the Tour. Screens mark what each
/// step points at with `.hearthTourTarget(_:)`.
enum SatedTour {
    static let today = "today"
    static let trends = "trends"
    static let coach = "coach"
    static let add = "add"

    static var steps: [HearthTourStep] {
        var steps = [
            HearthTourStep(today, title: "Today", message: "What you've eaten and what's left for the day. Swipe sideways for other days, or tap the calendar up top.", symbol: "fork.knife", color: .orange),
            HearthTourStep(trends, title: "Trends", message: "Your week and month at a glance: calories, protein, carbs, fat and fiber against your goals.", symbol: "chart.bar.fill", color: .green),
        ]
        if OnDeviceModel.isOffered {
            steps.append(HearthTourStep(coach, title: "Coach", message: "Ask about your day or say what you ate. Coach runs on this device, so nothing you say leaves it.", symbol: "bubble.left.and.text.bubble.right.fill", color: .purple))
        }
        steps.append(HearthTourStep(add, title: "Add Food", message: "Search for a food, scan a barcode or a label, find a restaurant's menu, or add a meal from BigTable.", symbol: "plus", color: .blue))
        return steps
    }

    static func tab(for step: HearthTourStep) -> AppTab {
        switch step.id {
        case trends: .trends
        case coach: .coach
        case add: .add
        default: .today
        }
    }
}
