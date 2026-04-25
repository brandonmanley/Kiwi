import SwiftUI
import SwiftData
import NaturalLanguage
import LaTeXSwiftUI
import SafariServices
import UIKit

struct SearchView: View {
    @Query(sort: \Paper.date, order: .reverse)
    private var papers: [Paper]

    @State private var query: String = ""
    @State private var expandedPaperID: UUID?
    @State private var selectedURL: IdentifiableURL?
    @State private var debouncedQuery: String = ""
    @State private var resultIDs: [UUID] = []
    @State private var searchTask: Task<Void, Never>?

    enum Scope: String, CaseIterable {
        case all = "All"
        case new = "New"
        case cross = "Cross-lists"
        case updates = "Updates"
    }

    @State private var scope: Scope = .all
    @State private var savedOnly: Bool = false

    // ✅ PaperScaffold wants Hashable items
    private struct PaperRowItem: Hashable {
        let id: UUID
        let paper: Paper

        init(_ paper: Paper) {
            self.id = paper.id
            self.paper = paper
        }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: PaperRowItem, rhs: PaperRowItem) -> Bool { lhs.id == rhs.id }
    }

    @MainActor private var items: [PaperRowItem] {
        resultIDs.compactMap { id in
            papers.first(where: { $0.id == id }).map(PaperRowItem.init)
        }
    }

    var body: some View {
        PaperScaffold(
            background: { KiwiColors.creamWhite },
            header: { headerView },
            items: items,
            row: { item in
                paperRow(item.paper)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let id = item.paper.id
                        expandedPaperID = (expandedPaperID == id) ? nil : id
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            item.paper.saved.toggle()
                            Task { @MainActor in
                                let generator = UINotificationFeedbackGenerator()
                                generator.notificationOccurred(item.paper.saved ? .success : .warning)
                            }
                        } label: {
                            Label(item.paper.saved ? "Remove" : "Save",
                                  systemImage: item.paper.saved ? "checkmark" : "plus")
                        }
                        .tint(item.paper.saved ? .gray : .green)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            selectedURL = IdentifiableURL(url: item.paper.url)
                        } label: {
                            Label("arXiv", systemImage: "safari")
                        }
                        .tint(.blue)
                    }
            },
            emptyState: { emptyState },
            bottomOverlay: {
                bottomBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .safeAreaPadding(.bottom)
            }
        )
        .sheet(item: $selectedURL) { wrapper in
            SafariView(url: wrapper.url)
        }
        .navigationBarBackButtonHidden(true)
        .task { scheduleSearch() }
        .onChange(of: debouncedQuery) { _, _ in scheduleSearch() }
        .onChange(of: scope) { _, _ in scheduleSearch() }
        .onChange(of: savedOnly) { _, _ in scheduleSearch() }
        .onChange(of: papers.count) { _, _ in scheduleSearch() } // keeps results in sync after syncPapers
    }


    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 10) {
            KiwiAppNavBar(showReadingListButton: false) {
                Text("Search")
                    .font(.custom("Pulang", size: 22))
                    .foregroundColor(KiwiColors.darkBrown)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.65))

                TextField("Search titles, authors, abstracts…", text: $query)
                    .font(.custom("ArialRoundedMTBold", size: 14))
                    .foregroundColor(KiwiColors.darkBrown)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .onChange(of: query) { _, newValue in
                        let q = newValue
                        Task { @MainActor in
                            // cancel/replace simple debounce
                            try? await Task.sleep(nanoseconds: 160_000_000) // 160ms
                            if query == q { debouncedQuery = q }
                        }
                    }

                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(KiwiColors.darkBrown.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.55)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(KiwiColors.darkBrown.opacity(0.10), lineWidth: 1)
            )
            .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Scope.allCases, id: \.self) { s in
                        Button { scope = s } label: {
                            Text(s.rawValue)
                                .font(.custom("ArialRoundedMTBold", size: 12))
                                .foregroundColor(scope == s ? KiwiColors.creamWhite : KiwiColors.darkBrown)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(scope == s ? KiwiColors.darkGreen : KiwiColors.creamWhite.opacity(0.75))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().frame(height: 18)
                        .overlay(KiwiColors.darkBrown.opacity(0.20))

                    Button { savedOnly.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: savedOnly ? "bookmark.fill" : "bookmark")
                            Text("Saved")
                        }
                        .font(.custom("ArialRoundedMTBold", size: 12))
                        .foregroundColor(savedOnly ? KiwiColors.creamWhite : KiwiColors.darkBrown)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(savedOnly ? KiwiColors.darkBrown : KiwiColors.creamWhite.opacity(0.75))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }
        }
        .padding(.top, 2)
    }
    
    
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            // snapshot query + filters on main
            let q = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentScope = scope
            let saved = savedOnly

            // snapshot lightweight strings on main (SwiftData-safe)
            let snapshot: [(id: UUID, title: String, authors: String, abstract: String, date: Date, saved: Bool, isUpdate: Bool, isCross: Bool)] =
                papers.map { p in
                    (p.id, p.title, p.authors.joined(separator: " "), p.abstract, p.date, p.saved, p.isUpdate, p.isCrosslist)
                }

            // compute off-main
            let ids = await computeResultIDs(snapshot: snapshot, q: q, scope: currentScope, savedOnly: saved)
            if !Task.isCancelled { resultIDs = ids }
        }
    }

    private func computeResultIDs(
        snapshot: [(id: UUID, title: String, authors: String, abstract: String, date: Date, saved: Bool, isUpdate: Bool, isCross: Bool)],
        q: String,
        scope: Scope,
        savedOnly: Bool
    ) async -> [UUID] {
        return await Task.detached(priority: .userInitiated) { () -> [UUID] in
            var base = snapshot

            if savedOnly { base = base.filter { $0.saved } }

            switch scope {
            case .all: break
            case .new: base = base.filter { !$0.isUpdate && !$0.isCross }
            case .cross: base = base.filter { !$0.isUpdate && $0.isCross }
            case .updates: base = base.filter { $0.isUpdate }
            }

            guard !q.isEmpty else {
                return base.sorted(by: { $0.date > $1.date }).map(\.id)
            }

            let scored: [(id: UUID, score: Double, date: Date)] = base.map { p in
                let weights = SearchScorer.Weights()
                let s = SearchScorer.score(
                    title: p.title,
                    authors: p.authors,
                    abstract: p.abstract,
                    query: q,
                    weights: weights
                )
                return (p.id, s, p.date)
            }

            return scored
                .filter { $0.score > 0.0001 }
                .sorted { a, b in
                    if a.score != b.score { return a.score > b.score }
                    return a.date > b.date
                }
                .map(\.id)
        }.value
    }
    
    
    
    // MARK: - Row UI (same feel as PapersForDayView)

    private func paperRow(_ paper: Paper) -> some View {
        let isExpanded = (expandedPaperID == paper.id)

        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    LaTeX(paper.title)
                        .font(.subheadline)
                        .foregroundColor(KiwiColors.darkBrown)
                        .fixedSize(horizontal: false, vertical: true)
                        .parsingMode(.onlyEquations)
                        .allowsHitTesting(false)

                    Spacer()

                    if paper.isUpdate { badge("U", color: .blue) }
                    if paper.isCrosslist { badge("C", color: .orange) }
                }

                HStack(spacing: 4) {
                    let allCats = [paper.primaryCategory] + paper.categories.filter { $0 != paper.primaryCategory }
                    ForEach(Array(allCats.prefix(4).enumerated()), id: \.element) { index, cat in
                        Text(cat.lowercased())
                            .font(.caption2)
                            .foregroundColor(KiwiColors.creamWhite)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(index == 0 ? KiwiColors.darkGreen : KiwiColors.darkBrown)
                            .cornerRadius(4)
                    }
                    if allCats.count > 4 {
                        Text("…")
                            .font(.caption2)
                            .foregroundColor(KiwiColors.darkBrown.opacity(0.6))
                    }
                }

                Text(paper.authors.truncatedAuthors())
                    .font(.caption)
                    .foregroundColor(KiwiColors.darkBrown)
            }

            if isExpanded {
                Divider().background(KiwiColors.darkBrown.opacity(0.25))

                LaTeX(paper.abstract)
                    .font(.caption2)
                    .foregroundColor(KiwiColors.creamWhite)
                    .parsingMode(.onlyEquations)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(KiwiColors.darkGreen)
                    )
                    .allowsHitTesting(false)
            }
        }
        .padding(.vertical, 6)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.custom("Pulang", size: 15))
            .bold()
            .foregroundColor(color)
    }

    // MARK: - Bottom bar / empty state

    private var bottomBar: some View {
        HStack {
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "\(items.count) papers"
                 : "\(items.count) matches")
                .font(.custom("Pulang", size: 14))
                .foregroundColor(KiwiColors.darkBrown)

            Spacer()

            if !query.isEmpty {
                Text("“\(query)”")
                    .font(.custom("ArialRoundedMTBold", size: 12))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.60))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(
            .clear,
            in: .rect(cornerRadius: 16)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Search your saved papers")
                    .font(.custom("ArialRoundedMTBold", size: 20))
                    .foregroundColor(KiwiColors.darkBrown)
            } else {
                Text("No matches")
                    .font(.custom("ArialRoundedMTBold", size: 20))
                    .foregroundColor(KiwiColors.darkBrown)
                Text("Try fewer words or a different phrase.")
                    .font(.custom("ArialRoundedMTBold", size: 14))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.8))
            }
            Spacer()
        }
        .padding(.horizontal)
    }
}

