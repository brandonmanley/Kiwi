import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {

    // MARK: - Environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var syncService: PaperSyncService

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

    @State private var showLeaveDialog = false
    @State private var showNotifDeniedHint = false

    private var allCategories: [String] { ArxivCategories.all }
    private var groupedCategories: [(key: String, values: [String])] { ArxivCategories.grouped() }
    private func displayName(for category: String) -> String { ArxivCategories.displayName(for: category) }

    private var hasChanges: Bool { localSelected != originalSelected }
    private var canUpdate: Bool { !isUpdatingPapers && !localSelected.isEmpty && hasChanges }

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
                            .font(.custom("Pulang", size: 22, relativeTo: .title))
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
                            softHaptic()
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
                // Transparent over the screen gradient, matching every other
                // screen's KiwiNavBar — the ultraThinMaterial fill here read as a
                // slightly different shade at the top than Home/Reading list.

                ScrollView {
                    VStack(spacing: 14) {
                        
                        // --- App preferences card ---
                        settingsCard(title: "Preferences") {
                            VStack(spacing: 10) {

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Appearance")
                                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                            .foregroundColor(KiwiColors.darkBrown)
                                        Text("Follow the system, or force light / dark")
                                            .font(.system(.caption, design: .rounded, weight: .medium))
                                            .foregroundColor(KiwiColors.darkBrown.opacity(0.60))
                                    }
                                    Spacer()
                                    Picker("Appearance", selection: Binding(
                                        get: { settingsStore.appearance },
                                        set: { settingsStore.setAppearance($0); softHaptic() }
                                    )) {
                                        ForEach(SettingsStore.Appearance.allCases) { option in
                                            Text(option.label).tag(option)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 180)
                                }

                                toggleRow(
                                    title: "Haptics",
                                    subtitle: "Vibration feedback on actions",
                                    isOn: Binding(
                                        get: { !settingsStore.hapticsDisabled },
                                        set: { settingsStore.setHapticsDisabled(!$0) }
                                    )
                                )
                            }
                        }
                        
                        // --- Notifications card ---
                        settingsCard(title: "Notifications") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Off, a daily summary at the announcement time, or an alert when new papers match your keywords.")
                                    .font(.system(.caption, design: .rounded, weight: .medium))
                                    .foregroundColor(KiwiColors.darkBrown.opacity(0.65))

                                HStack {
                                    Text("Mode")
                                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                        .foregroundColor(KiwiColors.darkBrown)
                                    Spacer()
                                    Picker("Notifications", selection: Binding(
                                        get: { settingsStore.notificationMode },
                                        set: { handleNotificationModeChange($0) }
                                    )) {
                                        ForEach(SettingsStore.NotificationMode.allCases) { mode in
                                            Text(mode.label).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(KiwiColors.darkBrown)
                                }
                            }
                        }

                        // --- Daily papers card ---
                        settingsCard(title: "Daily papers") {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Days to show")
                                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                        .foregroundColor(KiwiColors.darkBrown)
                                    Text("Number of days in the daily view (1–21)")
                                        .font(.system(.caption, design: .rounded, weight: .medium))
                                        .foregroundColor(KiwiColors.darkBrown.opacity(0.60))
                                }
                                Spacer()
                                Stepper("\(settingsStore.dailyPapersDays)", value: Binding(
                                    get: { settingsStore.dailyPapersDays },
                                    set: { settingsStore.setDailyPapersDays($0) }
                                ), in: 1...21)
                                .onChange(of: settingsStore.dailyPapersDays) { softHaptic() }
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundColor(KiwiColors.darkBrown)
                                .frame(width: 140)
                            }
                        }

                        // --- Keywords card ---
                        settingsCard(title: "Keywords") {
                            VStack(alignment: .leading, spacing: 10) {
                                
                                Text("Prioritize papers matching these terms in title, authors, or abstract.")
                                    .font(.system(.caption, design: .rounded, weight: .medium))
                                    .foregroundColor(KiwiColors.darkBrown.opacity(0.65))
                                
                                // Input row
                                HStack(spacing: 8) {
                                    TextField("Add keyword", text: $keywordText)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
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
                                                    .font(.system(.caption, design: .rounded, weight: .medium))
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
                                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                        .foregroundColor(KiwiColors.darkBrown.opacity(0.85))
                                    Spacer()
                                    
                                    Button("All") {
                                        localSelected = Set(allCategories)
                                        softHaptic()
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(KiwiColors.darkBrown.opacity(0.9))
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    
                                    Text("·")
                                        .foregroundColor(KiwiColors.darkBrown.opacity(0.35))
                                    
                                    Button("Clear") {
                                        localSelected.removeAll()
                                        softHaptic()
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(KiwiColors.darkBrown.opacity(0.9))
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
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
                                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                                    .foregroundColor(KiwiColors.darkBrown)
                                                Spacer()
                                                Text("\(group.values.filter { localSelected.contains($0) }.count)")
                                                    .font(.system(.footnote, design: .rounded, weight: .medium))
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
                            commitAndSync()
                        } label: {
                            HStack {
                                Spacer()
                                if isUpdatingPapers {
                                    ProgressView().tint(KiwiColors.darkBrown)
                                } else {
                                    Text(localSelected.isEmpty ? "Select at least one category" : "Update papers")
                                        .font(.system(.callout, design: .rounded, weight: .semibold))
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
        .confirmationDialog("You changed categories", isPresented: $showLeaveDialog, titleVisibility: .visible) {
            Button("Update papers") { commitAndSync() }
            Button("Discard changes", role: .destructive) {
                localSelected = originalSelected
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apply your category changes, or discard them?")
        }
        .alert("Notifications are off", isPresented: $showNotifDeniedHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable notifications for Kiwi in the Settings app to use this.")
        }

    }

    // MARK: - UI helpers

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .semibold))
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
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown)

                Text(subtitle)
                    .font(.system(.caption, design: .rounded, weight: .medium))
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
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)                      // allow wrapping
                        .fixedSize(horizontal: false, vertical: true)

                    // Optional: keep the arXiv code visible but subtle
                    Text(category.lowercased())
                        .font(.system(.caption2, design: .rounded, weight: .medium))
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
        // The user can always leave now — a confirmation dialog offers to apply
        // or discard, instead of the old back-button block that trapped them.
        if hasChanges {
            showLeaveDialog = true
        } else {
            dismiss()
        }
    }

    // Requests authorization only when the user opts in; a denial degrades quietly
    // (reverts to Off + a one-time hint) rather than nagging.
    private func handleNotificationModeChange(_ mode: SettingsStore.NotificationMode) {
        softHaptic()
        if mode == .off {
            settingsStore.setNotificationMode(.off)
            NotificationManager.cancelAll()
            return
        }
        Task {
            let granted = await NotificationManager.requestAuthorization()
            if granted {
                settingsStore.setNotificationMode(mode)
                if mode == .daily {
                    await NotificationManager.scheduleDailySummary()
                } else {
                    // Keyword alerts are posted by background sync; no scheduled summary.
                    NotificationManager.cancelAll()
                }
            } else {
                settingsStore.setNotificationMode(.off)
                showNotifDeniedHint = true
            }
        }
    }

    // Commit the selection and kick off the sync through the shared service, then
    // dismiss immediately — the toast (with its progress counter and coalescing)
    // handles feedback, so we don't block behind an in-view spinner.
    private func commitAndSync() {
        guard !localSelected.isEmpty else { return }
        softHaptic()
        let selected = Array(localSelected)

        settingsStore.setSelectedCategories(selected)
        originalSelected = localSelected

        let context = modelContext
        let store = settingsStore
        Task {
            let outcome = await syncService.sync(context: context, categories: selected)
            switch outcome {
            case .added:            Haptics.notification(.success, store: store)
            case .failed, .offline: Haptics.notification(.error, store: store)
            default:                break
            }
        }
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
                            .font(.custom("Pulang", size: 18, relativeTo: .title3))
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
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundColor(KiwiColors.darkBrown.opacity(0.80))

//                    Divider().opacity(0.25)

                    Text(buildString)
                        .font(.system(.footnote, design: .rounded, weight: .medium))
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


