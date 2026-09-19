import SwiftUI
import SwiftData
import NaturalLanguage
import LaTeXSwiftUI
import SafariServices
import UIKit

struct SearchView: View {
    @Query(sort: \Paper.date, order: .reverse)
    private var papers: [Paper]

    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var query: String = ""
    @State private var expandedPaperID: UUID?
    @State private var selectedURL: IdentifiableURL?
    @State private var shareURL: IdentifiableURL?
    @State private var debouncedQuery: String = ""
    @State private var resultIDs: [UUID] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?

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
        let byID = Dictionary(uniqueKeysWithValues: papers.map { ($0.id, $0) })
        return resultIDs.compactMap { byID[$0].map(PaperRowItem.init) }
    }

    // Query words to highlight in results.
    private var queryTerms: [String] {
        query.split(separator: " ").map(String.init).filter { $0.count >= 2 }
    }

    // arXiv web search for the current query — the escape hatch when the local
    // cache has no match.
    private var arxivSearchURL: URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        var components = URLComponents(string: "https://arxiv.org/search/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: q),
            URLQueryItem(name: "searchtype", value: "all"),
        ]
        return components?.url
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
                            item.paper.savedDate = item.paper.saved ? Date() : nil
                            Haptics.notification(item.paper.saved ? .success : .warning, store: settingsStore)
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

                        Button {
                            selectedURL = IdentifiableURL(url: item.paper.url.arxivPDF)
                        } label: {
                            Label("PDF", systemImage: "doc.text")
                        }
                        .tint(.purple)
                    }
                    .contextMenu {
                        paperContextMenuItems(
                            saved: item.paper.saved,
                            onToggleSave: {
                                item.paper.saved.toggle()
                                item.paper.savedDate = item.paper.saved ? Date() : nil
                                Haptics.notification(item.paper.saved ? .success : .warning, store: settingsStore)
                            },
                            onOpenArxiv: { selectedURL = IdentifiableURL(url: item.paper.url) },
                            onOpenPDF: { selectedURL = IdentifiableURL(url: item.paper.url.arxivPDF) },
                            onShare: { shareURL = IdentifiableURL(url: item.paper.url) },
                            onCopyBibTeX: { UIPasteboard.general.string = Citation.bibtex(for: item.paper) }
                        )
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
        .sheet(item: $shareURL) { wrapper in
            ShareSheet(items: [wrapper.url])
                .presentationDetents([.medium])
        }
        .navigationBarBackButtonHidden(true)
        .task { scheduleSearch() }
        .onChange(of: debouncedQuery) { _, _ in scheduleSearch() }
        .onChange(of: scope) { _, _ in scheduleSearch() }
        .onChange(of: savedOnly) { _, _ in scheduleSearch() }
        // Trigger on the papers array itself, not just its count — a sync that
        // replaces/updates rows without changing the count still refreshes results.
        .onChange(of: papers) { _, _ in scheduleSearch() }
    }


    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 10) {
            KiwiAppNavBar(showReadingListButton: false) {
                Text("Search")
                    .font(.custom("Pulang", size: 22, relativeTo: .title))
                    .foregroundColor(KiwiColors.darkBrown)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.65))

                TextField("Search titles, authors, abstracts…", text: $query)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .onChange(of: query) { _, newValue in
                        // Single cancellable debounce task instead of one stacked
                        // task per keystroke.
                        debounceTask?.cancel()
                        debounceTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 160_000_000) // 160ms
                            guard !Task.isCancelled else { return }
                            debouncedQuery = newValue
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
                                .font(.system(.caption, design: .rounded, weight: .medium))
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
                        .font(.system(.caption, design: .rounded, weight: .medium))
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
    
    
    // Lightweight, Sendable per-paper record carrying cached tokens, so scoring
    // can run off the main actor without re-tokenizing.
    private struct SearchDoc: Sendable {
        let id: UUID
        let date: Date
        let saved: Bool
        let isUpdate: Bool
        let isCross: Bool
        let tokens: TokenCache.Tokens
    }

    private func scheduleSearch() {
        searchTask?.cancel()

        let q = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentScope = scope
        let saved = savedOnly

        // Build the snapshot on the main actor, pulling token sets from the cache
        // (cheap after the first build). Live `saved`/`isUpdate` are read here so a
        // save toggles filtering without a full re-tokenize.
        TokenCache.shared.evict(keeping: Set(papers.map(\.id)))
        let docs: [SearchDoc] = papers.map { p in
            SearchDoc(id: p.id, date: p.date, saved: p.saved,
                      isUpdate: p.isUpdate, isCross: p.isCrosslist,
                      tokens: TokenCache.shared.tokens(for: p))
        }

        searchTask = Task { @MainActor in
            let ids = await Self.computeResultIDs(docs: docs, q: q, scope: currentScope, savedOnly: saved)
            if !Task.isCancelled { resultIDs = ids }
        }
    }

    nonisolated private static func computeResultIDs(
        docs: [SearchDoc],
        q: String,
        scope: Scope,
        savedOnly: Bool
    ) async -> [UUID] {
        await Task.detached(priority: .userInitiated) { () -> [UUID] in
            var base = docs

            if savedOnly { base = base.filter { $0.saved } }

            switch scope {
            case .all: break
            case .new: base = base.filter { !$0.isUpdate && !$0.isCross }
            case .cross: base = base.filter { !$0.isUpdate && $0.isCross }
            case .updates: base = base.filter { $0.isUpdate }
            }

            guard !q.isEmpty, let prepared = TextScorer.prepare(query: q) else {
                return base.sorted(by: { $0.date > $1.date }).map(\.id)
            }

            return base
                .map { doc -> (id: UUID, score: Double, date: Date) in
                    let s = TextScorer.score(
                        titleTokens: doc.tokens.title,
                        authorTokens: doc.tokens.authors,
                        abstractTokens: doc.tokens.abstract,
                        haystack: doc.tokens.haystack,
                        prepared: prepared,
                        weights: .search
                    )
                    return (doc.id, s, doc.date)
                }
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
                    MathText(paper.title)
                        .font(.subheadline)
                        .foregroundColor(KiwiColors.darkBrown)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)

                    Spacer()

                    if paper.isUpdate { badge("U", color: .blue) }
                    if paper.isCrosslist { badge("C", color: .orange) }
                }

                HStack(spacing: 4) {
                    let allCats = orderedCategories(primary: paper.primaryCategory, all: paper.categories)
                    ForEach(Array(allCats.prefix(4).enumerated()), id: \.offset) { index, cat in
                        Text(cat)
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

                HStack(alignment: .firstTextBaseline) {
                    KeywordHighlightedText(
                        text: paper.authors.truncatedAuthors(),
                        keywords: queryTerms
                    )
                    .font(.caption)

                    Spacer()

                    if paper.saved {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(KiwiColors.darkGreen)
                            .accessibilityLabel("Saved")
                    }
                }
            }

            if isExpanded {
                Divider().background(KiwiColors.darkBrown.opacity(0.25))

                MathText(paper.abstract)
                    .font(.caption2)
                    .foregroundColor(KiwiColors.creamWhite)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(KiwiColors.darkBrown)
                    )
                    .allowsHitTesting(false)

                ExpandedPaperMeta(
                    arxivID: Citation.arxivID(from: paper.url),
                    submittedDate: paper.submittedDate,
                    listingDate: paper.date,
                    authors: paper.authors,
                    comment: paper.comment,
                    journalRef: paper.journalRef,
                    doi: paper.doi
                )
            }
        }
        .padding(.vertical, 6)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.custom("Pulang", size: 15, relativeTo: .headline))
            .bold()
            .foregroundColor(color)
    }

    // MARK: - Bottom bar / empty state

    private var bottomBar: some View {
        HStack {
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "\(items.count) \(items.count == 1 ? "paper" : "papers")"
                 : "\(items.count) matches")
                .font(.custom("Pulang", size: 14, relativeTo: .subheadline))
                .foregroundColor(KiwiColors.darkBrown)

            Spacer()

            if !query.isEmpty {
                Text("“\(query)”")
                    .font(.system(.caption, design: .rounded, weight: .medium))
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
                // The view searches the whole downloaded cache, not just saved.
                Text("Search all downloaded papers")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown)
                Text("Titles, authors, and abstracts.")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.8))
            } else {
                Text("No matches")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown)
                Text("Nothing in your downloaded papers matches.")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.8))
                if let url = arxivSearchURL {
                    Button {
                        selectedURL = IdentifiableURL(url: url)
                    } label: {
                        Label("Search arXiv", systemImage: "magnifyingglass")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundColor(KiwiColors.creamWhite)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(KiwiColors.darkGreen))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
    }
}