// MARK: - Scoring (Apple NaturalLanguage lemma tokens + phrase bonus)

private enum SearchScorer {}

// The scorer is pure string processing; make it callable from any actor context.
nonisolated(unsafe) extension SearchScorer {
    struct Weights {
        var title: Double = 6.0
        var authors: Double = 3.0
        var abstract: Double = 1.0
        var phraseBonus: Double = 4.0
        var multiHitBonus: Double = 0.35
    }

    static func score(title: String, authors: String, abstract: String, query: String, weights: Weights) -> Double {
        let q = normalizeText(query)
        guard !q.isEmpty else { return 0 }

        let hayAll = normalizeText(title + " " + authors + " " + abstract)
        var score: Double = 0
        if q.count >= 3, hayAll.contains(q) { score += weights.phraseBonus }

        let qTokens = tokenSet(q)
        guard !qTokens.isEmpty else { return score }

        let titleTokens = tokenSet(title)
        let authorTokens = tokenSet(authors)
        let abstractTokens = tokenSet(abstract)

        let titleHits = titleTokens.intersection(qTokens).count
        let authorHits = authorTokens.intersection(qTokens).count
        let abstractHits = abstractTokens.intersection(qTokens).count

        score += Double(titleHits) * weights.title
        score += Double(authorHits) * weights.authors
        score += Double(abstractHits) * weights.abstract

        let distinctHits = Set(titleTokens.union(authorTokens).union(abstractTokens)).intersection(qTokens).count
        if distinctHits > 1 {
            score += Double(distinctHits - 1) * weights.multiHitBonus
        }

        return score
    }

    private static func normalizeText(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenSet(_ text: String) -> Set<String> {
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

