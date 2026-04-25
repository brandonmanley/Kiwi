import SwiftUI
import Combine

@MainActor
final class KiwiRouter: ObservableObject {

    enum Route: Hashable {
        case daily
        case readingList
        case settings
        case search
    }

    @Published var path = NavigationPath()
    @Published private(set) var currentRoute: Route? = nil  // nil = Home

    func goHome() {
        path = NavigationPath()
        currentRoute = nil
    }

    func go(_ route: Route) {
        path = NavigationPath()
        path.append(route)
        currentRoute = route
    }
}
