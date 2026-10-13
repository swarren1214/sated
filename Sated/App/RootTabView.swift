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
            Tab("Today", systemImage: "fork.knife", value: AppTab.today) {
                NavigationStack { TodayView() }
            }

            Tab("Trends", systemImage: "chart.bar.fill", value: AppTab.trends) {
                NavigationStack { TrendsView() }
            }

            if OnDeviceModel.isOffered {
                Tab("Coach", systemImage: "bubble.left.and.text.bubble.right.fill", value: AppTab.coach) {
                    NavigationStack { CoachView() }
                }
            }

            Tab(value: AppTab.add, role: .search) {
                AddFoodView()
            } label: {
                Label("Add Food", systemImage: "plus")
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

#Preview {
    RootTabView()
        .previewEnvironment()
}
