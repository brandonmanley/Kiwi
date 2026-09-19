import Foundation

// Lightweight parser + matcher for human author names, used by author search.
//
// Why:
// - arXiv stores authors as "Lastname, Firstname M." which means a substring
//   search for "Ed Witten" never matches "Witten, Edward". We parse both sides
//   and compare structurally.
// - Real names break naive tokenizers: particled surnames ("Simon van der
//   Meer"), suffixes ("Manley Jr."), and hyphenated/initialized given names
//   ("Jian-Wei Pan" ↔ "J.-W. Pan"). We model the given name as an *ordered* list
//   of tokens, each of which may be spelled out or just an initial, and compare
//   position-wise.
struct AuthorName: Equatable, Hashable {

    // A single given-name token. `full` is the folded spelled-out form when we
    // have it (nil for a bare initial); `initial` is always its first letter.
    struct GivenToken: Equatable, Hashable {
        let full: String?
        let initial: Character
    }

    // How two names relate. Ordered by strength for clustering decisions.
    enum Compatibility: Equatable {
        case same        // all compared given tokens spelled out and equal
        case compatible  // agree, but only via a spelled prefix (Ed ⊂ Edward)
        case ambiguous   // agree, but a position was resolved only by an initial
        case different   // cannot be the same person
    }

    let original: String
    let given: [GivenToken]
    let lastName: String   // folded (lowercased, accents stripped, dots removed)

    // MARK: - Parsing

