import Foundation
import SwiftUI
import Combine
import Network

@MainActor
final class KiwiUIState: ObservableObject {
    @Published var isMenuOpen: Bool = false
    @Published private(set) var isConnected: Bool = true

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.kiwi.networkmonitor"))
    }
}
