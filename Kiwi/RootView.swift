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
                .animation(.easeInOut(duration: 0.25), value: hasCompletedOnboarding)
                .navigationDestination(for: KiwiRouter.Route.self) { route in
                    switch route {
                    case .daily: DailyPapersView()
                    case .readingList: ReadingListView()
                    case .settings: SettingsView()
                    case .search: SearchView()
                    case .author: AuthorView()
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
            .overlay(alignment: .top) {
                if !uiState.isConnected {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 12))
                        Text("No connection")
                            .font(.custom("ArialRoundedMTBold", size: 12))
                    }
                    .foregroundColor(KiwiColors.creamWhite)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(KiwiColors.darkBrown.opacity(0.85))
                    )
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: uiState.isConnected)
        }
        .background(KiwiColors.lightGreen.ignoresSafeArea())
    }
}
