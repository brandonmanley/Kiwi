import Foundation
import SwiftData
import UserNotifications

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

// arXiv's Terms of Use for the legacy APIs ask for no more than one request
// every three seconds *and* a single connection at a time. This actor
// serializes request *starts* so nothing — including a retry storm — can push
// the app back over the three-second interval. (The single-connection clause is
// enforced separately via httpMaximumConnectionsPerHost on the shared session.)
actor ArxivRateLimiter {
    static let shared = ArxivRateLimiter()

    private let minInterval: TimeInterval
    private var nextEarliestStart: Date = .distantPast

    init(minInterval: TimeInterval = 3.0) {
        self.minInterval = minInterval
    }

    // Reserve the next start slot, honoring the minimum interval between starts.
    func waitForSlot() async {
        let now = Date()
        let start = max(now, nextEarliestStart)
        nextEarliestStart = start.addingTimeInterval(minInterval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    // Sleep for a retry backoff *through* the limiter's own clock: the backoff
    // reserves the interval too, so retries can't be used to burst past the
    // three-second policy. Used instead of a bare Task.sleep for all backoffs.
    func backoff(_ seconds: TimeInterval) async {
        let now = Date()
        let resume = max(now, nextEarliestStart).addingTimeInterval(seconds)
        nextEarliestStart = resume.addingTimeInterval(minInterval)
        let delay = resume.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

// MARK: - SyncFailure

// A real error taxonomy so the UI can tell the user what actually went wrong.
// The reported "check your connection" symptom came from collapsing every
// failure — including arXiv 429/503 throttling — into a single Bool.
enum SyncFailure: Error, Equatable, Sendable {
    case offline
    case throttled(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case timedOut
    case parseFailed
}

// MARK: - Announce type (RSS listing feeds)

// arXiv's RSS listing items carry an authoritative `Announce Type` — this is
// arXiv's own classification, not our derived `!tracked.contains(primary)`
// heuristic, so it doesn't reclassify already-saved papers when the user edits
// their category set. `replace-cross` is both a replacement and a cross-list.
enum ArxivAnnounceType: String, Sendable {
    case new
    case cross
    case replace
    case replaceCross = "replace-cross"

    var isUpdate: Bool { self == .replace || self == .replaceCross }
    var isCrosslist: Bool { self == .cross || self == .replaceCross }

    // Prefers the <arxiv:announce_type> element, falling back to the
    // "Announce Type: <type>" prefix arXiv also embeds in <description>.
    init?(element: String, description: String) {
        let candidate = element.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let t = ArxivAnnounceType(rawValue: candidate) { self = t; return }
        if let r = description.range(of: "Announce Type:") {
            let word = description[r.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix { !$0.isWhitespace }
                .lowercased()
            if let t = ArxivAnnounceType(rawValue: String(word)) { self = t; return }
        }
        return nil
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
    // Bibliographic extras (arxiv:comment / arxiv:journal_ref / arxiv:doi).
    var comment: String?
    var journalRef: String?
    var doi: String?

    // RSS-only. When set, arXiv has told us the listing day and the paper's
    // new/cross/replace classification directly, so storage sync uses these
    // instead of the announcementDate heuristic and the tracked-category
    // derivation. `listingDate` is already bucketed to local midnight of the
    // ET listing day. nil on the Atom path.
    var listingDate: Date?
    var rssIsUpdate: Bool?
    var rssIsCrosslist: Bool?
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
    var comment: String = ""
    var journalRef: String = ""
    var doi: String = ""
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
            func nonEmpty(_ s: String) -> String? {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            result[key] = ParsedPaper(
                title: b.title.trimmingCharacters(in: .whitespacesAndNewlines),
                authors: b.authors,
                abstract: b.abstract.trimmingCharacters(in: .whitespacesAndNewlines),
                url: url,
                submittedDate: b.submittedDate,
                updatedDate: b.updatedDate,
                categories: b.categories,
                primaryCategory: b.primaryCategory,
                comment: nonEmpty(b.comment),
                journalRef: nonEmpty(b.journalRef),
                doi: nonEmpty(b.doi)
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
        case "arxiv:comment", "comment":
            builder.comment += string
        case "arxiv:journal_ref", "journal_ref":
            builder.journalRef += string
        case "arxiv:doi", "doi":
            builder.doi += string
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
                if existing.comment.isEmpty { existing.comment = builder.comment }
                if existing.journalRef.isEmpty { existing.journalRef = builder.journalRef }
                if existing.doi.isEmpty { existing.doi = builder.doi }
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

// MARK: - ArxivRSSParser (rss.arxiv.org listing feeds — one announcement day)

// Parses a single category's RSS listing (https://rss.arxiv.org/rss/<category>).
// Unlike the Atom API this feed states the listing day (channel/item pubDate)
// and each paper's new/cross/replace classification directly, which is why it's
// the primary sync path. Identity converges with ArxivPageParser: the guid
// carries the versioned id, from which we rebuild `http://arxiv.org/abs/<id>`
// so arxivDedupKey lands on the same row as an Atom-fetched paper.
// Internal (not private) so unit tests can feed it saved fixtures.
final class ArxivRSSParser: NSObject, XMLParserDelegate {

    private final class ItemBuilder {
        var title = ""
        var link = ""
        var guid = ""
        var descriptionText = ""
        var creator = ""
        var announceType = ""
        var doi = ""
        var journalRef = ""
        var pubDate: Date?
        var categories: [String] = []

        // Prefer the versioned id from the guid ("oai:arXiv.org:2501.12345v2"),
        // falling back to the (version-stripped) link's last path component.
        // Always rebuilt as an http abs URL so the dedup key matches the Atom path.
        func resolvedURL() -> URL? {
            var id = ""
            if let last = guid.components(separatedBy: ":").last,
               !last.trimmingCharacters(in: .whitespaces).isEmpty {
                id = last.trimmingCharacters(in: .whitespaces)
            } else if let u = URL(string: link) {
                id = u.lastPathComponent
            }
            guard !id.isEmpty else { return nil }
            return URL(string: "http://arxiv.org/abs/\(id)")
        }
    }

    private var currentElement = ""
    private var buffer = ""
    private var inItem = false
    private var builder: ItemBuilder?
    private var items: [ItemBuilder] = []
    private var channelPubDate: Date?

    // arXiv RSS pubDates are RFC-822 with a fixed ET offset ("Fri, 23 Aug 2024
    // 00:00:00 -0400"). The Z in the string carries the offset; the formatter's
    // timeZone is irrelevant for parsing.
    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    private static let etZone = TimeZone(identifier: "America/New_York")!

    // The listing day is defined by arXiv in ET, but views bucket by the user's
    // local calendar — materialize the ET year/month/day as local midnight so the
    // paper lands under the correct day in any timezone (mirrors
    // NetworkManager.announcementDate's final step).
    private static func listingDay(from pubDate: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = etZone
        let comps = cal.dateComponents([.year, .month, .day], from: pubDate)
        return Calendar.current.date(from: comps) ?? Calendar.current.startOfDay(for: pubDate)
    }

    func parse(_ data: Data) -> [String: ParsedPaper] {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.parse()

        var result: [String: ParsedPaper] = [:]
        for b in items {
            guard let url = b.resolvedURL() else { continue }
            let key = arxivDedupKey(for: url)

            let type = ArxivAnnounceType(element: b.announceType, description: b.descriptionText)
            let listing = (b.pubDate ?? channelPubDate).map { Self.listingDay(from: $0) }

            var pp = ParsedPaper()
            pp.title = Self.collapse(b.title)
            pp.authors = Self.authors(from: b.creator)
            pp.abstract = Self.abstract(from: b.descriptionText)
            pp.url = url
            pp.categories = Set(b.categories)
            // The first <category> in an RSS item is the paper's primary class.
            pp.primaryCategory = b.categories.first
            pp.journalRef = b.journalRef.isEmpty ? nil : b.journalRef
            pp.doi = b.doi.isEmpty ? nil : b.doi
            pp.listingDate = listing
            pp.rssIsUpdate = type?.isUpdate
            pp.rssIsCrosslist = type?.isCrosslist

            result[key] = pp
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
        if elementName == "item" {
            builder = ItemBuilder()
            inItem = true
            return
        }
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {

        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "item" {
            if let b = builder { items.append(b) }
            builder = nil
            inItem = false
            return
        }

        guard inItem, let b = builder else {
            // Channel-level pubDate is the fallback listing day for items lacking one.
            if elementName == "pubDate", channelPubDate == nil {
                channelPubDate = Self.rfc822.date(from: text)
            }
            return
        }

        switch elementName {
        case "title":                    b.title = text
        case "link":                     b.link = text
        case "guid":                     b.guid = text
        case "description":              b.descriptionText = text
        case "dc:creator":               b.creator = text
        case "arxiv:announce_type":      b.announceType = text
        case "arxiv:DOI":                b.doi = text
        case "arxiv:journal_reference":  b.journalRef = text
        case "pubDate":                  b.pubDate = Self.rfc822.date(from: text)
        case "category":                 if !text.isEmpty { b.categories.append(text) }
        default:                         break
        }
    }

    // MARK: Field extraction

    // <description> is "arXiv:ID Announce Type: <type> \nAbstract: <text>".
    private static func abstract(from description: String) -> String {
        if let r = description.range(of: "Abstract:") {
            return String(description[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // <dc:creator> is a comma-joined list of full names ("Alice Smith, Bob Jones").
    private static func authors(from creator: String) -> [String] {
        creator
            .components(separatedBy: ",")
            .map { collapse($0) }
            .filter { !$0.isEmpty }
    }

    private static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ArxivFetcher (sequential fetching, runs off main actor)

// Internal (not private) so the fetch layer is unit-testable via a URLProtocol
// stub and an injectable rate limiter — see ArxivFetcherTests.
enum ArxivFetcher {

    // Per-category outcomes rather than a single anySucceeded Bool: nineteen of
    // twenty categories can fail while one succeeds, and the toast must be able
    // to say "Synced N of M" and to name the dominant failure honestly.
    struct FetchResult {
        var categoryResults: [String: Result<[String: ParsedPaper], SyncFailure>]

        // All successfully-parsed papers, merged across categories.
        var mergedPapers: [String: ParsedPaper] {
            var merged: [String: ParsedPaper] = [:]
            for case let .success(papers) in categoryResults.values {
                ArxivFetcher.mergePapers(papers, into: &merged)
            }
            return merged
        }

        var succeededCategories: Set<String> {
            Set(categoryResults.compactMap { key, value in
                if case .success = value { return key } else { return nil }
            })
        }

        // When every category failed, the single failure to surface. Throttling
        // dominates (it's the actionable "wait a moment"), then offline, then
        // the not-responding bucket.
        var dominantFailure: SyncFailure? {
            let failures = categoryResults.values.compactMap { value -> SyncFailure? in
                if case .failure(let f) = value { return f } else { return nil }
            }
            guard !failures.isEmpty else { return nil }
            if let t = failures.first(where: { if case .throttled = $0 { return true } else { return false } }) { return t }
            if failures.contains(.offline) { return .offline }
            if failures.contains(.timedOut) { return .timedOut }
            if let s = failures.first(where: { if case .serverError = $0 { return true } else { return false } }) { return s }
            return failures.first
        }
    }

    // Injectable so tests can point the fetch layer at a URLProtocol stub, and
    // so retries stay fast under test. Production keeps the three-second limiter
    // and a two-second backoff base.
    static var session: URLSession = makeSession()
    static var rateLimiter: ArxivRateLimiter = .shared
    static var retryBaseDelay: TimeInterval = 2.0

    // Shared session: descriptive User-Agent per arXiv's guidelines, a single
    // connection per host (the ToU's single-connection clause), and a modest
    // protocol cache — arXiv listings change once daily, so cached GETs are
    // both correct and far less likely to be throttled by Fastly.
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Kiwi/1.0 (mailto:\(contactAddress))"
        ]
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024,
                                   diskCapacity: 32 * 1024 * 1024)
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config)
    }

    // Contact address arXiv asks API clients to advertise. Pulled from the
    // bundle's "ArxivContactEmail" Info.plist key when present so it can be a
    // build setting, falling back to the maintainer address.
    private static let contactAddress: String =
        (Bundle.main.object(forInfoDictionaryKey: "ArxivContactEmail") as? String)
            ?? "brandonmanley10@gmail.com"

    // The set of statuses worth retrying: throttling and transient upstream
    // errors. A bare 404/400 is a client bug and fails immediately.
    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]

    // Performs a request through the rate limiter and maps every failure into
    // the SyncFailure taxonomy. Retries up to three attempts total with
    // exponential backoff and full jitter (base two seconds), preferring a
    // Retry-After header when present, capped at thirty seconds. All backoff
    // sleeps go through the limiter's clock so a retry can't burst past the
    // policy. notConnectedToInternet fails fast — that one is genuinely offline.
    static func fetchData(_ request: URLRequest, maxAttempts: Int = 3) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            await rateLimiter.waitForSlot()

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return data }
                if (200...299).contains(http.statusCode) { return data }

                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                let status = http.statusCode

                if retryableStatuses.contains(status), attempt < maxAttempts {
                    await backoff(attempt: attempt, retryAfter: retryAfter)
                    continue
                }
                if status == 429 || status == 503 {
                    throw SyncFailure.throttled(retryAfter: retryAfter)
                }
                throw SyncFailure.serverError(status: status)

            } catch let failure as SyncFailure {
                throw failure
            } catch let urlError as URLError {
                switch urlError.code {
                case .notConnectedToInternet, .dataNotAllowed:
                    // Fail fast: the device says it isn't online.
                    throw SyncFailure.offline
                case .networkConnectionLost:
                    if attempt < maxAttempts { await backoff(attempt: attempt, retryAfter: nil); continue }
                    throw SyncFailure.offline
                case .timedOut, .cannotConnectToHost:
                    if attempt < maxAttempts { await backoff(attempt: attempt, retryAfter: nil); continue }
                    throw SyncFailure.timedOut
                default:
                    throw SyncFailure.serverError(status: urlError.errorCode)
                }
            }
        }
    }

    private static func backoff(attempt: Int, retryAfter: TimeInterval?) async {
        let seconds: TimeInterval
        if let retryAfter {
            seconds = min(retryAfter, 30)
        } else {
            let ceiling = retryBaseDelay * pow(2.0, Double(attempt - 1))
            seconds = Double.random(in: 0...ceiling) // full jitter
        }
        await rateLimiter.backoff(seconds)
    }

    static func fetchAll(
        categories: [String],
        maxPerCategory: Int = 200,
        lookbackDays: Int = 10,
        onProgress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async -> FetchResult {
        var results: [String: Result<[String: ParsedPaper], SyncFailure>] = [:]
        let total = categories.count
        var done = 0

        // Sequential: the global limiter already serialized request *starts*, so
        // the old concurrent task group bought no throughput while breaking the
        // single-connection clause. One category at a time is simpler and, with
        // last-updated sorting and early termination, faster in practice.
        //
        // RSS is the primary path: one request returns the whole announcement day
        // with arXiv's own new/cross/replace classification. Only a *failed* feed
        // falls back to the Atom query (an empty feed is a real weekend/holiday,
        // not a failure), so one bad response can't blank the day.
        for category in categories {
            if Task.isCancelled { break }
            switch await fetchCategoryRSS(category) {
            case .success(let papers):
                results[category] = .success(papers)
            case .failure:
                results[category] = await fetchCategory(category, maxResults: maxPerCategory, lookbackDays: lookbackDays)
            }
            done += 1
            onProgress?(done, total)
        }

        return FetchResult(categoryResults: results)
    }

    // Fetches and parses one category's RSS listing feed. A network/HTTP failure
    // surfaces as .failure so the caller can fall back to the Atom query; an
    // empty-but-valid feed returns .success([:]).
    private static func fetchCategoryRSS(
        _ category: String
    ) async -> Result<[String: ParsedPaper], SyncFailure> {
        guard let url = URL(string: "https://rss.arxiv.org/rss/\(category)") else {
            return .failure(.parseFailed)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 20
        do {
            let data = try await fetchData(request)
            return .success(ArxivRSSParser().parse(data))
        } catch let failure as SyncFailure {
            return .failure(failure)
        } catch {
            return .failure(.serverError(status: -1))
        }
    }

    private static func fetchCategory(
        _ category: String,
        maxResults: Int,
        lookbackDays: Int
    ) async -> Result<[String: ParsedPaper], SyncFailure> {
        let batchSize = 100
        var start = 0
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()
        var accumulated: [String: ParsedPaper] = [:]
        var sawSuccess = false

        while start < maxResults {
            guard !Task.isCancelled else { break }

            let batchLimit = min(batchSize, maxResults - start)
            var components = URLComponents(string: "https://export.arxiv.org/api/query")!
            components.queryItems = [
                URLQueryItem(name: "search_query", value: "cat:\(category)"),
                URLQueryItem(name: "start", value: "\(start)"),
                URLQueryItem(name: "max_results", value: "\(batchLimit)"),
                // Sort by *last updated*, not original submission: a replacement
                // announced tonight then sits on page one instead of hundreds of
                // entries deep, which is exactly what the app wants.
                URLQueryItem(name: "sortBy", value: "lastUpdatedDate"),
                URLQueryItem(name: "sortOrder", value: "descending"),
            ]
            guard let url = components.url else { break }

            var request = URLRequest(url: url)
            request.cachePolicy = .useProtocolCachePolicy
            request.timeoutInterval = 20

            do {
                let data = try await fetchData(request)
                sawSuccess = true

                let pagePapers = ArxivPageParser().parse(data)
                if pagePapers.isEmpty { break }
                mergePapers(pagePapers, into: &accumulated)

                // With lastUpdatedDate ordering the page is genuinely sorted by
                // the quantity being compared, so the moment the *oldest* entry
                // on this page predates the cutoff we've seen everything in range
                // — normally after a single request.
                if let oldest = pagePapers.values.compactMap(\.updatedDate).min(), oldest < cutoff { break }
                // Fewer results than requested means the last page.
                if pagePapers.count < batchLimit { break }
            } catch let failure as SyncFailure {
                // Pages already fetched are still useful; only report failure if
                // the very first request failed.
                return sawSuccess ? .success(accumulated) : .failure(failure)
            } catch {
                return sawSuccess ? .success(accumulated) : .failure(.serverError(status: -1))
            }

            start += batchSize
        }

        return .success(accumulated)
    }

    // Two-stage author fetch. Stage one issues a quoted phrase query covering
    // both name orderings ("Brandon Manley" OR "Manley, Brandon"), which is
    // precise for common surnames where a bare `au:manley` never surfaces the
    // right person. Stage two only runs if stage one is thin: a surname query
    // (quoted when the surname has a space, which particled names now do), sorted
    // by last-updated and paged up to a cap. Throws rather than swallowing
    // errors so the view can tell "no papers" from "the request failed".
    static func fetchByAuthor(_ name: AuthorName, targetMatches: Int = 40) async throws -> [String: ParsedPaper] {
        var merged: [String: ParsedPaper] = [:]

        // Stage 1 — quoted phrase, both orderings.
        let phraseQuery = name.queryPhrases().map { "au:\"\($0)\"" }.joined(separator: " OR ")
        let stage1 = try await runAuthorQuery(searchQuery: phraseQuery, start: 0, sortBy: "submittedDate")
        mergePapers(stage1, into: &merged)

        func filteredCount() -> Int {
            merged.values.filter { paperMatches($0, name) }.count
        }

        // Stage 2 — surname fallback, only while under target.
        if filteredCount() < targetMatches {
            let surname = name.lastName
            let quoted = surname.contains(" ") ? "\"\(surname)\"" : surname
            var start = 0
            var page = 0
            while filteredCount() < targetMatches && page < 4 {
                let batch = try await runAuthorQuery(searchQuery: "au:\(quoted)", start: start, sortBy: "lastUpdatedDate")
                if batch.isEmpty { break }
                let before = merged.count
                mergePapers(batch, into: &merged)
                start += 100
                page += 1
                // No new keys means we've exhausted the useful pages.
                if merged.count == before { break }
            }
        }

        return merged
    }

    private static func paperMatches(_ parsed: ParsedPaper, _ target: AuthorName) -> Bool {
        parsed.authors.contains { AuthorName.parse($0).map { target.matches($0) } ?? false }
    }

    private static func runAuthorQuery(searchQuery: String, start: Int, sortBy: String) async throws -> [String: ParsedPaper] {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: searchQuery),
            URLQueryItem(name: "start", value: "\(start)"),
            URLQueryItem(name: "max_results", value: "100"),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortOrder", value: "descending"),
        ]
        guard let url = components.url else { throw SyncFailure.parseFailed }

        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 20
        let data = try await fetchData(request)
        return ArxivPageParser().parse(data)
    }

    // Combines two optional flags: applies `op` when both are present, otherwise
    // keeps whichever is non-nil.
    private static func combineOptionalBool(_ a: Bool?, _ b: Bool?, with op: (Bool, Bool) -> Bool) -> Bool? {
        switch (a, b) {
        case let (x?, y?): return op(x, y)
        default:           return a ?? b
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
                if existing.comment == nil { existing.comment = paper.comment }
                if existing.journalRef == nil { existing.journalRef = paper.journalRef }
                if existing.doi == nil { existing.doi = paper.doi }

                // RSS classification is per-feed: the same paper appears as "new"
                // in its primary feed and "cross" in a feed it's cross-listed into.
                // A replacement in *any* feed makes it an update (OR); a native
                // sighting (non-cross) in *any* tracked feed makes it not a
                // cross-list (AND). listingDate is identical across feeds — keep
                // whichever we have.
                existing.rssIsUpdate = combineOptionalBool(existing.rssIsUpdate, paper.rssIsUpdate, with: { $0 || $1 })
                existing.rssIsCrosslist = combineOptionalBool(existing.rssIsCrosslist, paper.rssIsCrosslist, with: { $0 && $1 })
                if existing.listingDate == nil { existing.listingDate = paper.listingDate }
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

    // Returns author-search results as value-type cards. Nothing is inserted
    // into SwiftData here — author results used to be persisted, which surfaced
    // them on Home and let the next sync's prune delete them (the reported
    // "results shrink on revisit" bug). Cards backed by an already-stored row
    // carry its saved state and persistent id; the rest are fetch-only until the
    // user explicitly saves them. Throws so the view can distinguish failure
    // from an empty result.
    func fetchPapersByAuthor(name: String, maxResults: Int = 100) async throws -> [PaperCard] {
        guard let target = AuthorName.parse(name) else { return [] }

        let fetched = try await ArxivFetcher.fetchByAuthor(target)

        // Deduplicate on arxivDedupKey (not url) so a stored v1 and a fetched v2
        // collapse. Stored rows win the key so their saved state is preserved.
        var byKey: [String: PaperCard] = [:]

        let stored = (try? modelContext.fetch(FetchDescriptor<Paper>())) ?? []
        for paper in stored where paper.authors.contains(where: { AuthorName.parse($0).map { target.matches($0) } ?? false }) {
            byKey[arxivDedupKey(for: paper.url)] = PaperCard(paper)
        }

        for parsed in fetched.values {
            guard let url = parsed.url else { continue }
            guard parsed.authors.contains(where: { AuthorName.parse($0).map { target.matches($0) } ?? false }) else { continue }
            let key = arxivDedupKey(for: url)
            if byKey[key] == nil { byKey[key] = PaperCard(parsed: parsed) }
        }

        return byKey.values.sorted { ($0.sortDate) > ($1.sortDate) }
    }

    // Carries per-category outcome counts plus the dominant failure, so the
    // sync service can report honestly instead of collapsing everything to a
    // single Bool. `succeededCategories` is the *set* of categories that fetched
    // cleanly (not just a count) so the service can record per-category sync
    // timestamps for cheap partial retries.
    struct SyncResult {
        let added: Int
        let succeededCategories: Set<String>
        let totalCategories: Int
        let dominantFailure: SyncFailure?
    }

    // Primary entry point. `fetchCategories` is the set to actually hit the
    // network for (auto-sync may pass only the stale ones); `selectedCategories`
    // is the user's full selection, used for pruning and cross-list derivation
    // so skipping a fresh category can't cause its papers to be pruned away.
    @discardableResult
    func syncPapers(
        fetchCategories: [String],
        selectedCategories: [String],
        maxResultsPerCategory: Int = 200,
        lookbackDays: Int = 30,
        onProgress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async -> SyncResult {
        let tracked = Set(selectedCategories.map { $0.lowercased() })

        do {
            try prunePapersNotMatchingSelectedCategories(
                selectedCategories: Set(selectedCategories.map { $0.lowercased() }),
                keepSaved: true
            )
        } catch {
            #if DEBUG
            print("⚠️ Failed to prune papers: \(error)")
            #endif
        }

        let fetched = await ArxivFetcher.fetchAll(
            categories: fetchCategories,
            maxPerCategory: maxResultsPerCategory,
            lookbackDays: lookbackDays,
            onProgress: onProgress
        )

        // A failed category contributes nothing but never blanks the day: only
        // the successfully-fetched papers reach storage sync.
        let added = synchronizeWithStorage(fetched.mergedPapers, trackedCategories: tracked, lookbackDays: lookbackDays)

        return SyncResult(
            added: added,
            succeededCategories: fetched.succeededCategories,
            totalCategories: fetchCategories.count,
            dominantFailure: fetched.dominantFailure
        )
    }

    // Backward-compatible convenience for callers that fetch their full
    // selection in one shot (Onboarding, Settings apply).
    @discardableResult
    func syncPapers(
        for categories: [String],
        trackedCategories: [String]? = nil,
        maxResultsPerCategory: Int = 200,
        lookbackDays: Int = 30
    ) async -> SyncResult {
        await syncPapers(
            fetchCategories: categories,
            selectedCategories: trackedCategories ?? categories,
            maxResultsPerCategory: maxResultsPerCategory,
            lookbackDays: lookbackDays
        )
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

    // The announcement instant is fixed by arXiv (20:00 ET), but the message
    // shows it in the phone's timezone — "today"/"tomorrow" and the clock time
    // are computed on the user's local calendar.
    nonisolated static func friendlyNextAnnouncement(from date: Date = Date()) -> String {
        let next = nextAnnouncement(after: date)
        let calendar = Calendar.current

        let nowDay = calendar.startOfDay(for: date)
        let nextDay = calendar.startOfDay(for: next)
        let dayDiff = calendar.dateComponents([.day], from: nowDay, to: nextDay).day ?? 0

        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = .current
        timeFormatter.dateFormat = "h a"
        let timeString = timeFormatter.string(from: next)

        switch dayDiff {
        case 0: return "next batch \(timeString)"
        case 1: return "next batch tomorrow \(timeString)"
        default:
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.timeZone = .current
            weekdayFormatter.dateFormat = "EEEE"
            return "next batch \(weekdayFormatter.string(from: next)) \(timeString)"
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
                guard let url = parsed.url else { continue }
                let key = arxivDedupKey(for: url)

                // Listing day: RSS states it (pubDate); the Atom path derives it
                // from the last-updated timestamp. A paper with neither is unusable.
                let listing: Date
                if let l = parsed.listingDate {
                    listing = l
                } else if let u = parsed.updatedDate {
                    listing = Self.announcementDate(from: u)
                } else {
                    continue
                }

                if listing < cutoff, storedByKey[key]?.saved != true {
                    continue
                }

                if let existing = storedByKey[key] {
                    // A new version (…v2) keeps the same dedup key; point the
                    // stored row at the newest URL.
                    if existing.url != url {
                        existing.url = url
                        if parsed.rssIsUpdate == nil { existing.isUpdate = true }
                    }
                    existing.categories = Array(Set(existing.categories + Array(parsed.categories)))

                    if (existing.primaryCategory.isEmpty || existing.primaryCategory.lowercased() == "unknown"),
                       let bp = parsed.primaryCategory, !bp.isEmpty {
                        existing.primaryCategory = bp
                    }

                    // Prefer arXiv's own classification. It's authoritative and
                    // monotonic — a native (non-cross) sighting in any feed
                    // permanently wins — so we never recompute from the mutable
                    // tracked-category set (which reclassified saved papers on
                    // category edits). The Atom path keeps the legacy derivation.
                    if let rssCross = parsed.rssIsCrosslist {
                        existing.isCrosslist = existing.isCrosslist && rssCross
                    } else {
                        let primary = (parsed.primaryCategory ?? existing.primaryCategory).lowercased()
                        if !primary.isEmpty && primary != "unknown" {
                            existing.isCrosslist = !trackedCategories.contains(primary)
                        }
                    }
                    if let rssUpdate = parsed.rssIsUpdate {
                        existing.isUpdate = existing.isUpdate || rssUpdate
                    }

                    // Idempotent re-bucketing onto the correct local listing day
                    // (also repairs rows stored under the old ET-midnight convention).
                    existing.date = listing

                    // Backfill bibliographic extras as the feed provides them.
                    if let s = parsed.submittedDate { existing.submittedDate = s }
                    if let c = parsed.comment { existing.comment = c }
                    if let j = parsed.journalRef { existing.journalRef = j }
                    if let d = parsed.doi { existing.doi = d }
                } else {
                    let isCrosslist = parsed.rssIsCrosslist ?? {
                        let primary = (parsed.primaryCategory ?? "").lowercased()
                        return !primary.isEmpty && !trackedCategories.contains(primary)
                    }()
                    let isUpdate = parsed.rssIsUpdate ?? (parsed.submittedDate != parsed.updatedDate)

                    let paper = Paper(
                        title: parsed.title,
                        authors: parsed.authors,
                        abstract: parsed.abstract,
                        url: url,
                        categories: Array(parsed.categories),
                        primaryCategory: parsed.primaryCategory ?? "unknown",
                        date: listing,
                        isUpdate: isUpdate,
                        isCrosslist: isCrosslist,
                        submittedDate: parsed.submittedDate,
                        comment: parsed.comment,
                        journalRef: parsed.journalRef,
                        doi: parsed.doi
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

// MARK: - NotificationManager

// Local-notification helper. Authorization is requested only when the user opts
// in (never at launch), and every entry point degrades quietly when denied.
@MainActor
enum NotificationManager {
    static let dailySummaryID = "kiwi.dailySummary"

    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    // (Re)schedules a one-shot summary at the next announcement instant. We re-arm
    // on launch/foreground rather than using a calendar-repeat trigger because
    // "weekdays at 20:00 ET" doesn't express cleanly across the device timezone
    // and DST.
    static func scheduleDailySummary() async {
        guard await isAuthorized() else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [dailySummaryID])

        let content = UNMutableNotificationContent()
        content.title = "New arXiv papers"
        content.body = "Today's listing is out — open Kiwi to see what's new."
        content.sound = .default

        let interval = max(60, NetworkManager.nextAnnouncement().timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: dailySummaryID, content: content, trigger: trigger))
    }

    // Posted from a background sync when new keyword matches are found.
    static func postKeywordMatch(topTitle: String, count: Int) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = count > 1 ? "\(count) new papers match your keywords"
                                  : "New paper matches your keywords"
        content.body = topTitle
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "kiwi.keywords.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
