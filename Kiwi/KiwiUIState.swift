import Foundation
import SwiftUI
import Combine
import Network

@MainActor
final class KiwiUIState: ObservableObject {
    @Published var isMenuOpen: Bool = false
    @Published private(set) var isConnected: Bool = true
    @Published var isRefreshing: Bool = false
    @Published var refreshMessage: String? = nil
    // Optional action rendered as a button in the toast (e.g. "Undo").
    @Published var refreshAction: ToastAction? = nil
    // Live per-category sync progress for the toast; nil when idle.
    @Published var syncProgress: (done: Int, total: Int)? = nil

    struct ToastAction {
        let label: String
        let perform: @MainActor () -> Void
    }

    private let monitor = NWPathMonitor()
    private var refreshMessageTask: Task<Void, Never>?
    private var connectivityTask: Task<Void, Never>?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.updateConnectivity(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.kiwi.networkmonitor"))
    }

    // NWPathMonitor reports `.unsatisfied` transiently during Wi-Fi↔cellular
    // handoff and VPN transitions. Recover immediately, but only flip to offline
    // after the path has stayed unsatisfied for ~2s — otherwise a blip produces
    // a spurious "No connection" banner and (worse) blocks an otherwise-fine sync.
    private func updateConnectivity(satisfied: Bool) {
        connectivityTask?.cancel()
        if satisfied {
            isConnected = true
        } else {
            connectivityTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.isConnected = false
            }
        }
    }

    func flashRefreshMessage(
        _ message: String,
        duration: TimeInterval = 2.5,
        action: ToastAction? = nil
    ) {
        refreshMessageTask?.cancel()
        refreshMessage = message
        refreshAction = action
        refreshMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshMessage = nil
            self?.refreshAction = nil
        }
    }

    // Dismiss the current toast immediately (e.g. after the user taps its action).
    func dismissRefreshMessage() {
        refreshMessageTask?.cancel()
        refreshMessage = nil
        refreshAction = nil
    }
}
