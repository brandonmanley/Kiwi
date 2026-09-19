import Testing
import Foundation
@testable import Kiwi

// MARK: - TextScorer Tests

@Suite struct TextScorerTests {

    private func makePaper(
        title: String = "",
        authors: [String] = [],
        abstract: String = ""
    ) -> Paper {
        Paper(
            title: title,
            authors: authors,
            abstract: abstract,
            url: URL(string: "https://arxiv.org/abs/\(UUID())")!,
            categories: ["hep-ph"],
            primaryCategory: "hep-ph",
            date: Date(),
            isUpdate: false,
            isCrosslist: false
        )
    }

    @Test func prepareEmptyKeywordsReturnsNil() {
        #expect(TextScorer.prepare(keywords: []) == nil)
        #expect(TextScorer.prepare(keywords: ["", "  "]) == nil)
    }

    @Test func prepareValidKeywords() {
        let prepared = TextScorer.prepare(keywords: ["quantum", "machine learning"])
        #expect(prepared != nil)
        #expect(!prepared!.tokens.isEmpty)
        #expect(prepared!.normalized.count == 2)
    }

    @Test func scoreZeroForNoKeywords() {
        let paper = makePaper(title: "Quantum Computing", abstract: "About qubits")
        #expect(TextScorer.score(paper: paper, keywords: []) == 0)
    }

    @Test func scoreTitleMatch() {
        let paper = makePaper(title: "Quantum Computing Advances", abstract: "Unrelated content here")
        let score = TextScorer.score(paper: paper, keywords: ["quantum"])
        #expect(score > 0)
    }

    @Test func preparedScoreMatchesLegacy() {
        let paper = makePaper(
            title: "Deep Learning for Physics",
            authors: ["Alice Smith"],
            abstract: "Neural networks applied to particle physics"
        )
        let keywords = ["neural", "physics"]

        let legacyScore = TextScorer.score(paper: paper, keywords: keywords)
        let prepared = TextScorer.prepare(keywords: keywords)!
        let preparedScore = TextScorer.score(paper: paper, prepared: prepared)

        #expect(legacyScore == preparedScore)
    }

    @Test func titleWeighedHigherThanAbstract() {
        let titleMatch = makePaper(title: "Quantum Computing", abstract: "Something unrelated entirely")
        let abstractMatch = makePaper(title: "Something unrelated entirely", abstract: "Quantum computing applications")
        let keywords = ["quantum"]

        let titleScore = TextScorer.score(paper: titleMatch, keywords: keywords)
        let abstractScore = TextScorer.score(paper: abstractMatch, keywords: keywords)

        #expect(titleScore > abstractScore)
    }

    @Test func phraseBonus() {
        let paper = makePaper(
            title: "Color glass condensate in heavy ion collisions",
            abstract: ""
        )
        let score = TextScorer.score(paper: paper, keywords: ["color glass condensate"])
        #expect(score > 0)
    }

    @Test func tokenSetHandlesEmptyInput() {
        #expect(TextScorer.tokenSet("").isEmpty)
        #expect(TextScorer.tokenSet("   ").isEmpty)
    }

    @Test func tokenSetProducesTokens() {
        let tokens = TextScorer.tokenSet("running computations quickly")
        #expect(!tokens.isEmpty)
        #expect(tokens.count >= 2)
    }

    @Test func normalizeTextFoldsDiacritics() {
        let result = TextScorer.normalizeText("café résumé")
        #expect(result == "cafe resume")
    }

    @Test func normalizeTextCollapsesWhitespace() {
        let result = TextScorer.normalizeText("  hello   world  ")
        #expect(result == "hello world")
    }
}

// MARK: - TokenCache Tests

@MainActor
@Suite struct TokenCacheTests {

    private func makePaper(url: String) -> Paper {
        Paper(
            title: "Quantum widgets and lattices",
            authors: ["Alice Smith"],
            abstract: "About qubits and correlated electrons",
            url: URL(string: url)!,
            categories: ["hep-ph"],
            primaryCategory: "hep-ph",
            date: Date(),
            isUpdate: false,
            isCrosslist: false
        )
    }

