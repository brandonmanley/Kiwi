import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks

@MainActor
@main
struct KiwiApp: App {

    static let refreshTaskID = "com.kiwi.refresh"

    private let container: ModelContainer
    private let isInRecoveryMode: Bool
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var uiState = KiwiUIState()
    @StateObject private var router = KiwiRouter()
    @StateObject private var syncService = PaperSyncService()

    init() {
        Self.ensureApplicationSupportExists()

        // Hide the native pull-to-refresh spinner everywhere — refresh feedback
        // comes from the toast in RootView instead. SwiftUI's `.tint(.clear)`
        // doesn't reliably suppress it, but zeroing the UIRefreshControl
        // appearance does.
        let clearRefresh = UIRefreshControl.appearance()
        clearRefresh.tintColor = .clear
        clearRefresh.attributedTitle = NSAttributedString(string: "")

        // Build the store, but never crash the launch on failure (a corrupt store
        // after a bad migration would otherwise brick the app). Retry once against
        // a fresh store file; if that still fails, fall back to an ephemeral
        // in-memory store and show a recovery screen instead of a fatalError.
        var built: ModelContainer
        var recovery = false
        do {
            built = try Self.makeContainer()
        } catch {
            #if DEBUG
            print("⚠️ ModelContainer failed, retrying with a fresh store: \(error)")
            #endif
            Self.destroyDefaultStore()
            do {
                built = try Self.makeContainer()
            } catch {
                #if DEBUG
                print("⚠️ ModelContainer still failing, using in-memory fallback: \(error)")
                #endif
                recovery = true
                built = try! ModelContainer(
                    for: Paper.self, UserSettings.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            }
        }

        self.container = built
        self.isInRecoveryMode = recovery
        _settingsStore = StateObject(
            wrappedValue: SettingsStore(modelContext: built.mainContext)
        )
    }

    private static func makeContainer() throws -> ModelContainer {
        #if DEBUG
        // UI-test hook: "-uitest-seed-reading-list" boots an in-memory store
        // pre-populated with saved papers so tests can exercise the reading
        // list without network or onboarding.
        if ProcessInfo.processInfo.arguments.contains("-uitest-seed-reading-list") {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let seeded = try ModelContainer(for: Paper.self, UserSettings.self, configurations: config)
            seedForUITests(container: seeded)
            return seeded
        }
        #endif
        return try ModelContainer(for: Paper.self, UserSettings.self)
    }

    // Removes the default SwiftData store files so a retry starts clean.
    private static func destroyDefaultStore() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return }
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            try? fm.removeItem(at: appSupport.appendingPathComponent(name))
        }
    }

    #if DEBUG
    private static func seedForUITests(container: ModelContainer) {
        let context = container.mainContext

        let settings = UserSettings(
            selectedCategories: ["hep-ph"],
            clickedDays: [],
            hasCompletedOnboarding: true
        )
        context.insert(settings)

        for i in 1...10 {
            let paper = Paper(
                title: "Seeded Paper \(i): A Study of Test Fixtures in Scroll Physics",
                authors: ["Ada Lovelace", "Grace Hopper"],
                abstract: "Abstract for seeded paper \(i). This exists to fill the reading list during UI tests.",
                url: URL(string: "https://arxiv.org/abs/9999.0000\(i)")!,
                categories: ["hep-ph"],
                primaryCategory: "hep-ph",
                date: Date(),
                isUpdate: false,
                isCrosslist: false
            )
            paper.saved = true
            paper.savedDate = Date()
            context.insert(paper)
        }

        // Unsaved papers dated today so the Home list is populated too.
        for i in 1...12 {
            let paper = Paper(
                title: "Seeded Today Paper \(i): Fixtures for the Home List",
                authors: ["Ada Lovelace"],
                abstract: "Abstract for seeded today paper \(i).",
                url: URL(string: "https://arxiv.org/abs/8888.000\(i)")!,
                categories: ["hep-ph"],
                primaryCategory: "hep-ph",
                date: Calendar.current.startOfDay(for: Date()),
                isUpdate: false,
                isCrosslist: false
            )
            context.insert(paper)
        }

        try? context.save()
    }

    static var isUITestSeedRun: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-seed-reading-list")
    }
    #endif

    var body: some Scene {
        WindowGroup {
            if isInRecoveryMode {
                RecoveryView()
            } else {
                RootView()
                    .modelContainer(container)
                    .environmentObject(settingsStore)
                    .environmentObject(uiState)
                    .environmentObject(router)
                    .environmentObject(syncService)
                    .preferredColorScheme(settingsStore.preferredColorScheme)
                    .task { syncService.bind(uiState: uiState) }
            }
        }
        // Registers the BGAppRefreshTask handler (SwiftUI calls BGTaskScheduler
        // .register for us). Runs a sync shortly after the announcement window.
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await performBackgroundRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Self.scheduleAppRefresh() }
        }
    }

    // Ask iOS to run us again shortly after the next announcement. iOS decides
    // the actual time; this is only the earliest.
    static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = NetworkManager.nextAnnouncement().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // Background handler: re-arm, sync the selection, and (in keyword mode) post a
    // notification naming the top match. Runs on the main actor; syncPapers checks
    // Task cancellation so it stops gracefully if iOS reclaims the time budget.
    @MainActor
    private func performBackgroundRefresh() async {
        Self.scheduleAppRefresh()

        let categories = settingsStore.selectedCategories
        guard !categories.isEmpty else { return }

        let manager = NetworkManager(context: container.mainContext)
        let result = await manager.syncPapers(for: categories)

        guard settingsStore.notificationMode == .keywords,
              result.added > 0,
              let prepared = TextScorer.prepare(keywords: settingsStore.keywords) else { return }

        // Score today's papers; notify about the strongest match + total count.
        let todayStart = Calendar.current.startOfDay(for: Date())
        let descriptor = FetchDescriptor<Paper>(predicate: #Predicate { $0.date >= todayStart })
        let todays = (try? container.mainContext.fetch(descriptor)) ?? []

        let matches = todays.compactMap { paper -> (Paper, Double)? in
            let t = TokenCache.shared.tokens(for: paper)
            let score = TextScorer.score(
                titleTokens: t.title, authorTokens: t.authors, abstractTokens: t.abstract,
                haystack: t.haystack, prepared: prepared, weights: .keyword
            )
            return score > 0.0001 ? (paper, score) : nil
        }
        guard let top = matches.max(by: { $0.1 < $1.1 }) else { return }
        await NotificationManager.postKeywordMatch(topTitle: top.0.title, count: matches.count)
    }

    // Best-effort: SwiftData needs the directory to exist, but a failure here
    // shouldn't crash the launch — the container build (with its retry/recovery)
    // is the real gate.
    private static func ensureApplicationSupportExists() {
        let fileManager = FileManager.default
        do {
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try fileManager.createDirectory(
                at: appSupportURL,
                withIntermediateDirectories: true
            )
        } catch {
            #if DEBUG
            print("⚠️ Failed to ensure Application Support exists: \(error)")
            #endif
        }
    }
}

// Minimal screen shown when the persistent store can't be opened even after a
// reset — the app runs on an ephemeral in-memory store so the user isn't stuck.
private struct RecoveryView: View {
    var body: some View {
        ZStack {
            KiwiColors.creamWhite.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.5))
                Text("Couldn't open your library")
                    .font(.custom("Pulang", size: 22, relativeTo: .title))
                    .foregroundColor(KiwiColors.darkBrown)
                Text("Kiwi ran into a problem loading saved data and is running in a temporary mode. Restarting the app usually fixes it.")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            .padding(28)
        }
    }
}
