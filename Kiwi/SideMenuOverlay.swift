import SwiftUI
import SwiftData
import UIKit

struct SideMenuOverlay: View {
    @EnvironmentObject private var uiState: KiwiUIState
    @EnvironmentObject private var router: KiwiRouter
    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.modelContext) private var modelContext

    @State private var kiwiWiggle: Double = 0

    private let menuWidth: CGFloat = 260

    // Smooth, responsive drawer animation
    private let drawerAnim = Animation.interactiveSpring(response: 0.30, dampingFraction: 0.86, blendDuration: 0.12)

    var body: some View {
        ZStack(alignment: .leading) {

            // Scrim (tap to close)
            Color.black
                .opacity(uiState.isMenuOpen ? 0.25 : 0.0)
                .ignoresSafeArea()
                .allowsHitTesting(uiState.isMenuOpen)
                .onTapGesture { close(animated: true) }
                .animation(drawerAnim, value: uiState.isMenuOpen)

            // Menu panel
            menuPanel
                .frame(width: menuWidth)
                .frame(maxHeight: .infinity)
                .background(KiwiColors.darkGreen)
                .offset(x: uiState.isMenuOpen ? 0 : -menuWidth)
                .shadow(color: .black.opacity(uiState.isMenuOpen ? 0.20 : 0.0),
                        radius: 14, x: 2, y: 0)
                .animation(drawerAnim, value: uiState.isMenuOpen)
        }
        // Only intercept touches when open (prevents “dead zones”)
        .allowsHitTesting(uiState.isMenuOpen)
        // Haptics on state change (open/close)
        .onChange(of: uiState.isMenuOpen) { _, newValue in
            hapticMenuToggled(isOpen: newValue)
        }
    }

    // MARK: - Menu content

    private var menuPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            HStack{
                Text("Kiwi")
                    .font(.custom("Pulang", size: 34))
                    .foregroundColor(KiwiColors.darkBrown)
                    .padding(.top, 20)
                
                Spacer()
                
                Button {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.prepare()
                    generator.impactOccurred(intensity: 0.8)
                    Task { @MainActor in
                        withAnimation(.easeInOut(duration: 0.09)) { kiwiWiggle = -14 }
                        try? await Task.sleep(nanoseconds: 90_000_000)
                        withAnimation(.easeInOut(duration: 0.09)) { kiwiWiggle = 14 }
                        try? await Task.sleep(nanoseconds: 90_000_000)
                        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.55)) {
                            kiwiWiggle = 0
                        }
                    }
                } label: {
                    Image("KiwiLogo")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(KiwiColors.darkBrown)
                        .frame(height: 64)   // slightly bigger
                        .rotationEffect(.degrees(kiwiWiggle))
                }
                .buttonStyle(.plain)
            }

            Button {
                router.goHome()
                close(animated: false) // close immediately after route switch
            } label: {
                menuButton(
                    title: "Today",
                    systemImage: "sun.max.fill",
                    isSelected: router.currentRoute == nil
                )
            }
            .buttonStyle(.plain)

            Button {
                router.go(.daily)
                close(animated: false)
            } label: {
                menuButton(
                    title: "Daily arXiv papers",
                    systemImage: "calendar",
                    isSelected: router.currentRoute == .daily
                )
            }
            .buttonStyle(.plain)

            Button {
                router.go(.readingList)
                close(animated: false)
            } label: {
                menuButton(
                    title: "Reading list",
                    systemImage: "book.fill",
                    isSelected: router.currentRoute == .readingList
                )
            }
            .buttonStyle(.plain)

            Button {
                router.go(.author)
                close(animated: false)
            } label: {
                menuButton(
                    title: "Author",
                    systemImage: "person.fill",
                    isSelected: router.currentRoute == .author
                )
            }
            .buttonStyle(.plain)

            Spacer()

            HStack {
                Button {
                    router.go(.search)
                    close(animated: false)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundColor(KiwiColors.darkBrown)
                        .padding(12)
                        .background(Circle().fill(KiwiColors.darkGreen))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    close(animated: true)
                    triggerRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundColor(KiwiColors.darkBrown)
                        .padding(12)
                        .background(Circle().fill(KiwiColors.darkGreen))
                        .opacity(uiState.isRefreshing ? 0.5 : 1.0)
                }
                .buttonStyle(.plain)
                .disabled(uiState.isRefreshing)

                Spacer()

                Button {
                    router.go(.settings)
                    close(animated: false)
                } label: {
                    Image(systemName: "gearshape")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundColor(KiwiColors.darkBrown)
                        .padding(12)
                        .background(Circle().fill(KiwiColors.darkGreen))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
    }

    private func menuButton(
        title: String,
        systemImage: String,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22)

            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
        }
        .foregroundColor(KiwiColors.darkBrown)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isSelected
                    ? KiwiColors.creamWhite.opacity(0.8)   // ✅ selected
                    : Color.clear
                )
        )
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }

    // MARK: - Open/Close + haptics

    private func close(animated: Bool) {
        if animated {
            withAnimation(drawerAnim) {
                uiState.isMenuOpen = false
            }
        } else {
            uiState.isMenuOpen = false
        }
    }

    private func triggerRefresh() {
        guard !uiState.isRefreshing else { return }
        let categories = settingsStore.selectedCategories
        guard !categories.isEmpty else {
            uiState.flashRefreshMessage("Choose categories in Settings")
            return
        }

        uiState.isRefreshing = true
        Task {
            let manager = NetworkManager(context: modelContext)
            let result = await manager.syncPapers(for: categories)
            uiState.isRefreshing = false
            guard !result.cancelled else { return }
            if result.added > 0 {
                uiState.flashRefreshMessage("Added \(result.added) papers!")
            } else {
                uiState.flashRefreshMessage("Up to date — \(NetworkManager.friendlyNextAnnouncement())")
            }
        }
    }

    private func hapticMenuToggled(isOpen: Bool) {
        // One light impact on open + close
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: isOpen ? 0.9 : 0.6)
    }
}
