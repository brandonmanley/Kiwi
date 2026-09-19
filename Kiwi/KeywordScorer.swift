import Foundation
import NaturalLanguage

// Unified relevance scorer for both keyword prioritization (Home / Daily) and
// free-text search (Search). Previously this logic was duplicated across
// `KeywordScorer` and a `private` `SearchScorer` inside SearchView (which meant
// the search variant couldn't be unit-tested at all). The only real difference
// was the weight profile, now expressed as named presets.
struct TextScorer {

    struct Weights {
        var title: Double
        var authors: Double
        var abstract: Double
        var phraseBonus: Double
        var multiHitBonus: Double

        // Keyword prioritization: title and authors matter, phrases are a mild nudge.
        static let keyword = Weights(title: 3.0, authors: 3.0, abstract: 2.0, phraseBonus: 2.0, multiHitBonus: 1.0)
        // Free-text search: title dominates, an exact phrase is a strong signal.
        static let search = Weights(title: 6.0, authors: 3.0, abstract: 1.0, phraseBonus: 4.0, multiHitBonus: 0.35)
    }

    struct Prepared {
        let normalized: [String]
        // Phrases to reward as contiguous substrings of the haystack.
        let phrases: [String]
        let tokens: Set<String>
    }

    // Keyword-list preparation (each entry a keyword; multi-word entries phrase).
    static func prepare(keywords: [String]) -> Prepared? {
        let normalized = normalizeKeywords(keywords)
        guard !normalized.isEmpty else { return nil }
        let tokens = Set(normalized.flatMap { tokenSet($0) }.filter { !$0.isEmpty })
        guard !tokens.isEmpty else { return nil }
        let phrases = normalized.filter { $0.contains(" ") }
        return Prepared(normalized: normalized, phrases: phrases, tokens: tokens)
    }

    // Single free-text query preparation (the whole query is the phrase).
    static func prepare(query: String) -> Prepared? {
        let q = normalizeText(query)
        guard !q.isEmpty else { return nil }
        let tokens = tokenSet(q)
        guard !tokens.isEmpty else { return nil }
        let phrases = q.count >= 3 ? [q] : []
        return Prepared(normalized: [q], phrases: phrases, tokens: tokens)
    }

    // MARK: - Scoring

    // Core scorer over *precomputed* token sets, so callers reading through
    // TokenCache never re-tokenize.
    static func score(
        titleTokens: Set<String>,
        authorTokens: Set<String>,
        abstractTokens: Set<String>,
        haystack: String,
        prepared: Prepared,
        weights: Weights
    ) -> Double {
        var score = 0.0

        for phrase in prepared.phrases where !phrase.isEmpty {
            if haystack.contains(phrase) { score += weights.phraseBonus }
        }

        let titleHits = titleTokens.intersection(prepared.tokens).count
        let authorHits = authorTokens.intersection(prepared.tokens).count
        let abstractHits = abstractTokens.intersection(prepared.tokens).count

        score += Double(titleHits) * weights.title
        score += Double(authorHits) * weights.authors
        score += Double(abstractHits) * weights.abstract

        let distinctHits = titleTokens.union(authorTokens).union(abstractTokens)
            .intersection(prepared.tokens).count
        if distinctHits > 1 {
            score += Double(distinctHits - 1) * weights.multiHitBonus
        }
        return score
    }

    // Convenience that tokenizes a Paper inline (used by tests and any non-cached
    // path). Prefer the token-set overload with TokenCache in hot loops.
    static func score(paper: Paper, prepared: Prepared, weights: Weights = .keyword) -> Double {
        let authors = paper.authors.joined(separator: " ")
        let haystack = normalizeText(paper.title + " " + authors + " " + paper.abstract)
        return score(
            titleTokens: tokenSet(paper.title),
            authorTokens: tokenSet(authors),
            abstractTokens: tokenSet(paper.abstract),
            haystack: haystack,
            prepared: prepared,
            weights: weights
        )
    }

    static func score(paper: Paper, keywords: [String], weights: Weights = .keyword) -> Double {
        guard let prepared = prepare(keywords: keywords) else { return 0 }
        return score(paper: paper, prepared: prepared, weights: weights)
    }

    // MARK: - Normalization / tokenization

    static func normalizeKeywords(_ keywords: [String]) -> [String] {
        keywords
            .map { normalizeText($0) }
            .filter { !$0.isEmpty }
    }

    static func normalizeText(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
         .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokenSet(_ text: String) -> Set<String> {
        let normalized = normalizeText(text)
        guard !normalized.isEmpty else { return [] }

        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = normalized

        var out = Set<String>()
        let range = normalized.startIndex..<normalized.endIndex
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma, options: options) { tag, tokenRange in
            let surface = String(normalized[tokenRange])
            let lemma = tag?.rawValue ?? surface
            if lemma.count >= 2, lemma.rangeOfCharacter(from: .decimalDigits) == nil {
                out.insert(lemma)
            }
            return true
        }
        return out
    }
}

// MARK: - TokenCache

// In-memory cache of a paper's lemmatized token sets, so filter/keyword/keystroke
// changes don't re-run NLTagger over thousands of papers each time. Keyed by
// Paper.id and invalidated when the paper's `url` changes (a new version).
@MainActor
final class TokenCache {
    static let shared = TokenCache()

    struct Tokens: Sendable {
        let title: Set<String>
        let authors: Set<String>
        let abstract: Set<String>
        let haystack: String
    }

    private struct Entry {
        let url: URL
        let tokens: Tokens
    }

    private var entries: [UUID: Entry] = [:]
    // Test hook: how many times we actually tokenized (a cache hit doesn't bump it).
    private(set) var tokenizeCount = 0

    func tokens(for paper: Paper) -> Tokens {
        if let entry = entries[paper.id], entry.url == paper.url {
            return entry.tokens
        }
        tokenizeCount += 1
        let authors = paper.authors.joined(separator: " ")
        let tokens = Tokens(
            title: TextScorer.tokenSet(paper.title),
            authors: TextScorer.tokenSet(authors),
            abstract: TextScorer.tokenSet(paper.abstract),
            haystack: TextScorer.normalizeText(paper.title + " " + authors + " " + paper.abstract)
        )
        entries[paper.id] = Entry(url: paper.url, tokens: tokens)
        return tokens
    }

    // Drop entries for papers that no longer exist (e.g. after a sync prune).
    func evict(keeping ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    func clear() { entries.removeAll() }
}
