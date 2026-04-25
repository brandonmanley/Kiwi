import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var uiState: KiwiUIState
    @EnvironmentObject private var router: KiwiRouter

    private var hasCompletedOnboarding: Bool {
        settingsStore.hasCompletedOnboarding
    }

    var body: some View {
        ZStack(alignment: .leading) {

            // MENU (behind)
            SideMenuOverlay()

            // APP CONTENT (slides right)
            NavigationStack(path: $router.path) {
                ZStack {
                    HomeView()
                        .opacity(hasCompletedOnboarding ? 1 : 0)

                    OnboardingView()
                        .opacity(hasCompletedOnboarding ? 0 : 1)
                        .allowsHitTesting(!hasCompletedOnboarding) // prevent taps during/after fade
                }
                .animation(.easeInOut(duration: 3.0), value: hasCompletedOnboarding)
                .navigationDestination(for: KiwiRouter.Route.self) { route in
                    switch route {
                    case .daily: DailyPapersView()
                    case .readingList: ReadingListView()
                    case .settings: SettingsView()
                    case .search: SearchView()
                    }
                }
            }
            .offset(x: uiState.isMenuOpen ? 260 : 0)
            .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.86, blendDuration: 0.12),
                       value: uiState.isMenuOpen)
            .overlay {
                if uiState.isMenuOpen {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.86, blendDuration: 0.12)) {
                                uiState.isMenuOpen = false
                            }
                        }
                        .padding(.leading, 260)
                }
            }
        }
        .background(KiwiColors.lightGreen.ignoresSafeArea())
    }
}