    // Suffix tokens stripped before anything else (folded, dotless).
    private static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "phd"]

    // Surname particles absorbed into the surname when walking backward through
    // an unpunctuated name ("van", "der", … in "Simon van der Meer").
    private static let particles: Set<String> = [
        "van", "von", "der", "den", "ter", "ten", "de", "del", "della", "di",
        "da", "das", "dos", "du", "le", "la", "bin", "ibn", "al", "mac", "mc", "o'"
    ]

    static func parse(_ raw: String) -> AuthorName? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Fold for comparison but keep dots and hyphens: given-name tokenization
        // needs them to split "J.-W." into two initials.
        let base = fold(trimmed)

        var lastNameTokens: [String]
        var givenRaw: [String]

        if base.contains(",") {
            // "Last, First Middle" — arXiv's own emission. The surname (which may
            // itself be multi-word, e.g. "van der Meer") sits before the comma.
            let parts = base.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            lastNameTokens = parts[0].split(separator: " ").map(String.init)
            givenRaw = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
            if let last = givenRaw.last, isSuffix(last) { givenRaw.removeLast() }
        } else {
            var tokens = base.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            if let last = tokens.last, isSuffix(last) { tokens.removeLast() }
            guard !tokens.isEmpty else { return nil }

            // Walk backward from the final token, absorbing surname particles.
            var lastParts = [tokens.removeLast()]
            while let candidate = tokens.last, isParticle(candidate) {
                lastParts.insert(candidate, at: 0)
                tokens.removeLast()
            }
            lastNameTokens = lastParts
            givenRaw = tokens
        }

        let lastName = lastNameTokens.joined(separator: " ")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !lastName.isEmpty else { return nil }

        // Split each given token on hyphens and periods so "Jian-Wei" and
        // "J.-W." both yield two tokens with initials j and w.
        var given: [GivenToken] = []
        for token in givenRaw {
            let subs = token.components(separatedBy: CharacterSet(charactersIn: "-.")).filter { !$0.isEmpty }
            for sub in subs {
                given.append(GivenToken(full: sub.count >= 2 ? sub : nil, initial: sub.first!))
            }
        }

        return AuthorName(original: trimmed, given: given, lastName: lastName)
    }

    private static func isSuffix(_ token: String) -> Bool {
        suffixes.contains(token.replacingOccurrences(of: ".", with: ""))
    }

    private static func isParticle(_ token: String) -> Bool {
        particles.contains(token)
    }

    // Lowercase + strip diacritics. Dots and hyphens are intentionally kept so
    // given-name tokenization can see initials like "J.-W."
    private static func fold(_ s: String) -> String {
        (s.applyingTransform(.stripDiacritics, reverse: false) ?? s).lowercased()
    }

    // MARK: - Comparison

    private enum TokenRelation { case exact, prefix, viaInitial, different }

    private static func relate(_ a: GivenToken, _ b: GivenToken) -> TokenRelation {
        if let af = a.full, let bf = b.full {
            if af == bf { return .exact }
            if af.count >= 2 && bf.hasPrefix(af) { return .prefix }
            if bf.count >= 2 && af.hasPrefix(bf) { return .prefix }
            // Both spelled out and neither a prefix — the same position holds two
            // different names ("John" vs "Jane"). That's what separates people.
            return .different
        }
        // At least one side is a bare initial: agree iff the initials match.
        return a.initial == b.initial ? .viaInitial : .different
    }

    // How this name relates to another. Surnames must match after folding;
    // nothing else can rescue a surname mismatch.
    func compatibility(with other: AuthorName) -> Compatibility {
        guard lastName == other.lastName else { return .different }

        let n = min(given.count, other.given.count)
        // No given information to compare on at least one side — surname only.
        guard n > 0 else { return .ambiguous }

        var sawInitial = false
        var sawPrefix = false
        for i in 0..<n {
            switch Self.relate(given[i], other.given[i]) {
            case .different:  return .different
            case .viaInitial: sawInitial = true
            case .prefix:     sawPrefix = true
            case .exact:      break
            }
        }
        // Extra trailing tokens on one side only are tolerated (papers routinely
        // omit middle names), so we don't inspect positions past `n`.
        if sawInitial { return .ambiguous }
        if sawPrefix { return .compatible }
        return .same
    }

    // Thin wrapper kept so existing call sites keep compiling: anything but a
    // hard mismatch counts as a match.
    func matches(_ other: AuthorName) -> Bool {
        compatibility(with: other) != .different
    }

    // "First Middle Last" for display, from the folded tokens. Initials render
    // as "J."; spelled tokens are capitalized.
    var display: String {
        let givenParts = given.map { token -> String in
            if let full = token.full { return full.capitalized }
            return "\(token.initial.uppercased())."
        }
        let last = lastName.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        return (givenParts + [last]).joined(separator: " ")
    }

    // Count of spelled-out given tokens — used to pick a cluster's canonical label.
    var spelledOutCount: Int { given.filter { $0.full != nil }.count }

    // The distinct phrases to OR together in a quoted `au:` query, covering both
    // orderings arXiv may have indexed ("Brandon Manley" and "Manley, Brandon").
    // Uses the *original* spelling so diacritics and casing survive.
    func queryPhrases() -> [String] {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let surnameWordCount = lastName.split(separator: " ").count

        if trimmed.contains(",") {
            let parts = trimmed.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let last = parts[0]
            let givenPart = parts.count > 1 ? parts[1] : ""
            let forward = givenPart.isEmpty ? last : "\(givenPart) \(last)"
            return Self.dedupePhrases([forward, trimmed])
        }

        // Drop any trailing suffix ("Jr.") before splitting surname from given.
        var words = trimmed.split(separator: " ").map(String.init)
        while let last = words.last, Self.isSuffix(Self.fold(last)) { words.removeLast() }
        guard words.count > surnameWordCount else { return [trimmed] }

        let surname = words.suffix(surnameWordCount).joined(separator: " ")
        let givenPart = words.prefix(words.count - surnameWordCount).joined(separator: " ")
        let comma = givenPart.isEmpty ? surname : "\(surname), \(givenPart)"
        return Self.dedupePhrases([words.joined(separator: " "), comma])
    }

    private static func dedupePhrases(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        return phrases.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - AuthorIdentity (variant clustering)

// A single human identity absorbed from many raw author-string variants.
// `isAmbiguous` marks an initials-only variant that could belong to more than
// one distinct person of the same surname ("B. Manley" when both Brandon and
// Bernard Manley exist).
struct AuthorIdentity: Identifiable, Equatable {
    let canonical: String
    let variants: Set<String>
    let isAmbiguous: Bool

    // Stable across rebuilds so SwiftUI keeps chip identity.
    var id: String { variants.sorted().joined(separator: "|") }
}

extension AuthorName {

    // Cluster raw author strings into distinct identities.
    //
    // Compatibility is *not* transitive — "B. Manley" is compatible with both
    // "Brandon Manley" and "Bernard Manley" while those two are `.different` —
    // so naive union-find would merge two people. Instead we seed clusters from
    // the spelled-out variants (which can be told apart) and only then attach
    // each initials-only variant, and only when exactly one seed accepts it.
    static func cluster(_ rawNames: [String]) -> [AuthorIdentity] {
        let parsed: [(raw: String, name: AuthorName)] = rawNames.compactMap { raw in
            AuthorName.parse(raw).map { (raw, $0) }
        }

        var identities: [AuthorIdentity] = []
        for (_, group) in Dictionary(grouping: parsed, by: { $0.name.lastName }) {
            identities.append(contentsOf: clusterSurnameGroup(group))
        }
        return identities.sorted { $0.canonical < $1.canonical }
    }

    private struct Cluster {
        var members: [(raw: String, name: AuthorName)]
        var ambiguous: Bool
    }

    private static func clusterSurnameGroup(_ group: [(raw: String, name: AuthorName)]) -> [AuthorIdentity] {
        let seeds = group.filter { $0.name.spelledOutCount > 0 }
        let initialsOnly = group.filter { $0.name.spelledOutCount == 0 }

        var clusters: [Cluster] = []

        // Seed from spelled-out variants. A seed joins an existing cluster only
        // when it is same/compatible with *every* member; if two clusters would
        // accept it, it's genuinely ambiguous and stands alone.
        for seed in seeds {
            let accepting = clusters.indices.filter { idx in
                clusters[idx].members.allSatisfy { member in
                    let c = seed.name.compatibility(with: member.name)
                    return c == .same || c == .compatible
                }
            }
            if accepting.count == 1 {
                clusters[accepting[0]].members.append(seed)
            } else {
                clusters.append(Cluster(members: [seed], ambiguous: accepting.count > 1))
            }
        }

        // Attach initials-only variants to the single compatible seed cluster.
        // Zero matches (no spelled seed at all) or more than one match becomes
        // its own, ambiguous, entry rather than being silently merged.
        for variant in initialsOnly {
            let accepting = clusters.indices.filter { idx in
                !clusters[idx].ambiguous && clusters[idx].members.contains { member in
                    variant.name.compatibility(with: member.name) != .different
                }
            }
            if accepting.count == 1 {
                clusters[accepting[0]].members.append(variant)
            } else {
                clusters.append(Cluster(members: [variant], ambiguous: true))
            }
        }

        return clusters.map { cluster in
            // Canonical label: the variant with the most spelled-out given tokens.
            let best = cluster.members.max { $0.name.spelledOutCount < $1.name.spelledOutCount }!
            return AuthorIdentity(
                canonical: best.name.display,
                variants: Set(cluster.members.map { $0.raw }),
                isAmbiguous: cluster.ambiguous
            )
        }
    }
}