    @Test func repeatScoreDoesNotRetokenize() {
        let cache = TokenCache()
        let paper = makePaper(url: "https://arxiv.org/abs/2501.00001v1")
        _ = cache.tokens(for: paper)
        let after = cache.tokenizeCount
        _ = cache.tokens(for: paper)
        #expect(cache.tokenizeCount == after)
    }

    @Test func versionBumpInvalidates() {
        let cache = TokenCache()
        let paper = makePaper(url: "https://arxiv.org/abs/2501.00001v1")
        _ = cache.tokens(for: paper)
        let after = cache.tokenizeCount
        paper.url = URL(string: "https://arxiv.org/abs/2501.00001v2")!
        _ = cache.tokens(for: paper)
        #expect(cache.tokenizeCount == after + 1)
    }

    @Test func evictRemovesMissingIDs() {
        let cache = TokenCache()
        let p1 = makePaper(url: "https://arxiv.org/abs/2501.00001v1")
        let p2 = makePaper(url: "https://arxiv.org/abs/2501.00002v1")
        _ = cache.tokens(for: p1)
        _ = cache.tokens(for: p2)
        let before = cache.tokenizeCount
        cache.evict(keeping: [p1.id])
        _ = cache.tokens(for: p1) // still cached
        #expect(cache.tokenizeCount == before)
        _ = cache.tokens(for: p2) // evicted → re-tokenize
        #expect(cache.tokenizeCount == before + 1)
    }
}

// MARK: - AnnouncementDate Tests

@Suite struct AnnouncementDateTests {

    private func makeDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // The result must be midnight in the *local* calendar on the ET-defined
    // listing day, so day-bucketing works in any user timezone.
    private func expectListingDay(_ result: Date, year: Int, month: Int, day: Int) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: result)
        #expect(comps.year == year)
        #expect(comps.month == month)
        #expect(comps.day == day)
        #expect(result == cal.startOfDay(for: result)) // local midnight
    }

    @Test func mondayMorningListedTuesday() {
        // Monday 10am ET → announced Mon 8pm ET → listed Tue May 5
        let input = makeDate(year: 2026, month: 5, day: 4, hour: 10)
        expectListingDay(NetworkManager.announcementDate(from: input), year: 2026, month: 5, day: 5)
    }

    @Test func mondayAfternoonListedWednesday() {
        // Monday 3pm ET → announced Tue 8pm ET → listed Wed May 6
        let input = makeDate(year: 2026, month: 5, day: 4, hour: 15)
        expectListingDay(NetworkManager.announcementDate(from: input), year: 2026, month: 5, day: 6)
    }

    @Test func thursdayAfternoonListedMonday() {
        // Thu 3pm ET → announced Fri 8pm ET → listed Mon May 11
        let input = makeDate(year: 2026, month: 5, day: 7, hour: 15)
        expectListingDay(NetworkManager.announcementDate(from: input), year: 2026, month: 5, day: 11)
    }

    @Test func saturdayListedTuesday() {
        // Saturday → announced Mon 8pm ET → listed Tue May 12
        let input = makeDate(year: 2026, month: 5, day: 9, hour: 12)
        expectListingDay(NetworkManager.announcementDate(from: input), year: 2026, month: 5, day: 12)
    }
}

// MARK: - Settings Normalization Tests

@Suite struct SettingsNormalizationTests {

    @Test func normalizeCategoriesRemovesDuplicates() {
        let result = SettingsStore.normalizeCategories(["hep-ph", "hep-ph", "hep-th"])
        #expect(result.count == 2)
        #expect(result.contains("hep-ph"))
        #expect(result.contains("hep-th"))
    }

    @Test func normalizeCategoriesTrimsWhitespace() {
        let result = SettingsStore.normalizeCategories(["  hep-ph  ", "hep-th"])
        #expect(result.contains("hep-ph"))
    }

    @Test func normalizeCategoriesRemovesEmpty() {
        let result = SettingsStore.normalizeCategories(["", "  ", "hep-ph"])
        #expect(result == ["hep-ph"])
    }

    @Test func normalizeCategoriesSorts() {
        let result = SettingsStore.normalizeCategories(["hep-th", "cs.AI", "hep-ph"])
        #expect(result == ["cs.AI", "hep-ph", "hep-th"])
    }

