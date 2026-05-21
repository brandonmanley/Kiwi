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

    private let monitor = NWPathMonitor()
    private var refreshMessageTask: Task<Void, Never>?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.kiwi.networkmonitor"))
    }

    func flashRefreshMessage(_ message: String, duration: TimeInterval = 2.5) {
        refreshMessageTask?.cancel()
        refreshMessage = message
        refreshMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshMessage = nil
        }
    }
}
