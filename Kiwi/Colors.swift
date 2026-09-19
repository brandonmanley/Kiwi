import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanner = Scanner(string: hex)
        
        if hex.hasPrefix("#") {
            scanner.currentIndex = hex.index(after: hex.startIndex)
        }
        
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        
        self.init(red: r, green: g, blue: b)
    }
}


import SwiftUI

struct KiwiColors {
    // All five are now dynamic (light/dark) via the asset catalog, so the drawer,
    // filter chips, and backgrounds follow the color scheme instead of staying
    // bright. `lightBrown` was misnamed — it is #563429, a dark brown — and is
    // now `deepBrown`.
    static let lightGreen  = Color("KiwiLightGreen")
    static let deepBrown   = Color("KiwiDeepBrown")
    static let darkGreen   = Color("KiwiDarkGreen")
    static let creamWhite  = Color("KiwiCreamWhite")
    static let darkBrown   = Color("KiwiDarkBrown")
}
