import SwiftUI
import Combine

@MainActor
final class KiwiRouter: ObservableObject {

    enum Route: Hashable {
        case daily
        case readingList
        case settings
        case search
        case author
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

    // Keep `currentRoute` honest when the path changes outside `go`/`goHome`
    // (a custom chevron's dismiss, or an edge-swipe back). The app only ever
    // pushes one level deep, so an empty path means we're back on Home.
    // RootView drives this from `.onChange(of: path.count)`.
    func reconcileWithPath() {
        if path.isEmpty { currentRoute = nil }
    }
}
