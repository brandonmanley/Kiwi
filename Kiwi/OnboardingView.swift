import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settingsStore: SettingsStore

    // MARK: - Local state
    @State private var localSelected: Set<String> = []
    @State private var isLoading = false

    // MARK: - Categories
    private let allCategories: [String] = [
        "astro-ph.CO", "astro-ph.EP", "astro-ph.GA",
        "astro-ph.HE", "astro-ph.IM", "astro-ph.SR",
        "cond-mat.dis-nn", "cond-mat.mes-hall", "cond-mat.mtrl-sci",
        "cond-mat.other", "cond-mat.quant-gas", "cond-mat.soft",
        "cond-mat.stat-mech", "cond-mat.str-el", "cond-mat.supr-con",
        "gr-qc", "hep-ex", "hep-lat",
        "hep-ph", "hep-th", "math-ph",
        "nlin.AO", "nlin.CD", "nlin.CG", "nlin.PS", "nlin.SI",
        "nucl-ex", "nucl-th", "quant-ph",
        "physics.acc-ph", "physics.ao-ph", "physics.app-ph",
        "physics.atm-clus", "physics.atom-ph", "physics.bio-ph",
        "physics.chem-ph", "physics.class-ph", "physics.comp-ph",
        "physics.data-an", "physics.ed-ph", "physics.flu-dyn",
        "physics.gen-ph", "physics.geo-ph", "physics.hist-ph",
        "physics.ins-det", "physics.med-ph", "physics.optics",
        "physics.plasm-ph", "physics.pop-ph", "physics.soc-ph",
        "physics.space-ph"
    ]
    
    // MARK: - Category display names (UI only)
    private let categoryDisplayName: [String: String] = [
        // group names
        "astro-ph": "Astrophysics",
        "astro-ph.co": "Cosmology and Nongalactic Astrophysics",
        "astro-ph.ep": "Earth and Planetary Astrophysics",
        "astro-ph.ga": "Astrophysics of Galaxies",
        "astro-ph.he": "High Energy Astrophysical Phenomena",
        "astro-ph.im": "Instrumentation and Methods for Astrophysics",
        "astro-ph.sr": "Solar and Stellar Astrophysics",
        "cond-mat": "Condensed Matter",
        "cond-mat.dis-nn": "Disordered Systems and Neural Networks",
        "cond-mat.mes-hall": "Mesoscale and Nanoscale Physics",
        "cond-mat.mtrl-sci": "Materials Science",
        "cond-mat.other": "Other Condensed Matter",
        "cond-mat.quant-gas": "Quantum Gases",
        "cond-mat.soft": "Soft Condensed Matter",
        "cond-mat.stat-mech": "Statistical Mechanics",
        "cond-mat.str-el": "Strongly Correlated Electrons",
        "cond-mat.supr-con": "Superconductivity",
        "nlin": "Nonlinear Sciences",
        "nlin.ao": "Adaptation and Self-Organizing Systems",
        "nlin.cd": "Chaotic Dynamics",
        "nlin.cg": "Cellular Automata and Lattice Gases",
        "nlin.ps": "Pattern Formation and Solitons",
        "nlin.si": "Exactly Solvable and Integrable Systems",
        "physics": "Other physics",
        "physics.acc-ph": "Accelerator Physics",
        "physics.ao-ph": "Atmospheric and Oceanic Physics",
        "physics.app-ph": "Applied Physics",
        "physics.atm-clus": "Atomic and Molecular Clusters",
        "physics.atom-ph": "Atomic Physics",
        "physics.bio-ph": "Biological Physics",
        "physics.chem-ph": "Chemical Physics",
        "physics.class-ph": "Classical Physics",
        "physics.comp-ph": "Computational Physics",
        "physics.data-an": "Data Analysis, Statistics and Probability",
        "physics.ed-ph": "Physics Education",
        "physics.flu-dyn": "Fluid Dynamics",
        "physics.gen-ph": "General Physics",
        "physics.geo-ph": "Geophysics",
        "physics.hist-ph": "History and Philosophy of Physics",
        "physics.ins-det": "Instrumentation and Detectors",
        "physics.med-ph": "Medical Physics",
        "physics.optics": "Optics",
        "physics.plasm-ph": "Plasma Physics",
        "physics.pop-ph": "Popular Physics",
        "physics.soc-ph": "Physics and Society",
        "physics.space-ph": "Space Physics",
        "hep-ex": "High Energy Physics - Experiment",
        "hep-ph": "High Energy Physics - Phenomenology",
        "hep-th": "High Energy Physics - Theory",
        "hep-lat": "High Energy Physics - Lattice",
        "nucl-ex": "Nuclear Experiment",
        "nucl-th": "Nuclear Theory",
        "gr-qc": "General Relativity & Quantum Cosmology",
        "quant-ph": "Quantum Physics",
        "math-ph": "Mathematical Physics",
    ]

    private func displayName(for category: String) -> String {
        categoryDisplayName[category.lowercased()] ?? category
    }

    private var canContinue: Bool { !localSelected.isEmpty && !isLoading }

    // Groups are inferred from the prefix before the first dot
    private var groupedCategories: [(key: String, values: [String])] {
        let grouped = Dictionary(grouping: allCategories) { cat in
            cat.split(separator: ".").first.map(String.init) ?? "other"
        }
        let order = ["hep", "nucl", "astro-ph", "cond-mat", "quant-ph", "gr-qc", "math-ph", "nlin", "physics"]
        return grouped
            .map { (key: $0.key, values: $0.value.sorted()) }
            .sorted { a, b in
                let ia = order.firstIndex(of: a.key) ?? 999
                let ib = order.firstIndex(of: b.key) ?? 999
                if ia != ib { return ia < ib }
                return a.key < b.key
            }
    }

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
//        .overlay(
//            RoundedRectangle(cornerRadius: 16, style: .continuous)
//                .stroke(KiwiColors.darkBrown.opacity(0.10), lineWidth: 0)
//        )
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

        await MainActor.run { isLoading = true }

        let selected = Array(localSelected).sorted()

        // Commit settings first
        await MainActor.run {
            settingsStore.setSelectedCategories(selected)
            settingsStore.setCompletedOnboarding(true)
        }

        // Sync papers
        let manager = NetworkManager(context: modelContext)
        await manager.syncPapers(for: selected)

        await MainActor.run { isLoading = false }
    }

    private func softHaptic() {
        guard !settingsStore.hapticsDisabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    }
}
