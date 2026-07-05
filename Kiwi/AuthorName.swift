import Foundation

// Lightweight parser + matcher for human author names, used by author search.
//
// Why:
// - arXiv stores authors as "Lastname, Firstname M." which means a substring
//   search for "Ed Witten" never matches "Witten, Edward". We parse both
//   sides and compare structurally.
// - We want "Ed Witten" and "Edward Witten" to be equivalent. The rule is:
//   same last name, AND either initials match OR one first-name is a prefix
//   of the other (this covers "E"/"Ed"/"Edward").
struct AuthorName: Equatable, Hashable {
    let original: String
    let firstName: String?   // folded (lowercased, accents stripped, dots removed)
    let middleNames: [String]
    let lastName: String

    static func parse(_ raw: String) -> AuthorName? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let folded = fold(trimmed)

        // Handle "Last, First Middle"
        let tokens: [String]
        if folded.contains(",") {
            let parts = folded.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let last = parts[0]
            let firstMiddle = parts.count > 1
                ? parts[1].split(separator: " ").map(String.init)
                : []
            tokens = firstMiddle + [last]
        } else {
            tokens = folded.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        }

        guard let last = tokens.last, !last.isEmpty else { return nil }

        if tokens.count == 1 {
            return AuthorName(original: trimmed, firstName: nil, middleNames: [], lastName: last)
        }

        let first = tokens.first!
        let middle = Array(tokens.dropFirst().dropLast())
        return AuthorName(original: trimmed, firstName: first, middleNames: middle, lastName: last)
    }

    // True if these two names could plausibly refer to the same person.
    // Rule: last names must match; if both have first names, either they're
    // identical, one is an initial of the other, or one is a prefix of the
    // other (≥ 2 chars). If either side has no first name, it's a wildcard.
    func matches(_ other: AuthorName) -> Bool {
        guard lastName == other.lastName else { return false }

        guard let a = firstName, let b = other.firstName else { return true }

        if a == b { return true }

        let aIsInitial = a.count == 1
        let bIsInitial = b.count == 1

        if aIsInitial && b.hasPrefix(a) { return true }
        if bIsInitial && a.hasPrefix(b) { return true }

        // "Ed" vs "Edward": one full first name is a prefix of the other.
        // Require ≥ 2 chars to avoid "Er"/"Ed" style false positives.
        if a.count >= 2 && b.hasPrefix(a) { return true }
        if b.count >= 2 && a.hasPrefix(b) { return true }

        return false
    }

    private static func fold(_ s: String) -> String {
        let stripped = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        return stripped
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
    }
}
