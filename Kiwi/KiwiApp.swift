import SwiftUI
import SwiftData
import UIKit

@MainActor
@main
struct KiwiApp: App {

    private let container: ModelContainer
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

        let builtContainer: ModelContainer
        do {
            #if DEBUG
            // UI-test hook: "-uitest-seed-reading-list" boots an in-memory store
            // pre-populated with saved papers so tests can exercise the reading
            // list without network or onboarding.
            if ProcessInfo.processInfo.arguments.contains("-uitest-seed-reading-list") {
                let config = ModelConfiguration(isStoredInMemoryOnly: true)
                builtContainer = try ModelContainer(for: Paper.self, UserSettings.self, configurations: config)
                Self.seedForUITests(container: builtContainer)
            } else {
                builtContainer = try ModelContainer(for: Paper.self, UserSettings.self)
            }
            #else
            builtContainer = try ModelContainer(for: Paper.self, UserSettings.self)
            #endif
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }

        self.container = builtContainer
        _settingsStore = StateObject(
            wrappedValue: SettingsStore(modelContext: builtContainer.mainContext)
        )
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
            RootView()
                .modelContainer(container)
                .environmentObject(settingsStore)
                .environmentObject(uiState)
                .environmentObject(router)
                .environmentObject(syncService)
                .preferredColorScheme(settingsStore.darkModeEnabled ? .dark : .light)
                .task { syncService.bind(uiState: uiState) }
        }
    }

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
            fatalError("Failed to ensure Application Support exists: \(error)")
        }
    }
}
