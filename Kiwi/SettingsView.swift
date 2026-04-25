import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {

    // MARK: - Environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settingsStore: SettingsStore

    // MARK: - Local UI state
    @State private var localSelected: Set<String> = []
    @State private var originalSelected: Set<String> = []
    @State private var isUpdatingPapers = false
    @State private var keywordText: String = ""
    
    @State private var showBetaInfo = false

    private var buildString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    @State private var showMustUpdateAlert = false

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

    private var hasChanges: Bool { localSelected != originalSelected }
    private var canUpdate: Bool { !isUpdatingPapers && !localSelected.isEmpty && hasChanges }

    // Groups are inferred from the prefix before the first dot
    private var groupedCategories: [(key: String, values: [String])] {
        let grouped = Dictionary(grouping: allCategories) { cat in
            cat.split(separator: ".").first.map(String.init) ?? "other"
        }
        // Nice ordering
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

    // MARK: - Body
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [KiwiColors.creamWhite, KiwiColors.creamWhite.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Custom nav bar: back is controlled (can’t leave while dirty)
                KiwiNavBar(
                    title: {
                        Text("Settings")
                            .font(.custom("Pulang", size: 22))
                            .foregroundColor(KiwiColors.darkBrown)
                    },
                    left: {
                        Button {
                            attemptLeave()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44, alignment: .leading)
                                .foregroundColor(KiwiColors.darkBrown)
                        }
                        .buttonStyle(.plain)
                        .disabled(isUpdatingPapers)
                        .opacity(isUpdatingPapers ? 0.35 : 1.0)
                    },
                    right: {
                        Button {
                            showBetaInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(KiwiColors.darkBrown)
                                .frame(width: 36, height: 36)
                                .background(
                                    Circle().fill(KiwiColors.creamWhite.opacity(0.85))
                                )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                        .disabled(isUpdatingPapers)
                        .opacity(isUpdatingPapers ? 0.35 : 1.0)
                    }
                )
                .background(.ultraThinMaterial) // matches your new translucent direction
                
                ScrollView {
                    VStack(spacing: 14) {
                        
                        // --- App preferences card ---
                        settingsCard(title: "Preferences") {
                            VStack(spacing: 10) {
                                
                                toggleRow(
                                    title: "Dark mode",
                                    subtitle: "Swap cream / brown colors",
                                    isOn: Binding(
                                        get: { settingsStore.darkModeEnabled },
                                        set: { settingsStore.setDarkModeEnabled($0) }
                                    )
                                )
                            }
                        }
                        
                        // --- Keywords card ---
                        settingsCard(title: "Keywords") {
                            VStack(alignment: .leading, spacing: 10) {
                                
                                Text("Prioritize papers matching these terms in title, authors, or abstract.")
                                    .font(.custom("ArialRoundedMTBold", size: 12))
                                    .foregroundColor(KiwiColors.darkBrown.opacity(0.65))
                                
                                // Input row
                                HStack(spacing: 8) {
                                    TextField("Add keyword", text: $keywordText)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .font(.custom("ArialRoundedMTBold", size: 14))
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(KiwiColors.creamWhite.opacity(0.9))
                                        )
                                    
                                    Button {
                                        let trimmed = keywordText.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !trimmed.isEmpty else { return }
                                        settingsStore.addKeyword(trimmed)
                                        keywordText = ""
                                        softHaptic()
                                    } label: {
                                        Image(systemName: "plus")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(KiwiColors.creamWhite)
                                            .frame(width: 34, height: 34)
                                            .background(
                                                Circle()
                                                    .fill(KiwiColors.darkGreen)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                // Existing keywords
                                if !settingsStore.keywords.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(settingsStore.keywords, id: \.self) { kw in
                                            HStack(spacing: 6) {
                                                Text(kw.lowercased())
                                                    .font(.custom("ArialRoundedMTBold", size: 12))
                                                    .foregroundColor(KiwiColors.darkBrown)

                                                Spacer()

                                                Button {
                                                    settingsStore.removeKeyword(kw)
                                                    softHaptic()
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundColor(KiwiColors.darkBrown.opacity(0.7))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.vertical, 6)
                                            .padding(.horizontal, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(KiwiColors.creamWhite.opacity(0.85))
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        
                        
                        
                        // --- Categories card ---
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
                                            .overlay(alignment: .leading) {
                                            }
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
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }
                .scrollDismissesKeyboard(.immediately)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .safeAreaInset(edge: .bottom) {
                    if hasChanges {
                        Button {
                            Task { await updatePapersAndCommit() }
                        } label: {
                            HStack {
                                Spacer()
                                if isUpdatingPapers {
                                    ProgressView().tint(KiwiColors.darkBrown)
                                } else {
                                    Text(localSelected.isEmpty ? "Select at least one category" : "Update papers")
                                        .font(.custom("ArialRoundedMTBold", size: 16))
                                        .foregroundColor(KiwiColors.darkBrown)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .glassEffect(.clear, in: .rect(cornerRadius: 16))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.horizontal, 14)
                            .padding(.top, 10) // separates it from content
                        }
                        .disabled(isUpdatingPapers || localSelected.isEmpty)
                        .padding(.bottom, 10)
                    }
                }
            }
            
            
            if showBetaInfo {
                BetaInfoPopup(buildString: buildString) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showBetaInfo = false
                    }
                }
                .transition(.opacity)
            }
            
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            // Load from SettingsStore
            localSelected = Set(settingsStore.selectedCategories)
            originalSelected = localSelected
        }
        .alert("Update required", isPresented: $showMustUpdateAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You changed categories. Tap “Update papers” at the bottom to apply changes.")
        }
        
    }

    // MARK: - UI helpers

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("ArialRoundedMTBold", size: 20))
                .foregroundColor(KiwiColors.darkBrown)

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(KiwiColors.creamWhite.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(KiwiColors.darkBrown.opacity(0.40), lineWidth: 1.5)
        )
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.custom("ArialRoundedMTBold", size: 15))
                    .foregroundColor(KiwiColors.darkBrown)

                Text(subtitle)
                    .font(.custom("ArialRoundedMTBold", size: 12))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.60))
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(KiwiColors.darkGreen)
        }
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
                        .lineLimit(nil)                      // allow wrapping
                        .fixedSize(horizontal: false, vertical: true)

                    // Optional: keep the arXiv code visible but subtle
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

    // MARK: - Leave / Update behavior

    private func attemptLeave() {
        // Hard rule: cannot leave while dirty.
        if hasChanges {
            showMustUpdateAlert = true
        } else {
            dismiss()
        }
    }

    private func updatePapersAndCommit() async {
        guard !isUpdatingPapers else { return }
        guard !localSelected.isEmpty else { return }

        isUpdatingPapers = true
        defer { isUpdatingPapers = false }

        // Commit categories first
        settingsStore.setSelectedCategories(Array(localSelected))

        // Sync papers
        let manager = NetworkManager(context: modelContext)
        await manager.syncPapers(for: Array(localSelected))

        // Changes are now “accepted”
        originalSelected = localSelected

        dismiss()
    }

    private func softHaptic() {
        // Respect the toggle. You’ll wire this to your haptics usage elsewhere too.
        guard !settingsStore.hapticsDisabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    }
    
    
    private struct BetaInfoPopup: View {
        let buildString: String
        let onClose: () -> Void

        var body: some View {
            ZStack {
                // Dim background + tap to dismiss
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Kiwi beta")
                            .font(.custom("Pulang", size: 18))
                            .foregroundColor(KiwiColors.darkBrown)

                        Spacer()

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(KiwiColors.darkBrown.opacity(0.7))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(KiwiColors.creamWhite.opacity(0.9)))
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Thanks for testing Kiwi.")
                        .font(.custom("ArialRoundedMTBold", size: 13))
                        .foregroundColor(KiwiColors.darkBrown.opacity(0.80))

//                    Divider().opacity(0.25)

                    Text(buildString)
                        .font(.custom("ArialRoundedMTBold", size: 13))
                        .foregroundColor(KiwiColors.darkBrown.opacity(0.85))
                }
                .padding(14)
                .frame(maxWidth: 320)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(KiwiColors.creamWhite.opacity(0.95))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(KiwiColors.darkBrown.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
                .padding(.horizontal, 24)
            }
        }
    }
    
}


