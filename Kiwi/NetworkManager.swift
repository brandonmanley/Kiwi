import Foundation
import SwiftData

@MainActor
final class NetworkManager: NSObject, XMLParserDelegate {

    // MARK: - Dependencies
    private let modelContext: ModelContext

    // MARK: - Policy knobs
    private var lookbackDays: Int = 10
    private var trackedCategories: Set<String> = []

    // MARK: - XML parsing state
    private var currentElement: String = ""
    private var currentBuilder: PaperBuilder?
    private var fetchedPapers: [URL: PaperBuilder] = [:]

    // MARK: - Init
    init(context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Public API
    /// Fetch papers for `categories` and synchronize with storage.
    ///
    /// - Parameters:
    ///   - categories: Categories to query from arXiv.
    ///   - trackedCategories: Categories considered "in-scope" for crosslist marking.
    ///                       If nil, defaults to `categories`.
    ///   - maxResultsPerCategory: Max results pulled per category.
    ///   - lookbackDays: Papers older than this are ignored unless already saved.
    func syncPapers(
        for categories: [String],
        trackedCategories: [String]? = nil,
        maxResultsPerCategory: Int = 500,
        lookbackDays: Int = 10
    ) async {
        self.lookbackDays = lookbackDays
        self.trackedCategories = Set((trackedCategories ?? categories).map { $0.lowercased() })
        
        do {
            try prunePapersNotMatchingSelectedCategories(
                selectedCategories: Set(categories.map { $0.lowercased() }),
                keepSaved: true   // set false if you want saved papers to be removed too
            )
        } catch {
            #if DEBUG
            print("⚠️ Failed to prune papers: \(error)")
            #endif
        }

        fetchedPapers.removeAll()

        for category in categories {
            await fetchCategory(category, maxResultsPerCategory: maxResultsPerCategory)
        }

        await synchronizeWithStorage()
    }

    // MARK: - Fetching
    private func fetchCategory(_ category: String, maxResultsPerCategory: Int) async {
        let batchSize = 100
        var start = 0
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()

        while start < maxResultsPerCategory {
            let batchLimit = min(batchSize, maxResultsPerCategory - start)

            let query = """
            https://export.arxiv.org/api/query?search_query=cat:\(category)&start=\(start)&max_results=\(batchLimit)&sortBy=submittedDate&sortOrder=descending
            """
            guard let url = URL(string: query) else { break }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)

                let urlsBefore = Set(fetchedPapers.keys)

                let parser = XMLParser(data: data)
                parser.delegate = self
                parser.parse()

                // Stop early once *this batch* has any paper older than the lookback window.
                // arXiv returns results sorted by date descending, so an old paper means
                // remaining batches will be older still.
                let batchDates = fetchedPapers
                    .filter { !urlsBefore.contains($0.key) }
                    .values
                    .compactMap { $0.updatedDate }

                if batchDates.isEmpty { break } // empty page → end of results
                if let oldest = batchDates.min(), oldest < cutoff { break }

            } catch {
                #if DEBUG
                print("⚠️ Failed to fetch \(category) batch at start=\(start): \(error)")
                #endif
                break
            }

            start += batchSize
        }
    }

    // MARK: - XMLParserDelegate
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

        // arXiv sometimes uses "arxiv:primary_category"
        if (elementName == "arxiv:primary_category" || elementName == "primary_category"),
           let term = attributeDict["term"] {
            currentBuilder?.primaryCategory = term
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let builder = currentBuilder else { return }

        // Don't trim here; just append what the parser gives.
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
    
    private func normalizeXMLText(_ s: String) -> String {
        // Collapse any whitespace runs into a single space and trim ends.
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {

        guard let builder = currentBuilder else { return }

        if elementName == "name" {
            let name = normalizeXMLText(builder.authorBuffer)
            if !name.isEmpty { builder.authors.append(name) }
            builder.authorBuffer = ""
            return
        }

        if elementName == "entry" {
            defer { currentBuilder = nil }

            guard let url = builder.url else { return }

            // Normalize accumulated strings
            builder.title = builder.title.trimmingCharacters(in: .whitespacesAndNewlines)
            builder.abstract = builder.abstract.trimmingCharacters(in: .whitespacesAndNewlines)

            // Merge if already present (same URL across categories)
            if let existing = fetchedPapers[url] {
                existing.categories.formUnion(builder.categories)
                // Prefer non-empty primary category if one side is missing
                if existing.primaryCategory == nil || existing.primaryCategory?.isEmpty == true {
                    existing.primaryCategory = builder.primaryCategory
                }
                // Keep the newest updated/submitted dates if duplicate appears
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
                fetchedPapers[url] = builder
            }
        }
    }
    
    // Delete stored papers that are no longer in any selected category.
    // Keeps saved/pinned if you want (toggle via keepSaved).
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

            // If none of the paper's categories intersect the selected set -> delete.
            if paperCats.isDisjoint(with: selectedCategories) {
                modelContext.delete(paper)
            }
        }

        try modelContext.save()
    }
    
    

    // MARK: - Storage sync
    private func synchronizeWithStorage() async {
        do {
            let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()

            // Fetch all stored papers
            var stored: [Paper] = try modelContext.fetch(FetchDescriptor<Paper>())
            let storedByURL = Dictionary(uniqueKeysWithValues: stored.map { ($0.url, $0) })

            // Insert or update fetched papers
            for builder in fetchedPapers.values {
                guard let url = builder.url, let updatedDate = builder.updatedDate else { continue }

                // Skip old papers unless already stored & saved
                if updatedDate < cutoff, storedByURL[url]?.saved != true {
                    continue
                }

                if let existing = storedByURL[url] {
                    // Merge categories
                    existing.categories = Array(Set(existing.categories + Array(builder.categories)))
                    
                    // Prefer builder primary if existing is missing/unknown
                    if (existing.primaryCategory.isEmpty || existing.primaryCategory.lowercased() == "unknown"),
                       let bp = builder.primaryCategory, !bp.isEmpty {
                        existing.primaryCategory = bp
                    }

                    // Recompute crosslist using *current* trackedCategories
                    let primary = (builder.primaryCategory ?? existing.primaryCategory).lowercased()
                    if !primary.isEmpty && primary != "unknown" {
                        existing.isCrosslist = !trackedCategories.contains(primary)
                    }

                    // Update announcement date if this is a newer version
                    if updatedDate > existing.date {
                        existing.date = announcementDate(from: updatedDate)
                    }
                } else {
                    let primary = (builder.primaryCategory ?? "").lowercased()
                    let isCrosslist = !primary.isEmpty && !trackedCategories.contains(primary)

                    #if DEBUG
                    if !primary.isEmpty {
                        print("ℹ️ crosslist=\(isCrosslist) primary=\(primary) tracked=\(trackedCategories.sorted())")
                    }
                    #endif

                    let paper = Paper(
                        title: builder.title,
                        authors: builder.authors,
                        abstract: builder.abstract,
                        url: url,
                        categories: Array(builder.categories),
                        primaryCategory: builder.primaryCategory ?? "unknown",
                        date: announcementDate(from: updatedDate),
                        isUpdate: builder.submittedDate != builder.updatedDate,
                        isCrosslist: isCrosslist
                    )

                    modelContext.insert(paper)
                    stored.append(paper)
                }
            }

            // Cleanup: delete only old, unsaved papers.
            // Avoid deleting papers that may be rendered by SwiftUI lists during a sync.
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

    // MARK: - Helper: announcement date
    private func announcementDate(from submissionDate: Date) -> Date {
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
        case 6, 7: // Fri/Sat -> Monday
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

    // MARK: - ISO formatter
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - PaperBuilder
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