    @Test func normalizeKeywordsDeduplicates() {
        let result = SettingsStore.normalizeKeywords(["quantum", "quantum", "neural"])
        #expect(result.count == 2)
    }

    @Test func normalizeKeywordsTrimsAndFilters() {
        let result = SettingsStore.normalizeKeywords(["  quantum  ", "", "  ", "neural"])
        #expect(result.count == 2)
        #expect(result.contains("quantum"))
        #expect(result.contains("neural"))
    }
}

// MARK: - arXiv dedup key Tests

@Suite struct ArxivDedupKeyTests {

    @Test func stripsTrailingVersion() {
        let v1 = URL(string: "http://arxiv.org/abs/2501.12345v1")!
        let v2 = URL(string: "http://arxiv.org/abs/2501.12345v2")!
        #expect(arxivDedupKey(for: v1) == arxivDedupKey(for: v2))
        #expect(arxivDedupKey(for: v1) == "http://arxiv.org/abs/2501.12345")
    }

    @Test func leavesUnversionedURLUnchanged() {
        let url = URL(string: "http://arxiv.org/abs/2501.12345")!
        #expect(arxivDedupKey(for: url) == "http://arxiv.org/abs/2501.12345")
    }

    @Test func doesNotStripVersionLikeSubstringMidPath() {
        // Only a trailing vN is a version suffix.
        let url = URL(string: "http://arxiv.org/abs/v2paper.99999")!
        #expect(arxivDedupKey(for: url) == "http://arxiv.org/abs/v2paper.99999")
    }
}

// MARK: - ArxivPageParser Tests

@Suite struct ArxivPageParserTests {

