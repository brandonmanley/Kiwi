//
//  Item.swift
//  Kiwi
//
//  Created by Brandon Manley on 1/11/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
