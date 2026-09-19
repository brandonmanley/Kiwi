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
        case partial(succeeded: Int, total: Int)
        case upToDate
        case noCategories
        case offline
        case failed
    }

    // Per-category sync timestamps, so auto-sync skips only categories synced
    // within the interval and a partial failure retries just what failed rather
    // than redoing the whole set.
    @Published private(set) var lastSyncedAt: [String: Date] = [:]

    private weak var uiState: KiwiUIState?
    private var inFlight: Task<Outcome, Never>?

    private let lastSyncKey = "PaperSyncService.lastSyncedAtByCategory"
    // Auto-fetch on view appearance shouldn't hammer arXiv if the user just synced.
    private let autoSyncMinInterval: TimeInterval = 60 * 5

    init() {
        if let stored = UserDefaults.standard.object(forKey: lastSyncKey) as? [String: Date] {
            lastSyncedAt = stored
        }
    }

    func bind(uiState: KiwiUIState) {
        self.uiState = uiState
    }

    /// User-initiated sync. Always fetches the full selection (or joins an
    /// in-flight run).
    @discardableResult
    func sync(
        context: ModelContext,
        categories: [String],
        showMessages: Bool = true
    ) async -> Outcome {
        await run(
            context: context,
            fetchCategories: categories,
            allCategories: categories,
            showMessages: showMessages
        )
    }

    /// Auto-fetch on view appearance. Fetches only the categories that are stale
    /// (or missing a recorded sync). Connectivity here is a genuine gate —
    /// failing an auto-fetch silently is fine, so we don't attempt it offline.
    @discardableResult
    func autoSync(
        context: ModelContext,
        categories: [String]
    ) async -> Outcome {
        if uiState?.isConnected == false { return .offline }

        let now = Date()
        let stale = categories.filter { category in
            guard let last = lastSyncedAt[category] else { return true }
            return now.timeIntervalSince(last) >= autoSyncMinInterval
        }
        guard !stale.isEmpty else { return .upToDate }

        return await run(
            context: context,
            fetchCategories: stale,
            allCategories: categories,
            showMessages: true
        )
    }

    private func run(
        context: ModelContext,
        fetchCategories: [String],
        allCategories: [String],
        showMessages: Bool
    ) async -> Outcome {
        if let inFlight {
            return await inFlight.value
        }

        guard !allCategories.isEmpty else {
            if showMessages {
                uiState?.flashRefreshMessage("Choose categories in Settings")
            }
            return .noCategories
        }
        guard !fetchCategories.isEmpty else { return .upToDate }

        // Connectivity is now advisory, not a gate: attempt the request
        // regardless and let URLError be the authority on being offline. The
        // pre-flight check survives only in autoSync above.
        uiState?.isRefreshing = true
        uiState?.syncProgress = (0, fetchCategories.count)

        // Weak hop to the UI state; KiwiUIState is @MainActor-isolated (Sendable).
        let uiState = self.uiState
        let onProgress: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor in uiState?.syncProgress = (done, total) }
        }

        // A9: assign inFlight before the first await and clear it in a defer at
        // the await site, so a task that finished early can't leave a stale
        // non-nil inFlight that permanently short-circuits future syncs.
        let task = Task<Outcome, Never> { [weak self] in
            let manager = NetworkManager(context: context)
            let result = await manager.syncPapers(
                fetchCategories: fetchCategories,
                selectedCategories: allCategories,
                onProgress: onProgress
            )
            return await MainActor.run { [weak self] in
                self?.finish(result: result, showMessages: showMessages) ?? .upToDate
            }
        }
        inFlight = task
        defer { inFlight = nil }
        return await task.value
    }

    private func finish(result: NetworkManager.SyncResult, showMessages: Bool) -> Outcome {
        uiState?.isRefreshing = false
        uiState?.syncProgress = nil

        // Record success timestamps per category so cheap partial retries work.
        if !result.succeededCategories.isEmpty {
            let now = Date()
            for category in result.succeededCategories { lastSyncedAt[category] = now }
            UserDefaults.standard.set(lastSyncedAt, forKey: lastSyncKey)
        }

        let succeeded = result.succeededCategories.count
        let total = result.totalCategories

        // Every category succeeded.
        if succeeded == total {
            if result.added > 0 {
                if showMessages {
                    uiState?.flashRefreshMessage("Added \(result.added) \(result.added == 1 ? "paper" : "papers")!")
                }
                return .added(result.added)
            }
            if showMessages {
                uiState?.flashRefreshMessage("Up to date — \(NetworkManager.friendlyNextAnnouncement())")
            }
            return .upToDate
        }

        // Some — but not all — succeeded.
        if succeeded > 0 {
            if showMessages {
                uiState?.flashRefreshMessage("Synced \(succeeded) of \(total) categories — tap to retry")
            }
            return .partial(succeeded: succeeded, total: total)
        }

        // Everything failed: name the dominant cause. Never blame the
        // connection for a failure that wasn't a connection failure.
        if showMessages {
            uiState?.flashRefreshMessage(Self.message(for: result.dominantFailure))
        }
        return .failed
    }

    private static func message(for failure: SyncFailure?) -> String {
        switch failure {
        case .throttled:                   return "arXiv is busy — try again in a moment"
        case .offline:                     return "No connection — try again"
        case .serverError, .timedOut, .parseFailed:
                                           return "arXiv isn't responding — try again shortly"
        case .none:                        return "Couldn't sync — try again"
        }
    }
}