    private func feed(_ entries: String) -> Data {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
        \(entries)
        </feed>
        """.data(using: .utf8)!
    }

    @Test func parsesSingleEntry() {
        let data = feed("""
        <entry>
          <id>http://arxiv.org/abs/2501.12345v1</id>
          <updated>2025-01-20T10:00:00Z</updated>
          <published>2025-01-20T10:00:00Z</published>
          <title>A Study of Quantum Widgets</title>
          <summary>We investigate quantum widgets.</summary>
          <author><name>Alice Smith</name></author>
          <author><name>Bob Jones</name></author>
          <arxiv:primary_category term="hep-ph"/>
          <category term="hep-ph"/>
          <category term="hep-th"/>
        </entry>
        """)

        let result = ArxivPageParser().parse(data)
        #expect(result.count == 1)

        let paper = result["http://arxiv.org/abs/2501.12345"]
        #expect(paper != nil)
        #expect(paper?.title == "A Study of Quantum Widgets")
        #expect(paper?.abstract == "We investigate quantum widgets.")
        #expect(paper?.authors == ["Alice Smith", "Bob Jones"])
        #expect(paper?.primaryCategory == "hep-ph")
        #expect(paper?.categories == ["hep-ph", "hep-th"])
        #expect(paper?.url?.absoluteString == "http://arxiv.org/abs/2501.12345v1")
    }

    @Test func collapsesVersionsKeepingNewestURL() {
        // Same paper appearing as v1 and v2 in one feed must collapse to a
        // single record, retaining the newest versioned URL for linking.
        let data = feed("""
        <entry>
          <id>http://arxiv.org/abs/2501.12345v1</id>
          <updated>2025-01-20T10:00:00Z</updated>
          <published>2025-01-20T10:00:00Z</published>
          <title>Version One</title>
          <summary>First.</summary>
          <author><name>Alice Smith</name></author>
          <arxiv:primary_category term="hep-ph"/>
          <category term="hep-ph"/>
        </entry>
        <entry>
          <id>http://arxiv.org/abs/2501.12345v2</id>
          <updated>2025-02-01T10:00:00Z</updated>
          <published>2025-01-20T10:00:00Z</published>
          <title>Version Two</title>
          <summary>Second.</summary>
          <author><name>Alice Smith</name></author>
          <arxiv:primary_category term="hep-ph"/>
          <category term="hep-ph"/>
        </entry>
        """)

        let result = ArxivPageParser().parse(data)
        #expect(result.count == 1)

        let paper = result["http://arxiv.org/abs/2501.12345"]
        #expect(paper != nil)
        #expect(paper?.url?.absoluteString == "http://arxiv.org/abs/2501.12345v2")
    }

    @Test func emptyFeedYieldsNothing() {
        let result = ArxivPageParser().parse(feed(""))
        #expect(result.isEmpty)
    }

    @Test func parsesBibliographicFields() {
        let data = feed("""
        <entry>
          <id>http://arxiv.org/abs/2501.99999v1</id>
          <updated>2025-01-20T10:00:00Z</updated>
          <published>2025-01-18T10:00:00Z</published>
          <title>A Paper</title>
          <summary>Abstract.</summary>
          <author><name>Alice Smith</name></author>
          <arxiv:primary_category term="hep-ph"/>
          <category term="hep-ph"/>
          <arxiv:comment>12 pages, 3 figures</arxiv:comment>
          <arxiv:journal_ref>Phys. Rev. D 100, 012345</arxiv:journal_ref>
          <arxiv:doi>10.1103/PhysRevD.100.012345</arxiv:doi>
        </entry>
        """)
        let paper = ArxivPageParser().parse(data)["http://arxiv.org/abs/2501.99999"]
        #expect(paper?.comment == "12 pages, 3 figures")
        #expect(paper?.journalRef == "Phys. Rev. D 100, 012345")
        #expect(paper?.doi == "10.1103/PhysRevD.100.012345")
        #expect(paper?.submittedDate != nil)
    }

    @Test func missingBibliographicFieldsAreNil() {
        let data = feed("""
        <entry>
          <id>http://arxiv.org/abs/2501.88888v1</id>
          <updated>2025-01-20T10:00:00Z</updated>
          <published>2025-01-20T10:00:00Z</published>
          <title>Plain</title>
          <summary>Abstract.</summary>
          <author><name>Bob Jones</name></author>
          <arxiv:primary_category term="hep-ph"/>
          <category term="hep-ph"/>
        </entry>
        """)
        let paper = ArxivPageParser().parse(data)["http://arxiv.org/abs/2501.88888"]
        #expect(paper?.comment == nil)
        #expect(paper?.journalRef == nil)
        #expect(paper?.doi == nil)
    }
}

// MARK: - ArxivRSSParser Tests

@Suite struct ArxivRSSParserTests {

    // Mirrors a real rss.arxiv.org listing feed: a dated channel plus items that
    // carry an <arxiv:announce_type>, a version-stripped <link>, a versioned
    // <guid>, comma-joined <dc:creator>, and an "Announce Type: …/Abstract: …"
    // <description>.
    private func feed(_ items: String, channelPubDate: String = "Fri, 22 Aug 2026 00:00:00 -0400") -> Data {
        """
        <?xml version='1.0' encoding='UTF-8'?>
        <rss xmlns:arxiv="http://arxiv.org/schemas/atom" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom" version="2.0">
          <channel>
            <title>hep-ph updates on arXiv.org</title>
            <link>http://rss.arxiv.org/rss/hep-ph</link>
            <description>hep-ph updates on the arXiv.org e-print archive.</description>
            <pubDate>\(channelPubDate)</pubDate>
        \(items)
          </channel>
        </rss>
        """.data(using: .utf8)!
    }

    private func item(
        id: String,
        announceType: String,
        categories: [String] = ["hep-ph"],
        creator: String = "Alice Smith, Bob Jones",
        extras: String = ""
    ) -> String {
        let cats = categories.map { "      <category>\($0)</category>" }.joined(separator: "\n")
        return """
            <item>
              <title>A Study of \(id)</title>
              <link>https://arxiv.org/abs/\(id)</link>
              <description>arXiv:\(id)v1 Announce Type: \(announceType) \nAbstract: We investigate \(id).</description>
              <guid isPermaLink="false">oai:arXiv.org:\(id)v1</guid>
        \(cats)
              <pubDate>Fri, 22 Aug 2026 00:00:00 -0400</pubDate>
              <arxiv:announce_type>\(announceType)</arxiv:announce_type>
              <dc:creator>\(creator)</dc:creator>
        \(extras)
            </item>
        """
    }

    @Test func parsesSingleNewItem() {
        let data = feed(item(id: "2508.00001", announceType: "new", categories: ["hep-ph", "hep-th"]))
        let result = ArxivRSSParser().parse(data)
        #expect(result.count == 1)

        let paper = result["http://arxiv.org/abs/2508.00001"]
        #expect(paper != nil)
        #expect(paper?.title == "A Study of 2508.00001")
        #expect(paper?.abstract == "We investigate 2508.00001.")
        #expect(paper?.authors == ["Alice Smith", "Bob Jones"])
        #expect(paper?.primaryCategory == "hep-ph")
        #expect(paper?.categories == ["hep-ph", "hep-th"])
        // Rebuilt from the versioned guid, not the version-stripped <link>.
        #expect(paper?.url?.absoluteString == "http://arxiv.org/abs/2508.00001v1")
        #expect(paper?.rssIsUpdate == false)
        #expect(paper?.rssIsCrosslist == false)
    }

    // The dedup key must land on the same row an Atom fetch of the same paper
    // would produce (Atom <id> is http://arxiv.org/abs/<id>vN).
    @Test func dedupKeyConvergesWithAtomPath() {
        let data = feed(item(id: "2508.00002", announceType: "new"))
        let rssURL = ArxivRSSParser().parse(data)["http://arxiv.org/abs/2508.00002"]?.url
        let atomURL = URL(string: "http://arxiv.org/abs/2508.00002v3")!
        #expect(rssURL != nil)
        #expect(arxivDedupKey(for: rssURL!) == arxivDedupKey(for: atomURL))
    }

    @Test func announceTypeMapping() {
        let data = feed([
            item(id: "2508.10001", announceType: "new"),
            item(id: "2508.10002", announceType: "cross"),
            item(id: "2508.10003", announceType: "replace"),
            item(id: "2508.10004", announceType: "replace-cross"),
        ].joined(separator: "\n"))
        let r = ArxivRSSParser().parse(data)

        #expect(r["http://arxiv.org/abs/2508.10001"]?.rssIsUpdate == false)
        #expect(r["http://arxiv.org/abs/2508.10001"]?.rssIsCrosslist == false)

        #expect(r["http://arxiv.org/abs/2508.10002"]?.rssIsUpdate == false)
        #expect(r["http://arxiv.org/abs/2508.10002"]?.rssIsCrosslist == true)

        #expect(r["http://arxiv.org/abs/2508.10003"]?.rssIsUpdate == true)
        #expect(r["http://arxiv.org/abs/2508.10003"]?.rssIsCrosslist == false)

        #expect(r["http://arxiv.org/abs/2508.10004"]?.rssIsUpdate == true)
        #expect(r["http://arxiv.org/abs/2508.10004"]?.rssIsCrosslist == true)
    }

    @Test func parsesDOIandJournalReference() {
        let extras = """
              <arxiv:DOI>10.1103/PhysRevD.100.012345</arxiv:DOI>
              <arxiv:journal_reference>Phys. Rev. D 100, 012345</arxiv:journal_reference>
        """
        let data = feed(item(id: "2508.20001", announceType: "replace", extras: extras))
        let paper = ArxivRSSParser().parse(data)["http://arxiv.org/abs/2508.20001"]
        #expect(paper?.doi == "10.1103/PhysRevD.100.012345")
        #expect(paper?.journalRef == "Phys. Rev. D 100, 012345")
    }

    @Test func missingBibliographicFieldsAreNil() {
        let data = feed(item(id: "2508.30001", announceType: "new"))
        let paper = ArxivRSSParser().parse(data)["http://arxiv.org/abs/2508.30001"]
        #expect(paper?.doi == nil)
        #expect(paper?.journalRef == nil)
    }

    // pubDate is midnight ET; the listing date must bucket to local midnight of
    // that ET calendar day (Aug 22), so day-grouping works in any timezone.
    @Test func listingDateBucketsToLocalMidnightOfETDay() {
        let data = feed(item(id: "2508.40001", announceType: "new"))
        let listing = ArxivRSSParser().parse(data)["http://arxiv.org/abs/2508.40001"]?.listingDate
        #expect(listing != nil)
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: listing!)
        #expect(comps.year == 2026)
        #expect(comps.month == 8)
        #expect(comps.day == 22)
        #expect(listing == cal.startOfDay(for: listing!))
    }

    @Test func emptyFeedYieldsNothing() {
        #expect(ArxivRSSParser().parse(feed("")).isEmpty)
    }
}

// MARK: - Citation (BibTeX) Tests

@Suite struct CitationTests {

    @Test func arxivIDStripsVersion() {
        #expect(Citation.arxivID(from: URL(string: "http://arxiv.org/abs/2501.12345v2")!) == "2501.12345")
        #expect(Citation.arxivID(from: URL(string: "http://arxiv.org/abs/2501.12345")!) == "2501.12345")
    }

    @Test func bibtexContainsCoreFields() {
        let entry = Citation.bibtex(
            id: "2501.12345",
            title: "A Study of Quantum Widgets",
            authors: ["Alice Smith", "Bob Jones"],
            year: 2025,
            primaryClass: "hep-ph"
        )
        #expect(entry.contains("@article{arxiv250112345,"))
        #expect(entry.contains("title = {A Study of Quantum Widgets},"))
        #expect(entry.contains("author = {Alice Smith and Bob Jones},"))
        #expect(entry.contains("year = {2025},"))
        #expect(entry.contains("eprint = {2501.12345},"))
        #expect(entry.contains("archivePrefix = {arXiv},"))
        #expect(entry.contains("primaryClass = {hep-ph},"))
    }

    @Test func bibtexIncludesDOIandJournalWhenPresent() {
        let entry = Citation.bibtex(
            id: "2501.12345", title: "T", authors: ["A"], year: 2025,
            primaryClass: "hep-ph", doi: "10.1/x", journal: "Phys. Rev. D"
        )
        #expect(entry.contains("doi = {10.1/x},"))
        #expect(entry.contains("journal = {Phys. Rev. D},"))
    }

    @Test func bibtexOmitsUnknownPrimaryClass() {
        let entry = Citation.bibtex(id: "1", title: "T", authors: [], year: 2025, primaryClass: "unknown")
        #expect(!entry.contains("primaryClass"))
        #expect(!entry.contains("author =")) // no authors → no field
    }
}

// MARK: - ArxivCategories grouping Tests

@Suite struct ArxivCategoriesTests {

    @Test func hepVariantsShareOneGroup() {
        for cat in ["hep-ph", "hep-th", "hep-ex", "hep-lat"] {
            #expect(ArxivCategories.groupKey(for: cat) == "hep")
        }
        let hep = ArxivCategories.grouped().first { $0.key == "hep" }
        #expect(hep != nil)
        #expect(Set(hep?.values ?? []) == ["hep-ex", "hep-lat", "hep-ph", "hep-th"])
    }

    @Test func nuclVariantsShareOneGroup() {
        let nucl = ArxivCategories.grouped().first { $0.key == "nucl" }
        #expect(nucl != nil)
        #expect(Set(nucl?.values ?? []) == ["nucl-ex", "nucl-th"])
    }

    @Test func groupSequenceMatchesIntendedOrder() {
        let keys = ArxivCategories.grouped().map(\.key)
        #expect(keys == ["hep", "nucl", "astro-ph", "cond-mat", "quant-ph",
                         "gr-qc", "math-ph", "nlin", "physics"])
    }
}

// MARK: - AuthorName Tests

@Suite struct AuthorNameTests {

    private func compat(_ a: String, _ b: String) -> AuthorName.Compatibility {
        AuthorName.parse(a)!.compatibility(with: AuthorName.parse(b)!)
    }

    // Table from the brief. `.ambiguous` rows are the same identity resolved
    // only through an initial; `.different` rows are distinct people.
    @Test(arguments: [
        ("Brandon Manley",     "Manley, B.",        AuthorName.Compatibility.ambiguous),
        ("Brandon Manley",     "Manley, Brandon",   .same),
        ("Jian-Wei Pan",       "J.-W. Pan",         .ambiguous),
        ("John Smith",         "Jane Smith",        .different),
        ("J. Smith",           "John Smith",        .ambiguous),
        ("Simon van der Meer", "van der Meer, S.",  .ambiguous),
        ("Ed Witten",          "Edward Witten",     .compatible),
        ("Brandon Manley Jr.", "Brandon Manley",    .same),
        ("Yuri Kovchegov",     "Yuri Kovalenko",    .different),
    ])
    func compatibilityTable(a: String, b: String, expected: AuthorName.Compatibility) {
        #expect(compat(a, b) == expected)
    }

    @Test func particledSurnameParsesWholeSurname() {
        let name = AuthorName.parse("Simon van der Meer")
        #expect(name?.lastName == "van der meer")
        let comma = AuthorName.parse("van der Meer, S.")
        #expect(comma?.lastName == "van der meer")
    }

    @Test func suffixStrippedBeforeParsing() {
        let name = AuthorName.parse("Brandon Manley Jr.")
        #expect(name?.lastName == "manley")
        #expect(name?.given.count == 1)
        #expect(name?.given.first?.full == "brandon")
    }

    @Test func hyphenatedGivenSplitsIntoTwoInitials() {
        let name = AuthorName.parse("J.-W. Pan")
        #expect(name?.lastName == "pan")
        #expect(name?.given.map(\.initial) == ["j", "w"])
        #expect(name?.given.allSatisfy { $0.full == nil } == true)
    }
}

// MARK: - AuthorIdentity clustering Tests

@Suite struct AuthorIdentityTests {

    @Test func initialsCollapseIntoSingleIdentity() {
        let identities = AuthorName.cluster(["Manley, Brandon", "Manley, B.", "Manley, B. K."])
        #expect(identities.count == 1)
        #expect(identities.first?.isAmbiguous == false)
    }

    @Test func twoDistinctPeopleKeepAmbiguousInitialSeparate() {
        let identities = AuthorName.cluster(["Manley, Brandon", "Manley, Bernard", "Manley, B."])
        #expect(identities.count == 3)
        let ambiguous = identities.filter { $0.isAmbiguous }
        #expect(ambiguous.count == 1)
        #expect(ambiguous.first?.variants == ["Manley, B."])
    }
}

// MARK: - Fetch layer stub

// URLProtocol stub so the fetch/retry layer is testable without touching the
// network. Serves whatever the current `handler` returns. Safe to mutate the
// static because the test plan runs serially (single simulator, no parallelism).
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> Result<(HTTPURLResponse, Data), Error>)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch handler(request) {
        case .success(let (response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// Thread-safe request counter for asserting retry/attempt counts.
final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func increment() { lock.lock(); _count += 1; lock.unlock() }
}

// MARK: - ArxivFetcher (retry / error taxonomy) Tests

@Suite(.serialized) struct ArxivFetcherTests {

    // Redirects the fetcher at the stub with a fast limiter and near-zero
    // backoff, and restores everything afterward.
    private func withStub(
        _ handler: @escaping (URLRequest) -> Result<(HTTPURLResponse, Data), Error>,
        _ body: () async throws -> Void
    ) async rethrows {
        let savedSession = ArxivFetcher.session
        let savedLimiter = ArxivFetcher.rateLimiter
        let savedBackoff = ArxivFetcher.retryBaseDelay
        defer {
            ArxivFetcher.session = savedSession
            ArxivFetcher.rateLimiter = savedLimiter
            ArxivFetcher.retryBaseDelay = savedBackoff
            StubURLProtocol.handler = nil
        }
        StubURLProtocol.handler = handler
        ArxivFetcher.session = ArxivFetcher.makeSession(protocolClasses: [StubURLProtocol.self])
        ArxivFetcher.rateLimiter = ArxivRateLimiter(minInterval: 0)
        ArxivFetcher.retryBaseDelay = 0.001
        try await body()
    }

    private func http(_ url: URL, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private func oneEntryFeed() -> Data {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
        <entry>
          <id>http://arxiv.org/abs/2601.00001v1</id>
          <updated>2026-08-18T10:00:00Z</updated>
          <published>2026-08-18T10:00:00Z</published>
          <title>Stub Paper</title>
          <summary>Stub.</summary>
          <author><name>Alice Smith</name></author>
          <arxiv:primary_category term="hep-ph"/>
          <category term="hep-ph"/>
        </entry>
        </feed>
        """.data(using: .utf8)!
    }

