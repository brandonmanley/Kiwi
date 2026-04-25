import Foundation
import NaturalLanguage

struct KeywordScorer {

    struct Weights {
        var title: Double = 3.0
        var authors: Double = 3.0
        var abstract: Double = 2.0
        var phraseBonus: Double = 2.0
        var multiHitBonus: Double = 1.0   // small bonus per additional distinct keyword hit
    }

    static func score(paper: Paper, keywords: [String], weights: Weights = .init()) -> Double {
        let normalizedKeywords = normalizeKeywords(keywords)
        guard !normalizedKeywords.isEmpty else { return 0 }

        // Phrase bonus: if a multi-word keyword appears literally in any field.
        // (This helps a lot for things like “color glass condensate”.)
        let haystackAll = normalizeText(paper.title + " " + paper.authors.joined(separator: " ") + " " + paper.abstract)
        var score: Double = 0
        for kw in normalizedKeywords where kw.contains(" ") {
            if haystackAll.contains(kw) { score += weights.phraseBonus }
        }

        // Token sets (lemmatized)
        let titleTokens = tokenSet(paper.title)
        let authorTokens = tokenSet(paper.authors.joined(separator: " "))
        let abstractTokens = tokenSet(paper.abstract)

        // Keyword tokens (lemmatized per keyword)
        // We treat each keyword as a token (or tokens for multi-word; phrase handled above).
        let keywordTokens = Set(normalizedKeywords
            .flatMap { tokenSet($0) }
            .filter { !$0.isEmpty }
        )

        // Count distinct hits in each field
        let titleHits = titleTokens.intersection(keywordTokens).count
        let authorHits = authorTokens.intersection(keywordTokens).count
        let abstractHits = abstractTokens.intersection(keywordTokens).count

        score += Double(titleHits) * weights.title
        score += Double(authorHits) * weights.authors
        score += Double(abstractHits) * weights.abstract

        // Small bonus if multiple distinct keywords hit anywhere
        let distinctHits = Set(titleTokens.union(authorTokens).union(abstractTokens)).intersection(keywordTokens).count
        if distinctHits > 1 {
            score += Double(distinctHits - 1) * weights.multiHitBonus
        }

        return score
    }

    // MARK: - Normalization / tokenization

    private static func normalizeKeywords(_ keywords: [String]) -> [String] {
        keywords
            .map { normalizeText($0) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeText(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
         .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        let normalized = normalizeText(text)
        guard !normalized.isEmpty else { return [] }

        // Lemmatize using NLTagger (native Apple)
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = normalized

        var out = Set<String>()
        let range = normalized.startIndex..<normalized.endIndex
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        tagger.enumerateTags(in: range, unit: .word, scheme: .lemma, options: options) { tag, tokenRange in
            let surface = String(normalized[tokenRange])
            let lemma = tag?.rawValue ?? surface

            // Keep it simple: drop 1-char tokens, numbers
            if lemma.count >= 2, lemma.rangeOfCharacter(from: .decimalDigits) == nil {
                out.insert(lemma)
            }
            return true
        }
        return out
    }
}
