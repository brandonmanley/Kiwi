import Foundation
import SwiftData

// MARK: - ParsedPaper (value type — no SwiftData dependency)

struct ParsedPaper: Sendable {
    var title: String = ""
    var authors: [String] = []
    var abstract: String = ""
    var url: URL?
    var submittedDate: Date?
    var updatedDate: Date?
    var categories: Set<String> = []
    var primaryCategory: String?
}

// MARK: - PaperBuilder (mutable reference type used during XML parsing)

private final class PaperBuilder {
    var title: String = ""
    var authors: [String] = []
    var authorBuffer: String = ""
    var abstract: String = ""
    var url: URL?
    var submittedDate: Date?
    var updatedDate: Date?
    var categories: Set<String> = []
    var primaryCategory: String?
}

// MARK: - ArxivPageParser (self-contained per HTTP response — no shared state)

private final class ArxivPageParser: NSObject, XMLParserDelegate {

    private var currentElement = ""
    private var currentBuilder: PaperBuilder?
    private var builders: [URL: PaperBuilder] = [:]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parse(_ data: Data) -> [URL: ParsedPaper] {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.parse()

        var result: [URL: ParsedPaper] = [:]
        for (url, b) in builders {
            result[url] = ParsedPaper(
                title: b.title.trimmingCharacters(in: .whitespacesAndNewlines),
                authors: b.authors,
                abstract: b.abstract.trimmingCharacters(in: .whitespacesAndNewlines),
                url: url,
                submittedDate: b.submittedDate,
                updatedDate: b.updatedDate,
                categories: b.categories,
                primaryCategory: b.primaryCategory
            )
        }
        return result
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {

        currentElement = elementName

        if elementName == "entry" {
            currentBuilder = PaperBuilder()
            return
        }

        if elementName == "category", let term = attributeDict["term"] {
            currentBuilder?.categories.insert(term)
            return
        }

        if (elementName == "arxiv:primary_category" || elementName == "primary_category"),
           let term = attributeDict["term"] {
            currentBuilder?.primaryCategory = term
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let builder = currentBuilder else { return }

        switch currentElement {
        case "title":
            builder.title += string
        case "summary":
            builder.abstract += string
        case "name":
            builder.authorBuffer += string
        case "id":
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { builder.url = URL(string: trimmed) }
        case "published":
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { builder.submittedDate = Self.isoFormatter.date(from: trimmed) }
        case "updated":
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { builder.updatedDate = Self.isoFormatter.date(from: trimmed) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {

        guard let builder = currentBuilder else { return }

        if elementName == "name" {
            let name = Self.normalizeXMLText(builder.authorBuffer)
            if !name.isEmpty { builder.authors.append(name) }
            builder.authorBuffer = ""
            return
        }

        if elementName == "entry" {
            defer { currentBuilder = nil }
            guard let url = builder.url else { return }

            if let existing = builders[url] {
                existing.categories.formUnion(builder.categories)
                if existing.primaryCategory == nil || existing.primaryCategory?.isEmpty == true {
                    existing.primaryCategory = builder.primaryCategory
                }
                if let u = builder.updatedDate, let eu = existing.updatedDate {
                    existing.updatedDate = max(u, eu)
                } else if existing.updatedDate == nil {
                    existing.updatedDate = builder.updatedDate
                }
                if let s = builder.submittedDate, let es = existing.submittedDate {
                    existing.submittedDate = max(s, es)
                } else if existing.submittedDate == nil {
                    existing.submittedDate = builder.submittedDate
                }
            } else {
                builders[url] = builder
            }
        }
    }

    private static func normalizeXMLText(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ArxivFetcher (concurrent fetching, runs off main actor)

private enum ArxivFetcher {

    static func fetchAll(
        categories: [String],
        maxPerCategory: Int = 500,
        lookbackDays: Int = 10
    ) async -> [URL: ParsedPaper] {
        let maxConcurrent = 4
        var merged: [URL: ParsedPaper] = [:]

        for batchStart in stride(from: 0, to: categories.count, by: maxConcurrent) {
            let batchEnd = min(batchStart + maxConcurrent, categories.count)
            let batch = Array(categories[batchStart..<batchEnd])

            await withTaskGroup(of: [URL: ParsedPaper].self) { group in
                for category in batch {
                    group.addTask {
                        await fetchCategory(category, maxResults: maxPerCategory, lookbackDays: lookbackDays)
                    }
                }
                for await result in group {
                    mergePapers(result, into: &merged)
                }
            }
        }

        return merged
    }

    private static func fetchCategory(
        _ category: String,
        maxResults: Int,
        lookbackDays: Int
    ) async -> [URL: ParsedPaper] {
        let batchSize = 100
        var start = 0
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()
        var accumulated: [URL: ParsedPaper] = [:]

        while start < maxResults {
            guard !Task.isCancelled else { break }

            let batchLimit = min(batchSize, maxResults - start)
            let query = "https://export.arxiv.org/api/query?search_query=cat:\(category)&start=\(start)&max_results=\(batchLimit)&sortBy=submittedDate&sortOrder=descending"
            guard let url = URL(string: query) else { break }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let urlsBefore = Set(accumulated.keys)

                let pagePapers = ArxivPageParser().parse(data)
                mergePapers(pagePapers, into: &accumulated)

                let newDates = accumulated
                    .filter { !urlsBefore.contains($0.key) }
                    .values
                    .compactMap(\.updatedDate)

                if newDates.isEmpty { break }
                if let oldest = newDates.min(), oldest < cutoff { break }
            } catch {
                #if DEBUG
                print("⚠️ Failed to fetch \(category) batch at start=\(start): \(error)")
                #endif
                break
            }

            start += batchSize
        }

        return accumulated
    }

    static func fetchByAuthor(name: String, maxResults: Int = 10) async -> [URL: ParsedPaper] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: "au:\"\(trimmed)\""),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: "\(maxResults)"),
            URLQueryItem(name: "sortBy", value: "submittedDate"),
            URLQueryItem(name: "sortOrder", value: "descending"),
        ]

        guard let url = components.url else { return [:] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return ArxivPageParser().parse(data)
        } catch {
            #if DEBUG
            print("⚠️ Failed to fetch papers for author \(name): \(error)")
            #endif
            return [:]
        }
    }

    private static func mergePapers(_ source: [URL: ParsedPaper], into target: inout [URL: ParsedPaper]) {
        for (url, paper) in source {
            if var existing = target[url] {
                existing.categories.formUnion(paper.categories)
                if existing.primaryCategory == nil || existing.primaryCategory?.isEmpty == true {
                    existing.primaryCategory = paper.primaryCategory
                }
                if let u = paper.updatedDate, let eu = existing.updatedDate {
                    existing.updatedDate = max(u, eu)
                } else if existing.updatedDate == nil {
                    existing.updatedDate = paper.updatedDate
                }
                if let s = paper.submittedDate, let es = existing.submittedDate {
                    existing.submittedDate = max(s, es)
                } else if existing.submittedDate == nil {
                    existing.submittedDate = paper.submittedDate
                }
                target[url] = existing
            } else {
                target[url] = paper
            }
        }
    }
}

// MARK: - NetworkManager

@MainActor
final class NetworkManager {

    private let modelContext: ModelContext
    private static var currentSyncGeneration: Int = 0

    init(context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Public API

    func fetchPapersByAuthor(name: String, maxResults: Int = 10) async -> [Paper] {
        let fetched = await ArxivFetcher.fetchByAuthor(name: name, maxResults: maxResults)

        var result: [Paper] = []

        do {
            let stored = try modelContext.fetch(FetchDescriptor<Paper>())
            let storedByURL = Dictionary(uniqueKeysWithValues: stored.map { ($0.url, $0) })

            for parsed in fetched.values {
                guard let url = parsed.url else { continue }

                if let existing = storedByURL[url] {
                    result.append(existing)
                } else {
                    let paper = Paper(
                        title: parsed.title,
                        authors: parsed.authors,
                        abstract: parsed.abstract,
                        url: url,
                        categories: Array(parsed.categories),
                        primaryCategory: parsed.primaryCategory ?? "unknown",
                        date: Self.announcementDate(from: parsed.updatedDate ?? parsed.submittedDate ?? Date()),
                        isUpdate: parsed.submittedDate != parsed.updatedDate,
                        isCrosslist: false
                    )
                    modelContext.insert(paper)
                    result.append(paper)
                }
            }

            try modelContext.save()
        } catch {
            #if DEBUG
            print("⚠️ Failed to store author papers: \(error)")
            #endif
        }

        return result.sorted { $0.date > $1.date }
    }

    func syncPapers(
        for categories: [String],
        trackedCategories: [String]? = nil,
        maxResultsPerCategory: Int = 500,
        lookbackDays: Int = 10
    ) async {
        Self.currentSyncGeneration += 1
        let myGeneration = Self.currentSyncGeneration

        let tracked = Set((trackedCategories ?? categories).map { $0.lowercased() })

        do {
            try prunePapersNotMatchingSelectedCategories(
                selectedCategories: Set(categories.map { $0.lowercased() }),
                keepSaved: true
            )
        } catch {
            #if DEBUG
            print("⚠️ Failed to prune papers: \(error)")
            #endif
        }

        let fetched = await ArxivFetcher.fetchAll(
            categories: categories,
            maxPerCategory: maxResultsPerCategory,
            lookbackDays: lookbackDays
        )

        guard Self.currentSyncGeneration == myGeneration else { return }

        synchronizeWithStorage(fetched, trackedCategories: tracked, lookbackDays: lookbackDays)
    }

    // MARK: - Pruning

    private func prunePapersNotMatchingSelectedCategories(
        selectedCategories: Set<String>,
        keepSaved: Bool = true
    ) throws {
        let stored: [Paper] = try modelContext.fetch(FetchDescriptor<Paper>())

        for paper in stored {
            if keepSaved && paper.saved { continue }

            let paperCats = Set(
                ([paper.primaryCategory] + paper.categories)
                    .map { $0.lowercased() }
            )

            if paperCats.isDisjoint(with: selectedCategories) {
                modelContext.delete(paper)
            }
        }

        try modelContext.save()
    }

    // MARK: - Storage sync

    private func synchronizeWithStorage(
        _ fetchedPapers: [URL: ParsedPaper],
        trackedCategories: Set<String>,
        lookbackDays: Int
    ) {
        do {
            let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()

            var stored: [Paper] = try modelContext.fetch(FetchDescriptor<Paper>())
            let storedByURL = Dictionary(uniqueKeysWithValues: stored.map { ($0.url, $0) })

            for parsed in fetchedPapers.values {
                guard let url = parsed.url, let updatedDate = parsed.updatedDate else { continue }

                if updatedDate < cutoff, storedByURL[url]?.saved != true {
                    continue
                }

                if let existing = storedByURL[url] {
                    existing.categories = Array(Set(existing.categories + Array(parsed.categories)))

                    if (existing.primaryCategory.isEmpty || existing.primaryCategory.lowercased() == "unknown"),
                       let bp = parsed.primaryCategory, !bp.isEmpty {
                        existing.primaryCategory = bp
                    }

                    let primary = (parsed.primaryCategory ?? existing.primaryCategory).lowercased()
                    if !primary.isEmpty && primary != "unknown" {
                        existing.isCrosslist = !trackedCategories.contains(primary)
                    }

                    if updatedDate > existing.date {
                        existing.date = Self.announcementDate(from: updatedDate)
                    }
                } else {
                    let primary = (parsed.primaryCategory ?? "").lowercased()
                    let isCrosslist = !primary.isEmpty && !trackedCategories.contains(primary)

                    let paper = Paper(
                        title: parsed.title,
                        authors: parsed.authors,
                        abstract: parsed.abstract,
                        url: url,
                        categories: Array(parsed.categories),
                        primaryCategory: parsed.primaryCategory ?? "unknown",
                        date: Self.announcementDate(from: updatedDate),
                        isUpdate: parsed.submittedDate != parsed.updatedDate,
                        isCrosslist: isCrosslist
                    )

                    modelContext.insert(paper)
                    stored.append(paper)
                }
            }

            for paper in stored where !paper.saved && paper.date < cutoff {
                modelContext.delete(paper)
            }

            try modelContext.save()

            #if DEBUG
            print("✅ Synced papers. Total stored: \(stored.count)")
            #endif

        } catch {
            #if DEBUG
            print("⚠️ SwiftData sync failed: \(error)")
            #endif
        }
    }

    // MARK: - Announcement date (nonisolated for testability)

    nonisolated static func announcementDate(from submissionDate: Date) -> Date {
        let etZone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = etZone

        let comps = calendar.dateComponents(in: etZone, from: submissionDate)
        guard let etDate = calendar.date(from: comps) else { return submissionDate }

        let hour = comps.hour ?? 0
        let weekday = calendar.component(.weekday, from: etDate)

        var announceDate: Date?

        switch weekday {
        case 2...4: // Mon-Wed
            announceDate = hour < 14
                ? calendar.date(bySettingHour: 20, minute: 0, second: 0, of: etDate)
                : calendar.date(byAdding: .day, value: 1, to: calendar.date(bySettingHour: 20, minute: 0, second: 0, of: etDate)!)
        case 5: // Thu
            announceDate = hour < 14
                ? calendar.date(bySettingHour: 20, minute: 0, second: 0, of: etDate)
                : calendar.nextDate(after: etDate, matching: DateComponents(weekday: 1), matchingPolicy: .nextTime).flatMap {
                    calendar.date(bySettingHour: 20, minute: 0, second: 0, of: $0)
                }
        case 6, 7: // Fri/Sat -> next Monday
            announceDate = calendar.nextDate(after: etDate, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime).flatMap {
                calendar.date(bySettingHour: 20, minute: 0, second: 0, of: $0)
            }
        case 1: // Sunday
            announceDate = hour < 14
                ? calendar.date(bySettingHour: 20, minute: 0, second: 0, of: etDate)
                : calendar.nextDate(after: etDate, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime).flatMap {
                    calendar.date(bySettingHour: 20, minute: 0, second: 0, of: $0)
                }
        default:
            announceDate = etDate
        }

        if let a = announceDate,
           let shifted = calendar.date(byAdding: .day, value: 1, to: a) {
            announceDate = shifted
        }

        return announceDate ?? submissionDate
    }
}