    @Test func retriesOnceOn429ThenSucceeds() async throws {
        let hits = HitCounter()
        try await withStub({ request in
            hits.increment()
            if hits.count == 1 {
                return .success((self.http(request.url!, 429, headers: ["Retry-After": "0"]), Data()))
            }
            return .success((self.http(request.url!, 200), self.oneEntryFeed()))
        }) {
            let req = URLRequest(url: URL(string: "https://export.arxiv.org/api/query?search_query=cat:hep-ph")!)
            let data = try await ArxivFetcher.fetchData(req)
            #expect(!data.isEmpty)
            #expect(hits.count == 2) // one 429, one success
        }
    }

    @Test func threeConsecutive503sExhaustRetriesAndThrowThrottled() async throws {
        let hits = HitCounter()
        var thrown: Error?
        await withStub({ request in
            hits.increment()
            return .success((self.http(request.url!, 503), Data()))
        }) {
            let req = URLRequest(url: URL(string: "https://export.arxiv.org/api/query?search_query=cat:hep-ph")!)
            do { _ = try await ArxivFetcher.fetchData(req) }
            catch { thrown = error }
        }
        #expect(hits.count == 3) // maxAttempts total
        if case .throttled = (thrown as? SyncFailure) {} else {
            Issue.record("Expected .throttled, got \(String(describing: thrown))")
        }
    }

