import Foundation
import SwiftData
import SwiftUI
import Combine

// Centralized coordinator for paper syncs.
//
// Why this exists:
// - Pull-to-refresh used to run inside SwiftUI's `.refreshable` task, which
//   gets cancelled if the user navigates away mid-fetch (arXiv calls can take
//   20+ seconds). The side menu used an unstructured Task, which is why it
//   felt more reliable. This service owns the Task itself, so view lifecycle
//   can no longer kill an in-progress sync.
// - Multiple call sites (auto-fetch on Home, pull-to-refresh, side menu)
//   could previously race. This service coalesces concurrent calls onto a
//   single in-flight Task — no more silent cancellations.
// - All callers share one `uiState.isRefreshing` flag and one toast pipeline.
@MainActor
final class PaperSyncService: ObservableObject {

    enum Outcome: Equatable {
        case added(Int)
        case upToDate
        case noCategories
        case offline
        case failed
    }

    @Published private(set) var lastSyncedAt: Date?

    private weak var uiState: KiwiUIState?
    private var inFlight: Task<Outcome, Never>?

    private let lastSyncKey = "PaperSyncService.lastSyncedAt"
    // Auto-fetch on view appearance shouldn't hammer arXiv if the user just synced.
    private let autoSyncMinInterval: TimeInterval = 60 * 5

    init() {
        if let stored = UserDefaults.standard.object(forKey: lastSyncKey) as? Date {
            lastSyncedAt = stored
        }
    }

    func bind(uiState: KiwiUIState) {
        self.uiState = uiState
    }

    /// User-initiated sync. Always runs (or joins an in-flight one).
    @discardableResult
    func sync(
        context: ModelContext,
        categories: [String],
        showMessages: Bool = true
    ) async -> Outcome {
        if let inFlight {
            return await inFlight.value
        }

        guard !categories.isEmpty else {
            if showMessages {
                uiState?.flashRefreshMessage("Choose categories in Settings")
            }
            return .noCategories
        }

        if uiState?.isConnected == false {
            if showMessages {
                uiState?.flashRefreshMessage("No connection — try again")
            }
            return .offline
        }

        uiState?.isRefreshing = true

        let task = Task<Outcome, Never> { [weak self] in
            let manager = NetworkManager(context: context)
            let result = await manager.syncPapers(for: categories)
            return await MainActor.run { [weak self] in
                self?.finish(result: result, showMessages: showMessages) ?? .upToDate
            }
        }
        inFlight = task
        return await task.value
    }

    /// Auto-fetch on view appearance. Skips if a recent successful sync exists.
    @discardableResult
    func autoSync(
        context: ModelContext,
        categories: [String]
    ) async -> Outcome {
        if let last = lastSyncedAt,
           Date().timeIntervalSince(last) < autoSyncMinInterval {
            return .upToDate
        }
        return await sync(context: context, categories: categories, showMessages: true)
    }

    private func finish(result: NetworkManager.SyncResult, showMessages: Bool) -> Outcome {
        uiState?.isRefreshing = false
        inFlight = nil

        if result.failed {
            if showMessages {
                uiState?.flashRefreshMessage("Couldn't sync — check connection")
            }
            return .failed
        }

        let now = Date()
        lastSyncedAt = now
        UserDefaults.standard.set(now, forKey: lastSyncKey)

        if result.added > 0 {
            if showMessages {
                uiState?.flashRefreshMessage("Added \(result.added) papers!")
            }
            return .added(result.added)
        }

        if showMessages {
            uiState?.flashRefreshMessage("Up to date — \(NetworkManager.friendlyNextAnnouncement())")
        }
        return .upToDate
    }
}
