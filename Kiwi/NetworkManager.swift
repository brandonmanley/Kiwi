import Foundation
import SwiftData

// MARK: - arXiv dedup key

// arXiv's <id> resolves to a versioned abs URL (…/abs/2501.12345v2). When a
// paper updates from v1 to v2 the URL changes, so deduping on the raw URL would
// store the same paper twice. We key dedup on the version-stripped URL while
// keeping the versioned URL itself for linking.
func arxivDedupKey(for url: URL) -> String {
    var s = url.absoluteString
    if let range = s.range(of: #"v\d+$"#, options: .regularExpression) {
        s.removeSubrange(range)
    }
    return s
}

// MARK: - Rate limiter

// arXiv's API guidelines ask for roughly one request every few seconds and
// discourage bursts. This actor serializes request *starts* so concurrent
// category fetches don't fire a batch at once.
private actor ArxivRateLimiter {
    static let shared = ArxivRateLimiter()

    private let minInterval: TimeInterval = 1.0
    private var nextEarliestStart: Date = .distantPast

    func waitForSlot() async {
        let now = Date()
        let start = max(now, nextEarliestStart)
        nextEarliestStart = start.addingTimeInterval(minInterval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

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

// Internal (not private) so unit tests can feed it saved arXiv Atom fixtures —
// the parsing/merging logic here is the most fragile surface in the app.
final class ArxivPageParser: NSObject, XMLParserDelegate {

    private var currentElement = ""
    private var currentBuilder: PaperBuilder?
    // Keyed by version-stripped dedup key so v1/v2 of the same paper collapse.
    private var builders: [String: PaperBuilder] = [:]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parse(_ data: Data) -> [String: ParsedPaper] {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.parse()

        var result: [String: ParsedPaper] = [:]
        for (key, b) in builders {
            guard let url = b.url else { continue }
            result[key] = ParsedPaper(
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
            let key = arxivDedupKey(for: url)

            if let existing = builders[key] {
                // Keep the newest versioned URL for linking.
                if let u = builder.updatedDate, let eu = existing.updatedDate, u > eu {
                    existing.url = builder.url
                }
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
                builders[key] = builder
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

    struct FetchResult {
        var papers: [String: ParsedPaper]
        // True if at least one category produced a successful HTTP response.
        // Lets callers distinguish "arXiv had nothing new" from "network completely failed".
        var anySucceeded: Bool
    }

    // Shared session carrying the descriptive User-Agent arXiv's API guidelines ask for.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Kiwi/1.0 (mailto:brandonmanley10@gmail.com)"
        ]
        return URLSession(configuration: config)
    }()

    private struct HTTPStatusError: Error {
        let statusCode: Int
        let retryAfter: TimeInterval?
    }

    // Performs a request through the shared rate limiter and turns non-2xx
    // responses into thrown errors, so a 429/503 with an HTML error body can't
    // masquerade as a successful (but empty) parse. Retries once on a
    // throttling status that carries a Retry-After header.
    private static func fetchData(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            await ArxivRateLimiter.shared.waitForSlot()
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else { return data }
            if (200...299).contains(http.statusCode) { return data }

            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let isThrottled = (http.statusCode == 429 || http.statusCode == 503)
            if isThrottled, let retryAfter, attempt == 0 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 30) * 1_000_000_000))
                continue
            }
            throw HTTPStatusError(statusCode: http.statusCode, retryAfter: retryAfter)
        }
    }

    static func fetchAll(
        categories: [String],
        maxPerCategory: Int = 500,
        lookbackDays: Int = 10
    ) async -> FetchResult {
        let maxConcurrent = 4
        var merged: [String: ParsedPaper] = [:]
        var anySucceeded = false

        for batchStart in stride(from: 0, to: categories.count, by: maxConcurrent) {
            let batchEnd = min(batchStart + maxConcurrent, categories.count)
            let batch = Array(categories[batchStart..<batchEnd])

            await withTaskGroup(of: (papers: [String: ParsedPaper], succeeded: Bool).self) { group in
                for category in batch {
                    group.addTask {
                        await fetchCategory(category, maxResults: maxPerCategory, lookbackDays: lookbackDays)
                    }
                }
                for await result in group {
                    mergePapers(result.papers, into: &merged)
                    if result.succeeded { anySucceeded = true }
                }
            }
        }

        return FetchResult(papers: merged, anySucceeded: anySucceeded)
    }

    private static func fetchCategory(
        _ category: String,
        maxResults: Int,
        lookbackDays: Int
    ) async -> (papers: [String: ParsedPaper], succeeded: Bool) {
        let batchSize = 100
        var start = 0
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()
        var accumulated: [String: ParsedPaper] = [:]
        var succeeded = false

        while start < maxResults {
            guard !Task.isCancelled else { break }

            let batchLimit = min(batchSize, maxResults - start)
            let query = "https://export.arxiv.org/api/query?search_query=cat:\(category)&start=\(start)&max_results=\(batchLimit)&sortBy=submittedDate&sortOrder=descending"
            guard let url = URL(string: query) else { break }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            request.timeoutInterval = 20

            do {
                let data = try await fetchData(request)
                succeeded = true
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

        return (accumulated, succeeded)
    }

    // Queries by *last name only* on purpose. arXiv stores authors as
    // "Lastname, Firstname", so a quoted full-name search misses common
    // first-name variants ("Ed Witten" vs "Edward Witten"). We cast a wide
    // net here and let the caller filter on the client side.
    static func fetchByAuthor(lastName: String, maxResults: Int = 100) async -> [String: ParsedPaper] {
        let trimmed = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: "au:\(trimmed)"),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: "\(maxResults)"),
            URLQueryItem(name: "sortBy", value: "submittedDate"),
            URLQueryItem(name: "sortOrder", value: "descending"),
        ]

        guard let url = components.url else { return [:] }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        // Bounded timeout so the UI can't hang for the URLSession default (60s).
        request.timeoutInterval = 15

        do {
            let data = try await fetchData(request)
            return ArxivPageParser().parse(data)
        } catch {
            #if DEBUG
            print("⚠️ Failed to fetch papers for last name \(trimmed): \(error)")
            #endif
            return [:]
        }
    }

    private static func mergePapers(_ source: [String: ParsedPaper], into target: inout [String: ParsedPaper]) {
        for (key, paper) in source {
            if var existing = target[key] {
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
                target[key] = existing
            } else {
                target[key] = paper
            }
        }
    }
}

