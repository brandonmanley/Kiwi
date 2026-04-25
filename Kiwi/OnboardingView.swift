import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settingsStore: SettingsStore

    // MARK: - Local state
    @State private var localSelected: Set<String> = []
    @State private var isLoading = false

    private var allCategories: [String] { ArxivCategories.all }
    private var groupedCategories: [(key: String, values: [String])] { ArxivCategories.grouped() }
    private func displayName(for category: String) -> String { ArxivCategories.displayName(for: category) }

    private var canContinue: Bool { !localSelected.isEmpty && !isLoading }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [KiwiColors.creamWhite, KiwiColors.creamWhite.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {

                ScrollView {
                    VStack(spacing: 14) {

                        // MARK: - Hero card
                        settingsCard(title: "") {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Welcome to")
                                        .font(.custom("ArialRoundedMTBold", size: 22))
                                        .foregroundColor(KiwiColors.darkBrown)

                                    Text("Kiwi")
                                        .font(.custom("Pulang", size: 56))
                                        .foregroundColor(KiwiColors.darkBrown)

                                    Text("Pick a few arXiv categories to track.")
                                        .font(.custom("ArialRoundedMTBold", size: 14))
                                        .foregroundColor(KiwiColors.darkBrown.opacity(0.65))
                                }

                                Spacer()

                                Image("KiwiLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 96, height: 96)
                                    .opacity(0.95)
                                    .foregroundColor(KiwiColors.darkBrown)
                            }
                        }

                        // MARK: - Categories card (chips + disclosure)
                        settingsCard(title: "arXiv categories") {
                            VStack(alignment: .leading, spacing: 12) {

                                HStack {
                                    Text("\(localSelected.count) selected")
                                        .font(.custom("ArialRoundedMTBold", size: 14))
                                        .foregroundColor(KiwiColors.darkBrown.opacity(0.85))

                                    Spacer()

                                    Button("All") {
                                        localSelected = Set(allCategories)
                                        softHaptic()
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(KiwiColors.darkBrown.opacity(0.9))
                                    .font(.custom("ArialRoundedMTBold", size: 14))

                                    Text("·")
                                        .foregroundColor(KiwiColors.darkBrown.opacity(0.35))

                                    Button("Clear") {
                                        localSelected.removeAll()
                                        softHaptic()
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(KiwiColors.darkBrown.opacity(0.9))
                                    .font(.custom("ArialRoundedMTBold", size: 14))
                                }

                                ForEach(groupedCategories, id: \.key) { group in
                                    if group.values.count == 1, let only = group.values.first {
                                        chip(only)
                                            .padding(.vertical, 2)
                                    } else {
                                        DisclosureGroup {
                                            chipsGrid(group.values)
                                                .padding(.top, 8)
                                        } label: {
                                            HStack {
                                                Text(displayName(for: group.key))
                                                    .font(.custom("ArialRoundedMTBold", size: 15))
                                                    .foregroundColor(KiwiColors.darkBrown)

                                                Spacer()

                                                Text("\(group.values.filter { localSelected.contains($0) }.count)")
                                                    .font(.custom("ArialRoundedMTBold", size: 13))
                                                    .foregroundColor(KiwiColors.darkBrown.opacity(0.65))
                                            }
                                            .padding(.vertical, 6)
                                        }
                                        .accentColor(KiwiColors.darkBrown)
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                        }

                        // Spacer for the bottom CTA
                        Color.clear.frame(height: 84)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }
            }

            // MARK: - Bottom “Continue” button
            VStack {
                Spacer()

                Button {
                    Task { await startOnboarding() }
                } label: {
                    HStack {
                        Spacer()
                        if isLoading {
                            ProgressView().tint(KiwiColors.darkBrown)
                        } else {
                            Text(localSelected.isEmpty ? "Select at least one category" : "Continue")
                                .font(.custom("ArialRoundedMTBold", size: 16))
                                .foregroundColor(KiwiColors.darkBrown)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .glassEffect(
                        .clear,
                        in: .rect(cornerRadius: 16)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(localSelected.isEmpty || isLoading)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .safeAreaPadding(.bottom)
            }

            // MARK: - Loading overlay
            if isLoading {
                loadingOverlay
                    .transition(.opacity)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            localSelected = Set(settingsStore.selectedCategories)
        }
        .animation(.easeInOut(duration: 0.25), value: isLoading)
    }

    // MARK: - UI helpers (same “Settings” style)

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: title.isEmpty ? 0 : 10) {
            if !title.isEmpty {
                Text(title)
                    .font(.custom("ArialRoundedMTBold", size: 20))
                    .foregroundColor(KiwiColors.darkBrown)
            }
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(KiwiColors.creamWhite.opacity(0.75))
        )
    }

    private func chipsGrid(_ categories: [String]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ForEach(categories, id: \.self) { cat in
                chip(cat)
            }
        }
    }

    private func chip(_ category: String) -> some View {
        let selected = localSelected.contains(category)
        let long = displayName(for: category)

        return Button {
            if selected { localSelected.remove(category) }
            else { localSelected.insert(category) }
            softHaptic()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(long)
                        .font(.custom("ArialRoundedMTBold", size: 12))
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(category.lowercased())
                        .font(.custom("ArialRoundedMTBold", size: 10))
                        .foregroundColor((selected ? KiwiColors.creamWhite : KiwiColors.darkBrown).opacity(0.75))
                }

                Spacer()
            }
            .foregroundColor(selected ? KiwiColors.creamWhite : KiwiColors.darkBrown)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? KiwiColors.darkGreen : KiwiColors.creamWhite.opacity(0.90))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var loadingOverlay: some View {
        ZStack {
            // Slight dim + material feel
            Color.black.opacity(0.08).ignoresSafeArea()

            VStack(spacing: 10) {
                Text("Getting fresh papers…")
                    .font(.custom("ArialRoundedMTBold", size: 20))
                    .foregroundColor(KiwiColors.darkBrown)

                Text("First sync can take a moment.")
                    .font(.custom("ArialRoundedMTBold", size: 14))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.70))

                ProgressView()
                    .tint(KiwiColors.darkBrown)
                    .padding(.top, 6)
            }
            .padding(18)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(KiwiColors.darkBrown.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Logic

    private func startOnboarding() async {
        guard !localSelected.isEmpty else { return }
        isLoading = true

        let selected = Array(localSelected).sorted()
        settingsStore.setSelectedCategories(selected)

        // Sync papers while the loading overlay is visible, then complete onboarding.
        // Doing the fade-out only after sync prevents a blank Home flash on first launch.
        let manager = NetworkManager(context: modelContext)
        await manager.syncPapers(for: selected)

        settingsStore.setCompletedOnboarding(true)
        isLoading = false
    }

    private func softHaptic() {
        guard !settingsStore.hapticsDisabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    }
}
