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
    static let lightGreen  = Color(hex: "#e2f7c3")
    static let lightBrown  = Color(hex: "#563429")
    static let darkGreen   = Color(hex: "#61AB5A")

    // These two become dynamic via Color Assets:
    static let creamWhite  = Color("KiwiCreamWhite")
    static let darkBrown   = Color("KiwiDarkBrown")
}
