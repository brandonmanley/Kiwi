import Testing
import Foundation
@testable import Kiwi

// MARK: - KeywordScorer Tests

@Suite struct KeywordScorerTests {

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
        #expect(KeywordScorer.prepare(keywords: []) == nil)
        #expect(KeywordScorer.prepare(keywords: ["", "  "]) == nil)
    }

    @Test func prepareValidKeywords() {
        let prepared = KeywordScorer.prepare(keywords: ["quantum", "machine learning"])
        #expect(prepared != nil)
        #expect(!prepared!.tokens.isEmpty)
        #expect(prepared!.normalized.count == 2)
    }

    @Test func scoreZeroForNoKeywords() {
        let paper = makePaper(title: "Quantum Computing", abstract: "About qubits")
        #expect(KeywordScorer.score(paper: paper, keywords: []) == 0)
    }

    @Test func scoreTitleMatch() {
        let paper = makePaper(title: "Quantum Computing Advances", abstract: "Unrelated content here")
        let score = KeywordScorer.score(paper: paper, keywords: ["quantum"])
        #expect(score > 0)
    }

    @Test func preparedScoreMatchesLegacy() {
        let paper = makePaper(
            title: "Deep Learning for Physics",
            authors: ["Alice Smith"],
            abstract: "Neural networks applied to particle physics"
        )
        let keywords = ["neural", "physics"]

        let legacyScore = KeywordScorer.score(paper: paper, keywords: keywords)
        let prepared = KeywordScorer.prepare(keywords: keywords)!
        let preparedScore = KeywordScorer.score(paper: paper, prepared: prepared)

        #expect(legacyScore == preparedScore)
    }

    @Test func titleWeighedHigherThanAbstract() {
        let titleMatch = makePaper(title: "Quantum Computing", abstract: "Something unrelated entirely")
        let abstractMatch = makePaper(title: "Something unrelated entirely", abstract: "Quantum computing applications")
        let keywords = ["quantum"]

        let titleScore = KeywordScorer.score(paper: titleMatch, keywords: keywords)
        let abstractScore = KeywordScorer.score(paper: abstractMatch, keywords: keywords)

        #expect(titleScore > abstractScore)
    }

    @Test func phraseBonus() {
        let paper = makePaper(
            title: "Color glass condensate in heavy ion collisions",
            abstract: ""
        )
        let score = KeywordScorer.score(paper: paper, keywords: ["color glass condensate"])
        #expect(score > 0)
    }

    @Test func tokenSetHandlesEmptyInput() {
        #expect(KeywordScorer.tokenSet("").isEmpty)
        #expect(KeywordScorer.tokenSet("   ").isEmpty)
    }

    @Test func tokenSetProducesTokens() {
        let tokens = KeywordScorer.tokenSet("running computations quickly")
        #expect(!tokens.isEmpty)
        #expect(tokens.count >= 2)
    }

    @Test func normalizeTextFoldsDiacritics() {
        let result = KeywordScorer.normalizeText("café résumé")
        #expect(result == "cafe resume")
    }

    @Test func normalizeTextCollapsesWhitespace() {
        let result = KeywordScorer.normalizeText("  hello   world  ")
        #expect(result == "hello world")
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
}