// MARK: - NetworkManager

@MainActor
final class NetworkManager {

    private let modelContext: ModelContext

    init(context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Public API

    func fetchPapersByAuthor(name: String, maxResults: Int = 100) async -> [Paper] {
        guard let target = AuthorName.parse(name) else { return [] }

        let fetched = await ArxivFetcher.fetchByAuthor(lastName: target.lastName, maxResults: maxResults)

        // Filter by AuthorName matching so "Ed Witten" and "Edward Witten" map
        // to the same set of papers.
        let matching = fetched.values.filter { parsed in
            parsed.authors.contains { authorString in
                guard let parsedAuthor = AuthorName.parse(authorString) else { return false }
                return target.matches(parsedAuthor)
            }
        }

        var result: [Paper] = []

        do {
            let stored = try modelContext.fetch(FetchDescriptor<Paper>())
            let storedByKey = Dictionary(stored.map { (arxivDedupKey(for: $0.url), $0) },
                                         uniquingKeysWith: { first, _ in first })

            for parsed in matching {
                guard let url = parsed.url else { continue }

                if let existing = storedByKey[arxivDedupKey(for: url)] {
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

    struct SyncResult {
        let added: Int
        let failed: Bool
    }

    @discardableResult
    func syncPapers(
        for categories: [String],
        trackedCategories: [String]? = nil,
        maxResultsPerCategory: Int = 500,
        lookbackDays: Int = 30
    ) async -> SyncResult {
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

        // If no category produced a successful HTTP response, treat as failed
        // so callers don't silently report "Up to date" after a network outage.
        guard fetched.anySucceeded else {
            return SyncResult(added: 0, failed: true)
        }

        let added = synchronizeWithStorage(fetched.papers, trackedCategories: tracked, lookbackDays: lookbackDays)
        return SyncResult(added: added, failed: false)
    }

    // MARK: - Next announcement time (Mon-Fri 20:00 ET)

    nonisolated static func nextAnnouncement(after date: Date = Date()) -> Date {
        let etZone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = etZone

        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        let isBusinessDay = (2...6).contains(weekday)

        if isBusinessDay && hour < 20,
           let today8pm = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: date) {
            return today8pm
        }

        var next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        while !(2...6).contains(calendar.component(.weekday, from: next)) {
            next = calendar.date(byAdding: .day, value: 1, to: next)!
        }
        return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: next) ?? next
    }

    nonisolated static func friendlyNextAnnouncement(from date: Date = Date()) -> String {
        let next = nextAnnouncement(after: date)
        let etZone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = etZone

        let nowDay = calendar.startOfDay(for: date)
        let nextDay = calendar.startOfDay(for: next)
        let dayDiff = calendar.dateComponents([.day], from: nowDay, to: nextDay).day ?? 0

        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = etZone
        timeFormatter.dateFormat = "h a"
        let timeString = timeFormatter.string(from: next)

        switch dayDiff {
        case 0: return "next batch \(timeString) ET"
        case 1: return "next batch tomorrow \(timeString) ET"
        default:
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.timeZone = etZone
            weekdayFormatter.dateFormat = "EEEE"
            return "next batch \(weekdayFormatter.string(from: next)) \(timeString) ET"
        }
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

    @discardableResult
    private func synchronizeWithStorage(
        _ fetchedPapers: [String: ParsedPaper],
        trackedCategories: Set<String>,
        lookbackDays: Int
    ) -> Int {
        var insertedCount = 0

        do {
            let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()

            var stored: [Paper] = try modelContext.fetch(FetchDescriptor<Paper>())
            let storedByKey = Dictionary(stored.map { (arxivDedupKey(for: $0.url), $0) },
                                         uniquingKeysWith: { first, _ in first })

            for parsed in fetchedPapers.values {
                guard let url = parsed.url, let updatedDate = parsed.updatedDate else { continue }
                let key = arxivDedupKey(for: url)

                if updatedDate < cutoff, storedByKey[key]?.saved != true {
                    continue
                }

                if let existing = storedByKey[key] {
                    // A new version (…v2) keeps the same dedup key; point the
                    // stored row at the newest URL and flag it as an update.
                    if existing.url != url {
                        existing.url = url
                        existing.isUpdate = true
                    }
                    existing.categories = Array(Set(existing.categories + Array(parsed.categories)))

                    if (existing.primaryCategory.isEmpty || existing.primaryCategory.lowercased() == "unknown"),
                       let bp = parsed.primaryCategory, !bp.isEmpty {
                        existing.primaryCategory = bp
                    }

                    let primary = (parsed.primaryCategory ?? existing.primaryCategory).lowercased()
                    if !primary.isEmpty && primary != "unknown" {
                        existing.isCrosslist = !trackedCategories.contains(primary)
                    }

                    // Recompute unconditionally: announcementDate is a pure function
                    // of updatedDate, so this is idempotent — and it re-buckets rows
                    // stored under the old ET-midnight convention onto the correct
                    // local day after a timezone-related fix or move.
                    existing.date = Self.announcementDate(from: updatedDate)
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
                    insertedCount += 1
                }
            }

            for paper in stored where !paper.saved && paper.date < cutoff {
                modelContext.delete(paper)
            }

            try modelContext.save()

            #if DEBUG
            print("✅ Synced papers. Inserted: \(insertedCount). Total stored: \(stored.count)")
            #endif

        } catch {
            #if DEBUG
            print("⚠️ SwiftData sync failed: \(error)")
            #endif
        }

        return insertedCount
    }

    // MARK: - Announcement date (nonisolated for testability)

    nonisolated static func announcementDate(from submissionDate: Date) -> Date {
        let etZone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = etZone

        let comps = calendar.dateComponents(in: etZone, from: submissionDate)
        guard let etDate = calendar.date(from: comps) else { return submissionDate }

        let hour = comps.hour ?? 0
        let weekday = calendar.component(.weekday, from: etDate) // 1=Sun … 7=Sat
        let isBusinessDay = (2...6).contains(weekday)

        // Step 1: announcement day (papers appear at 20:00 ET that evening)
        let announceDay: Date
        if isBusinessDay && hour < 14 {
            announceDay = etDate
        } else {
            announceDay = Self.nextBusinessDay(after: etDate, calendar: calendar)
        }

        // Step 2: listing date = next business day after announcement
        let listingDate = Self.nextBusinessDay(after: announceDay, calendar: calendar)

        // The listing *day* is defined by arXiv in ET, but views bucket papers
        // by the user's local calendar (HomeView's "today" query, DailyPapersView's
        // grouping). Materialize the ET year/month/day as local midnight so the
        // paper lands under the correct day in any timezone — midnight ET would
        // read as the previous day west of ET.
        let dayComps = calendar.dateComponents([.year, .month, .day], from: listingDate)
        return Calendar.current.date(from: dayComps) ?? calendar.startOfDay(for: listingDate)
    }

    private nonisolated static func nextBusinessDay(after date: Date, calendar: Calendar) -> Date {
        var next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        while !(2...6).contains(calendar.component(.weekday, from: next)) {
            next = calendar.date(byAdding: .day, value: 1, to: next)!
        }
        return next
    }
}
