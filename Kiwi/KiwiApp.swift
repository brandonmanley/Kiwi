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

        // Hide the native pull-to-refresh spinner everywhere — we draw our own
        // RefreshingDotsView instead. SwiftUI's `.tint(.clear)` doesn't reliably
        // suppress it, but zeroing the UIRefreshControl appearance does.
        let clearRefresh = UIRefreshControl.appearance()
        clearRefresh.tintColor = .clear
        clearRefresh.attributedTitle = NSAttributedString(string: "")

        let builtContainer: ModelContainer
        do {
            builtContainer = try ModelContainer(for: Paper.self, UserSettings.self)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }

        self.container = builtContainer
        _settingsStore = StateObject(
            wrappedValue: SettingsStore(modelContext: builtContainer.mainContext)
        )
    }

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
