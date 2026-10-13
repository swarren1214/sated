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
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            // Icons only on iPhone, no titles under them; each keeps its name for VoiceOver.
            // On iPad the names show, in the top tab bar and the sidebar.
            Tab(value: AppTab.today) {
                NavigationStack { TodayView() }
            } label: {
                TabIcon("Today", systemImage: "fork.knife", showsTitle: showsTitles)
            }

            Tab(value: AppTab.trends) {
                NavigationStack { TrendsView() }
            } label: {
                TabIcon("Trends", systemImage: "chart.bar.fill", showsTitle: showsTitles)
            }

            if OnDeviceModel.isOffered {
                Tab(value: AppTab.coach) {
                    NavigationStack { CoachView() }
                } label: {
                    TabIcon("Coach", systemImage: "bubble.left.and.text.bubble.right.fill", showsTitle: showsTitles)
                }
            }

            Tab(value: AppTab.add, role: .search) {
                AddFoodView()
            } label: {
                TabIcon("Add Food", systemImage: "plus", showsTitle: showsTitles)
            }
        }
        // iPad: a top tab bar that opens into a sidebar. iPhone: the usual bottom tab bar.
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

/// A tab bar item with just its symbol; the title is read by VoiceOver but not shown.
private struct TabIcon: View {
    var title: String
    var systemImage: String
    var showsTitle: Bool

    init(_ title: String, systemImage: String, showsTitle: Bool) {
        self.title = title
        self.systemImage = systemImage
        self.showsTitle = showsTitle
    }

    var body: some View {
        if showsTitle {
            Label(title, systemImage: systemImage)
        } else {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
    }
}

extension RootTabView {
    private var showsTitles: Bool { sizeClass == .regular }
}

#Preview {
    RootTabView()
        .previewEnvironment()
}
