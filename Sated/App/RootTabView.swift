import SwiftUI

enum AppTab: Hashable {
    case today, trends, coach, add
}

/// The system Liquid Glass tab bar: Today, Trends and Coach in the capsule, and Add Food as the
/// separate round + button.
///
/// iOS only sets a tab apart in its own circle when it's the search tab, so Add Food is the
/// search tab (adding food starts with a food search anyway). `tabViewSearchActivation` makes
/// tapping it open the search field directly, and keeps iOS 26.4 and later from folding the
/// button back into the capsule.
struct RootTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            // Icons only, no titles under them. Each icon keeps its name for VoiceOver.
            Tab(value: AppTab.today) {
                NavigationStack { TodayView() }
            } label: {
                TabIcon("Today", systemImage: "fork.knife")
            }

            Tab(value: AppTab.trends) {
                NavigationStack { TrendsView() }
            } label: {
                TabIcon("Trends", systemImage: "chart.bar.fill")
            }

            if OnDeviceModel.isOffered {
                Tab(value: AppTab.coach) {
                    NavigationStack { CoachView() }
                } label: {
                    TabIcon("Coach", systemImage: "bubble.left.and.text.bubble.right.fill")
                }
            }

            Tab(value: AppTab.add, role: .search) {
                AddFoodView()
            } label: {
                TabIcon("Add Food", systemImage: "plus")
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

/// A tab bar item with just its symbol; the title is read by VoiceOver but not shown.
private struct TabIcon: View {
    var title: String
    var systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
    }
}

#Preview {
    RootTabView()
        .previewEnvironment()
}
