import Foundation
import SwiftUI
import Combine

@MainActor
final class KiwiUIState: ObservableObject {
    @Published var isMenuOpen: Bool = false
}