    @Test func notConnectedSurfacesOfflineWithoutRetry() async throws {
        let hits = HitCounter()
        var thrown: Error?
        await withStub({ _ in
            hits.increment()
            return .failure(URLError(.notConnectedToInternet))
        }) {
            let req = URLRequest(url: URL(string: "https://export.arxiv.org/api/query?search_query=cat:hep-ph")!)
            do { _ = try await ArxivFetcher.fetchData(req) }
            catch { thrown = error }
        }
        // URLSession may itself retry a connection failure once, so we don't
        // assert exactly one hit — but our own retry loop must NOT engage
        // (which would produce the full 3 attempts, as the 503 test shows).
        #expect(hits.count < 3, "Our retry loop should not engage for a hard offline error")
        #expect((thrown as? SyncFailure) == .offline)
    }

    @Test func mixedRunProducesPartialSuccess() async throws {
        try await withStub({ request in
            let query = request.url?.query ?? ""
            // Category B is permanently throttled; A and C succeed.
            if query.contains("cat:B") {
                return .success((self.http(request.url!, 503), Data()))
            }
            return .success((self.http(request.url!, 200), self.oneEntryFeed()))
        }) {
            let result = await ArxivFetcher.fetchAll(
                categories: ["A", "B", "C"],
                maxPerCategory: 100,
                lookbackDays: 30
            )
            #expect(result.succeededCategories == ["A", "C"])
            #expect(!result.mergedPapers.isEmpty)
            if case .throttled = result.dominantFailure {} else {
                Issue.record("Expected dominant .throttled, got \(String(describing: result.dominantFailure))")
            }
        }
    }
}

// MARK: - ArxivRateLimiter concurrency Tests

@Suite struct ArxivRateLimiterTests {

    // Concurrent callers must never start two requests less than the interval
    // apart — the arXiv ToU single-request-per-three-seconds clause.
    @Test func serializesStartsAtLeastThreeSecondsApart() async {
        let interval: TimeInterval = 3.0
        let limiter = ArxivRateLimiter(minInterval: interval)
        let callers = 3

        var starts = await withTaskGroup(of: Date.self) { group -> [Date] in
            for _ in 0..<callers {
                group.addTask {
                    await limiter.waitForSlot()
                    return Date()
                }
            }
            var collected: [Date] = []
            for await t in group { collected.append(t) }
            return collected
        }

        starts.sort()
        for i in 1..<starts.count {
            let gap = starts[i].timeIntervalSince(starts[i - 1])
            #expect(gap >= interval - 0.3, "Consecutive starts \(gap)s apart — under the \(interval)s policy")
        }
    }
}
