//
//  Paper.swift
//  Kiwi
//
//  Created by Brandon Manley on 1/11/26.
//

import Foundation
import SwiftData

@Model
class Paper {
    @Attribute(.unique) var id: UUID = UUID()
    
    var title: String
    var authors: [String]
    var abstract: String
    var url: URL
    var categories: [String]
    var primaryCategory: String
    var date: Date
    var isUpdate: Bool
    var isCrosslist: Bool
    var saved: Bool = false
    var pinned: Bool = false
    var savedDate: Date?
    
    init(title: String, authors: [String], abstract: String, url: URL, categories: [String],
         primaryCategory: String, date: Date, isUpdate: Bool, isCrosslist: Bool) {
        self.title = title
        self.authors = authors
        self.abstract = abstract
        self.url = url
        self.categories = categories
        self.primaryCategory = primaryCategory
        self.date = date
        self.isUpdate = isUpdate
        self.isCrosslist = isCrosslist
    }
}
