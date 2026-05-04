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

    private func components(from date: Date) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.dateComponents([.year, .month, .day, .weekday, .hour], from: date)
    }

    @Test func mondayMorningAnnouncedTuesday() {
        // Monday 10am ET → announced Mon 8pm → shifted to Tue 8pm
        let input = makeDate(year: 2026, month: 5, day: 4, hour: 10)
        let result = NetworkManager.announcementDate(from: input)
        let comps = components(from: result)
        #expect(comps.weekday == 3) // Tuesday
        #expect(comps.hour == 20)
    }

    @Test func mondayAfternoonAnnouncedWednesday() {
        // Monday 3pm ET → announced Tue 8pm → shifted to Wed 8pm
        let input = makeDate(year: 2026, month: 5, day: 4, hour: 15)
        let result = NetworkManager.announcementDate(from: input)
        let comps = components(from: result)
        #expect(comps.weekday == 4) // Wednesday
        #expect(comps.hour == 20)
    }

    @Test func thursdayAfternoonAnnouncedMonday() {
        // Thu 3pm ET → next Sun 8pm → shifted to Mon 8pm
        let input = makeDate(year: 2026, month: 5, day: 7, hour: 15)
        let result = NetworkManager.announcementDate(from: input)
        let comps = components(from: result)
        #expect(comps.weekday == 2) // Monday
        #expect(comps.hour == 20)
    }

    @Test func saturdayAnnouncedTuesday() {
        // Saturday → next Mon 8pm → shifted to Tue 8pm
        let input = makeDate(year: 2026, month: 5, day: 9, hour: 12)
        let result = NetworkManager.announcementDate(from: input)
        let comps = components(from: result)
        #expect(comps.weekday == 3) // Tuesday
        #expect(comps.hour == 20)
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
