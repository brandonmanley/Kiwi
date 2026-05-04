import Foundation
import NaturalLanguage

struct KeywordScorer {

    struct Weights {
        var title: Double = 3.0
        var authors: Double = 3.0
        var abstract: Double = 2.0
        var phraseBonus: Double = 2.0
        var multiHitBonus: Double = 1.0
    }

    struct PreparedKeywords {
        let normalized: [String]
        let tokens: Set<String>
    }

    static func prepare(keywords: [String]) -> PreparedKeywords? {
        let normalized = normalizeKeywords(keywords)
        guard !normalized.isEmpty else { return nil }
        let tokens = Set(normalized.flatMap { tokenSet($0) }.filter { !$0.isEmpty })
        guard !tokens.isEmpty else { return nil }
        return PreparedKeywords(normalized: normalized, tokens: tokens)
    }

    static func score(paper: Paper, prepared: PreparedKeywords, weights: Weights = .init()) -> Double {
        let haystackAll = normalizeText(paper.title + " " + paper.authors.joined(separator: " ") + " " + paper.abstract)
        var score: Double = 0
        for kw in prepared.normalized where kw.contains(" ") {
            if haystackAll.contains(kw) { score += weights.phraseBonus }
        }

        let titleTokens = tokenSet(paper.title)
        let authorTokens = tokenSet(paper.authors.joined(separator: " "))
        let abstractTokens = tokenSet(paper.abstract)

        let titleHits = titleTokens.intersection(prepared.tokens).count
        let authorHits = authorTokens.intersection(prepared.tokens).count
        let abstractHits = abstractTokens.intersection(prepared.tokens).count

        score += Double(titleHits) * weights.title
        score += Double(authorHits) * weights.authors
        score += Double(abstractHits) * weights.abstract

        let distinctHits = titleTokens.union(authorTokens).union(abstractTokens).intersection(prepared.tokens).count
        if distinctHits > 1 {
            score += Double(distinctHits - 1) * weights.multiHitBonus
        }

        return score
    }

    static func score(paper: Paper, keywords: [String], weights: Weights = .init()) -> Double {
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
