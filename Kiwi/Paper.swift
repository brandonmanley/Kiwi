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

    // Original submission date (distinct from the listing `date`), shown in the
    // expanded row. Tier 3 populates it from the feed.
    var submittedDate: Date?
    // Bibliographic extras captured from the RSS/Atom feed (Tier 3).
    var comment: String?
    var journalRef: String?
    var doi: String?
    // Reading-list depth (Tier 4.8).
    var isRead: Bool = false
    var note: String = ""

    // New fields are optional / defaulted so this is an additive (lightweight)
    // SwiftData migration, and every existing call site keeps compiling.
    init(title: String, authors: [String], abstract: String, url: URL, categories: [String],
         primaryCategory: String, date: Date, isUpdate: Bool, isCrosslist: Bool,
         submittedDate: Date? = nil, comment: String? = nil, journalRef: String? = nil,
         doi: String? = nil, isRead: Bool = false, note: String = "") {
        self.title = title
        self.authors = authors
        self.abstract = abstract
        self.url = url
        self.categories = categories
        self.primaryCategory = primaryCategory
        self.date = date
        self.isUpdate = isUpdate
        self.isCrosslist = isCrosslist
        self.submittedDate = submittedDate
        self.comment = comment
        self.journalRef = journalRef
        self.doi = doi
        self.isRead = isRead
        self.note = note
    }
}

// BibTeX generation for a paper. `doi`/`journal` are optional and stay nil until
// the Tier 3 model fields land; everything else derives from the dedup key and
// existing stored fields, so citations work today.
enum Citation {
    // arXiv identifier ("2501.12345") from a paper URL, version stripped.
    static func arxivID(from url: URL) -> String {
        let key = arxivDedupKey(for: url)
        return URL(string: key)?.lastPathComponent ?? key
    }

    static func bibtex(
        id: String,
        title: String,
        authors: [String],
        year: Int,
        primaryClass: String,
        doi: String? = nil,
        journal: String? = nil
    ) -> String {
        let citeKey = "arxiv" + id.replacingOccurrences(of: ".", with: "")
        var lines = ["@article{\(citeKey),"]
        lines.append("  title = {\(title)},")
        let authorField = authors.joined(separator: " and ")
        if !authorField.isEmpty { lines.append("  author = {\(authorField)},") }
        lines.append("  year = {\(year)},")
        lines.append("  eprint = {\(id)},")
        lines.append("  archivePrefix = {arXiv},")
        if !primaryClass.isEmpty, primaryClass.lowercased() != "unknown" {
            lines.append("  primaryClass = {\(primaryClass)},")
        }
        if let doi, !doi.isEmpty { lines.append("  doi = {\(doi)},") }
        if let journal, !journal.isEmpty { lines.append("  journal = {\(journal)},") }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    static func bibtex(for paper: Paper) -> String {
        bibtex(
            id: arxivID(from: paper.url),
            title: paper.title,
            authors: paper.authors,
            year: Calendar.current.component(.year, from: paper.date),
            primaryClass: paper.primaryCategory,
            doi: paper.doi,
            journal: paper.journalRef
        )
    }

    static func bibtex(for card: PaperCard) -> String {
        bibtex(
            id: arxivID(from: card.url),
            title: card.title,
            authors: card.authors,
            year: Calendar.current.component(.year, from: card.sortDate),
            primaryClass: card.primaryCategory,
            doi: card.doi,
            journal: card.journalRef
        )
    }
}

// Lowercased, deduplicated category list with the primary category first.
// Shared by every paper row: a `primaryCategory` differing only in case from a
// `categories` entry would otherwise render as duplicate chips (and, keyed on
// `\.element`, as duplicate SwiftUI identities).
func orderedCategories(primary: String, all: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    let primaryLower = primary.lowercased()
    if !primaryLower.isEmpty {
        result.append(primaryLower)
        seen.insert(primaryLower)
    }
    for category in all {
        let lower = category.lowercased()
        if seen.insert(lower).inserted { result.append(lower) }
    }
    return result
}

// A value-type view model for a paper. Author search renders from cards instead
// of inserting rows: a card either wraps a persisted `Paper` (carrying its saved
// state) or holds fetch-only fields until the user explicitly saves it. Identity
// is the arxivDedupKey so a stored v1 and a fetched v2 are the same card.
struct PaperCard: Identifiable, Hashable {
    let dedupKey: String
    let title: String
    let authors: [String]
    let abstract: String
    let url: URL
    let categories: [String]
    let primaryCategory: String
    let submittedDate: Date?
    let updatedDate: Date?
    let isUpdate: Bool
    let isCrosslist: Bool
    let comment: String?
    let journalRef: String?
    let doi: String?
    // Set when backed by a stored row; nil for a fetch-only result.
    var storedID: PersistentIdentifier?
    var saved: Bool

    var id: String { dedupKey }
    var sortDate: Date { updatedDate ?? submittedDate ?? .distantPast }

    // Equatable includes `saved`/`storedID` so a toggle re-renders the row;
    // identity (hash) stays keyed on dedupKey so list identity is stable.
    static func == (a: PaperCard, b: PaperCard) -> Bool {
        a.dedupKey == b.dedupKey && a.saved == b.saved && a.storedID == b.storedID
    }
    func hash(into hasher: inout Hasher) { hasher.combine(dedupKey) }

    init(_ paper: Paper) {
        dedupKey = arxivDedupKey(for: paper.url)
        title = paper.title
        authors = paper.authors
        abstract = paper.abstract
        url = paper.url
        categories = paper.categories
        primaryCategory = paper.primaryCategory
        submittedDate = paper.submittedDate
        updatedDate = paper.date
        isUpdate = paper.isUpdate
        isCrosslist = paper.isCrosslist
        comment = paper.comment
        journalRef = paper.journalRef
        doi = paper.doi
        storedID = paper.persistentModelID
        saved = paper.saved
    }

    init(parsed: ParsedPaper) {
        let url = parsed.url ?? URL(string: "https://arxiv.org")!
        dedupKey = arxivDedupKey(for: url)
        title = parsed.title
        authors = parsed.authors
        abstract = parsed.abstract
        self.url = url
        categories = Array(parsed.categories)
        primaryCategory = parsed.primaryCategory ?? "unknown"
        submittedDate = parsed.submittedDate
        updatedDate = parsed.updatedDate
        isUpdate = parsed.submittedDate != parsed.updatedDate
        isCrosslist = false
        comment = parsed.comment
        journalRef = parsed.journalRef
        doi = parsed.doi
        storedID = nil
        saved = false
    }
}
