import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var uiState: KiwiUIState
    @EnvironmentObject private var router: KiwiRouter

    private static let drawerWidth: CGFloat = 260
    private let drawerSpring = Animation.interactiveSpring(response: 0.30, dampingFraction: 0.86, blendDuration: 0.12)

    // Live finger tracking for the edge-swipe drawer gesture.
    @State private var dragOffset: CGFloat = 0

    private var hasCompletedOnboarding: Bool {
        settingsStore.hasCompletedOnboarding
    }

    private func closeMenu() {
        withAnimation(drawerSpring) { uiState.isMenuOpen = false }
    }

    // Edge-swipe to open (from the very left edge, so it doesn't steal row
    // swipe-to-save), swipe-left to close. Tracks the finger live via dragOffset.
    private var drawerDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if uiState.isMenuOpen {
                    dragOffset = min(0, max(value.translation.width, -Self.drawerWidth))
                } else {
                    guard value.startLocation.x < 24, value.translation.width > 0 else { return }
                    dragOffset = min(value.translation.width, Self.drawerWidth)
                }
            }
            .onEnded { value in
                // Ignore drags that never engaged (not from the edge, menu closed).
                if !uiState.isMenuOpen && value.startLocation.x >= 24 {
                    dragOffset = 0
                    return
                }
                let settled = (uiState.isMenuOpen ? Self.drawerWidth : 0) + value.translation.width
                withAnimation(drawerSpring) {
                    uiState.isMenuOpen = settled > Self.drawerWidth / 2
                    dragOffset = 0
                }
            }
    }

    private var fetchingLabel: String {
        if let p = uiState.syncProgress, p.total > 1 {
            return "Fetching papers — \(p.done) of \(p.total)"
        }
        return "Fetching latest papers…"
    }

    var body: some View {
        ZStack(alignment: .leading) {

            // MENU (behind)
            SideMenuOverlay()

            // APP CONTENT (slides right)
            NavigationStack(path: $router.path) {
                // A real branch, not a ZStack-with-opacity: Home shouldn't be
                // running its @Query and auto-fetch task behind the onboarding
                // overlay on first launch (which raced OnboardingView's own sync).
                Group {
                    if hasCompletedOnboarding {
                        HomeView()
                    } else {
                        OnboardingView()
                    }
                }
                .transition(.opacity)
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
            // Keep the drawer highlight in sync when the path changes outside the
            // router (custom chevron dismiss, edge-swipe back).
            .onChange(of: router.path.count) { _, _ in router.reconcileWithPath() }
            // dragOffset (live) is applied on top of the settled position; only
            // the settled position animates, so finger tracking stays 1:1.
            .offset(x: (uiState.isMenuOpen ? Self.drawerWidth : 0) + dragOffset)
            .animation(drawerSpring, value: uiState.isMenuOpen)
            .overlay {
                // Tap-to-close scrim only. (The SideMenuOverlay owns the other
                // one; this used to be a duplicate.) Kept here because it must sit
                // above the shifted content, not the menu.
                if uiState.isMenuOpen {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { closeMenu() }
                        .padding(.leading, Self.drawerWidth)
                }
            }
            .gesture(drawerDragGesture)
            .overlay(alignment: .top) {
                // Onboarding has its own loading overlay; don't stack the sync
                // toast on top of it during the first-launch fetch.
                if !hasCompletedOnboarding {
                    EmptyView()
                } else if !uiState.isConnected {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 12))
                        Text("No connection")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                    }
                    .foregroundColor(KiwiColors.creamWhite)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(KiwiColors.darkBrown.opacity(0.85))
                    )
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else if uiState.isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(KiwiColors.creamWhite)
                            .scaleEffect(0.7)
                        // Live counter so a minute-long multi-category sync shows
                        // movement instead of reading as a hang.
                        Text(fetchingLabel)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                    }
                    .foregroundColor(KiwiColors.creamWhite)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(KiwiColors.darkGreen.opacity(0.92))
                    )
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else if let message = uiState.refreshMessage {
                    HStack(spacing: 10) {
                        Text(message)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundColor(KiwiColors.creamWhite)

                        if let action = uiState.refreshAction {
                            Button {
                                action.perform()
                                uiState.dismissRefreshMessage()
                            } label: {
                                Text(action.label)
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                                    .foregroundColor(KiwiColors.lightGreen)
                            }
                            .buttonStyle(.plain)
                        }
                    }
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
            .animation(.easeInOut(duration: 0.3), value: uiState.isRefreshing)
            .animation(.easeInOut(duration: 0.3), value: uiState.refreshMessage)
        }
        .background(KiwiColors.lightGreen.ignoresSafeArea())
    }
}
