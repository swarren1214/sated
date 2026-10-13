import SwiftUI
import WidgetKit

@main
struct SatedWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CaloriesWidget()
        TodayWidget()
    }
}
