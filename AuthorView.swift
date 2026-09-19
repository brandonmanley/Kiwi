import SwiftUI
import SwiftData
import LaTeXSwiftUI
import UIKit

struct AuthorView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settingsStore: SettingsStore

    // Where the currently-shown results came from, surfaced in the bottom bar.
    private enum ResultSource: Equatable { case cache, fresh }

    @State private var authorQuery = ""
    // The full matched set; the list shows a windowed prefix (see displayLimit),
    // and an identity selection filters it further.
    @State private var matchedCards: [PaperCard] = []
    @State private var displayLimit = 50
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var loadError = false
    @State private var resultSource: ResultSource = .cache
    @State private var expandedPaperID: PaperCard.ID?
    @State private var selectedURL: IdentifiableURL?
    @State private var shareURL: IdentifiableURL?

    // Distinct people sharing the searched surname; the chip row appears only
    // when clustering found more than one.
    @State private var identities: [AuthorIdentity] = []
    @State private var selectedIdentity: AuthorIdentity?

    @State private var searchTask: Task<Void, Never>?
    @State private var localTask: Task<Void, Never>?

    // MARK: - Derived

    private var filteredCards: [PaperCard] {
        guard let identity = selectedIdentity else { return matchedCards }
        return matchedCards.filter { belongs($0, to: identity) }
    }

    private var displayedCards: [PaperCard] {
        Array(filteredCards.prefix(displayLimit))
    }

    // The single author the star follows: the selected identity, or the sole
    // identity when clustering produced exactly one. Nil when ambiguous.
    private var followableName: String? {
        if let selected = selectedIdentity { return selected.canonical }
        if identities.count == 1 { return identities.first?.canonical }
        return nil
    }

    var body: some View {
        PaperScaffold(
            background: { KiwiColors.creamWhite },
            header: { headerView },
            items: displayedCards,
            row: { card in
                paperRow(card)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        Haptics.impact(.medium, store: settingsStore)
                        shareURL = IdentifiableURL(url: card.url)
                    }
                    .onTapGesture {
                        expandedPaperID = (expandedPaperID == card.id) ? nil : card.id
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            toggleSave(card)
                        } label: {
                            Label(card.saved ? "Remove" : "Save",
                                  systemImage: card.saved ? "checkmark" : "plus")
                        }
                        .tint(card.saved ? .gray : .green)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            selectedURL = IdentifiableURL(url: card.url)
                        } label: {
                            Label("arXiv", systemImage: "safari")
                        }
                        .tint(.blue)

                        Button {
                            selectedURL = IdentifiableURL(url: card.url.arxivPDF)
                        } label: {
                            Label("PDF", systemImage: "doc.text")
                        }
                        .tint(.purple)
                    }
                    .contextMenu {
                        paperContextMenuItems(
                            saved: card.saved,
                            onToggleSave: { toggleSave(card) },
                            onOpenArxiv: { selectedURL = IdentifiableURL(url: card.url) },
                            onOpenPDF: { selectedURL = IdentifiableURL(url: card.url.arxivPDF) },
                            onShare: { shareURL = IdentifiableURL(url: card.url) },
                            onCopyBibTeX: { UIPasteboard.general.string = Citation.bibtex(for: card) }
                        )
                    }
            },
            emptyState: { emptyState },
            bottomOverlay: {
                if hasSearched && !displayedCards.isEmpty {
                    bottomBar
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                        .safeAreaPadding(.bottom)
                }
            }
        )
        .overlay(alignment: .bottom) {
            if isLoading && !displayedCards.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(KiwiColors.darkBrown)
                    Text("Searching arXiv…")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundColor(KiwiColors.darkBrown)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(KiwiColors.creamWhite.opacity(0.85))
                )
                .padding(.bottom, 80)
            }
        }
        .sheet(item: $selectedURL) { wrapper in
            SafariView(url: wrapper.url)
        }
        .sheet(item: $shareURL) { wrapper in
            ShareSheet(items: [wrapper.url])
                .presentationDetents([.medium])
        }
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 10) {
            KiwiAppNavBar {
                Text("Author")
                    .font(.custom("Pulang", size: 22, relativeTo: .title))
                    .foregroundColor(KiwiColors.darkBrown)
            }

            HStack(spacing: 10) {
                Image(systemName: "person.magnifyingglass")
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.65))

                TextField("Search by author name…", text: $authorQuery)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .onSubmit { startSearch() }
                    .onChange(of: authorQuery) { _, _ in scheduleLocalSearch() }

                if !authorQuery.isEmpty {
                    Button {
                        clearSearch()
                    } label: {
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

            // Follow the resolved author (when unambiguous).
            if let name = followableName {
                HStack {
                    Button {
                        settingsStore.toggleFollow(name)
                    } label: {
                        let following = settingsStore.isFollowing(name)
                        HStack(spacing: 6) {
                            Image(systemName: following ? "star.fill" : "star")
                            Text(following ? "Following" : "Follow \(name)")
                        }
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundColor(following ? KiwiColors.creamWhite : KiwiColors.darkBrown)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(following ? KiwiColors.darkGreen : KiwiColors.creamWhite.opacity(0.75))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 14)
            }

            // Disambiguation appears only when clustering actually found more
            // than one distinct person — the common single-identity case (which
            // used to render a confusing two-chip row) shows nothing.
            if identities.count > 1 {
                identityChips
            }
        }
        .padding(.top, 2)
    }

    private var identityChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Which one?")
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundColor(KiwiColors.darkBrown.opacity(0.70))
                .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(identities) { identity in
                        identityChip(identity)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }

    private func identityChip(_ identity: AuthorIdentity) -> some View {
        let isSelected = selectedIdentity == identity
        let count = matchedCards.filter { belongs($0, to: identity) }.count
        let coauthors = topCoauthors(for: identity)

        return Button {
            if isSelected { selectedIdentity = nil }
            else { selectedIdentity = identity }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(identity.isAmbiguous ? "\(identity.canonical) (ambiguous)" : identity.canonical)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundColor(isSelected ? KiwiColors.creamWhite : KiwiColors.darkBrown)
                Text(coauthors.isEmpty ? "\(count) papers" : "\(count) papers · \(coauthors)")
                    .font(.system(.caption2, design: .rounded, weight: .regular))
                    .foregroundColor((isSelected ? KiwiColors.creamWhite : KiwiColors.darkBrown).opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? KiwiColors.darkGreen : KiwiColors.creamWhite.opacity(0.75))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search

    // Cancels a previous submit and always reaches out to arXiv — the old
    // `if local.count >= 25 { skip network }` guard is gone, because that's
    // exactly what made frequently-searched authors go stale.
    private func startSearch() {
        localTask?.cancel()
        searchTask?.cancel()
        searchTask = Task { await performSearch() }
    }

    // Debounced local matching so the field feels responsive while typing; the
    // network query is reserved for explicit submit.
    private func scheduleLocalSearch() {
        localTask?.cancel()
        let query = authorQuery
        localTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await runLocalSearch(query)
        }
    }

    private func clearSearch() {
        localTask?.cancel()
        searchTask?.cancel()
        localTask = nil
        searchTask = nil
        isLoading = false
        authorQuery = ""
        matchedCards = []
        identities = []
        selectedIdentity = nil
        hasSearched = false
        loadError = false
        displayLimit = 50
    }

    @MainActor
    private func runLocalSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = AuthorName.parse(trimmed) else {
            if trimmed.isEmpty { clearSearch() }
            return
        }
        hasSearched = true
        loadError = false
        resultSource = .cache
        matchedCards = localCards(matching: target)
        rebuildIdentities()
    }

    private func performSearch() async {
        let query = authorQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = AuthorName.parse(query) else {
            clearSearch()
            return
        }

        hasSearched = true
        selectedIdentity = nil
        loadError = false
        displayLimit = 50
        settingsStore.addRecentAuthorSearch(query)

        // Show local matches immediately, then augment from the network.
        matchedCards = localCards(matching: target)
        rebuildIdentities()

        isLoading = true
        defer { isLoading = false }

        do {
            let manager = NetworkManager(context: modelContext)
            let cards = try await manager.fetchPapersByAuthor(name: query)
            if Task.isCancelled { return }
            matchedCards = cards
            resultSource = .fresh
            rebuildIdentities()
        } catch {
            if Task.isCancelled { return }
            // Keep whatever local matches we already showed, but flag the failure
            // so the empty/retry state can distinguish it from a true empty.
            loadError = true
        }
    }

    private func localCards(matching target: AuthorName) -> [PaperCard] {
        let all = (try? modelContext.fetch(FetchDescriptor<Paper>())) ?? []
        return all
            .filter { paper in
                paper.authors.contains { AuthorName.parse($0).map { target.matches($0) } ?? false }
            }
            .map(PaperCard.init)
            .sorted { $0.sortDate > $1.sortDate }
    }

    private func rebuildIdentities() {
        guard let target = AuthorName.parse(authorQuery) else {
            identities = []
            return
        }
        // Cluster only the author strings that match the query (the person being
        // searched), not every co-author on every paper.
        let relevant = matchedCards
            .flatMap { $0.authors }
            .filter { AuthorName.parse($0).map { target.matches($0) } ?? false }
        identities = AuthorName.cluster(relevant)
        if let selected = selectedIdentity, !identities.contains(selected) {
            selectedIdentity = nil
        }
    }

    private func belongs(_ card: PaperCard, to identity: AuthorIdentity) -> Bool {
        card.authors.contains { identity.variants.contains($0) }
    }

    private func topCoauthors(for identity: AuthorIdentity, limit: Int = 2) -> String {
        var counts: [String: Int] = [:]
        for card in matchedCards where belongs(card, to: identity) {
            for author in card.authors where !identity.variants.contains(author) {
                counts[author, default: 0] += 1
            }
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(limit).map { surnameOf($0.key) }
        return top.joined(separator: ", ")
    }

    private func surnameOf(_ raw: String) -> String {
        AuthorName.parse(raw)?.lastName.capitalized ?? raw
    }

    // MARK: - Save

    private func toggleSave(_ card: PaperCard) {
        let paper = resolvePaper(for: card)
        paper.saved.toggle()
        paper.savedDate = paper.saved ? Date() : nil
        try? modelContext.save()
        Haptics.notification(paper.saved ? .success : .warning, store: settingsStore)

        // Reflect the change in the value-type cards so the row re-renders.
        updateCard(card.dedupKey) {
            $0.saved = paper.saved
            $0.storedID = paper.persistentModelID
        }
    }

    // Finds the backing row (by persistent id, then by dedup key), inserting a
    // new one only when the author result isn't already stored.
    private func resolvePaper(for card: PaperCard) -> Paper {
        if let id = card.storedID, let existing = modelContext.model(for: id) as? Paper {
            return existing
        }
        let all = (try? modelContext.fetch(FetchDescriptor<Paper>())) ?? []
        if let existing = all.first(where: { arxivDedupKey(for: $0.url) == card.dedupKey }) {
            return existing
        }
        let paper = Paper(
            title: card.title,
            authors: card.authors,
            abstract: card.abstract,
            url: card.url,
            categories: card.categories,
            primaryCategory: card.primaryCategory,
            date: NetworkManager.announcementDate(from: card.updatedDate ?? card.submittedDate ?? Date()),
            isUpdate: card.isUpdate,
            isCrosslist: card.isCrosslist
        )
        modelContext.insert(paper)
        return paper
    }

    private func updateCard(_ dedupKey: String, _ mutate: (inout PaperCard) -> Void) {
        if let idx = matchedCards.firstIndex(where: { $0.dedupKey == dedupKey }) {
            mutate(&matchedCards[idx])
        }
    }

    // MARK: - Row

    private func paperRow(_ card: PaperCard) -> some View {
        let isExpanded = (expandedPaperID == card.id)

        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    MathText(card.title)
                        .font(.subheadline)
                        .foregroundColor(KiwiColors.darkBrown)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)

                    Spacer()

                    if card.isUpdate { badge("U", color: .blue) }
                    if card.isCrosslist { badge("C", color: .orange) }
                }

                HStack(spacing: 4) {
                    let allCats = orderedCategories(primary: card.primaryCategory, all: card.categories)
                    ForEach(Array(allCats.enumerated()), id: \.offset) { index, cat in
                        Text(cat)
                            .font(.caption2)
                            .foregroundColor(KiwiColors.creamWhite)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(index == 0 ? KiwiColors.darkGreen : KiwiColors.darkBrown)
                            .cornerRadius(4)
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    KeywordHighlightedText(
                        text: card.authors.truncatedAuthors(),
                        keywords: settingsStore.keywords
                    )
                    .font(.caption)

                    Spacer()

                    if card.saved {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(KiwiColors.darkGreen)
                            .accessibilityLabel("Saved")
                    }
                }
            }

            if isExpanded {
                Divider().background(KiwiColors.darkBrown.opacity(0.25))

                MathText(card.abstract)
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
                    arxivID: Citation.arxivID(from: card.url),
                    submittedDate: card.submittedDate,
                    listingDate: card.sortDate,
                    authors: card.authors,
                    comment: card.comment,
                    journalRef: card.journalRef,
                    doi: card.doi
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if isLoading {
                ProgressView()
                    .tint(KiwiColors.darkBrown)
                    .padding(.bottom, 20)
                Text("Searching arXiv…")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown)
            } else if loadError {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.35))
                Text("Couldn't reach arXiv")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown)
                Button { startSearch() } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundColor(KiwiColors.creamWhite)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(KiwiColors.darkGreen))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            } else if hasSearched {
                Text("No papers found")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown)
                Text("Try a different author name.")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.8))
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 40))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.3))
                Text("Search for an author")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown)
                Text("Find their latest papers on arXiv.")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.8))

                if !settingsStore.recentAuthorSearches.isEmpty {
                    recentSearches.padding(.top, 12)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.6))
                Spacer()
                Button {
                    settingsStore.clearRecentAuthorSearches()
                } label: {
                    Text("Clear")
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundColor(KiwiColors.darkBrown.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(settingsStore.recentAuthorSearches, id: \.self) { q in
                        Button {
                            authorQuery = q
                            startSearch()
                        } label: {
                            Text(q)
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundColor(KiwiColors.darkBrown)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(KiwiColors.creamWhite.opacity(0.75))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // "Showing X of N" with a load-more control so the previously-unread
            // overflow (the old `allResults`) is now reachable.
            if filteredCards.count > displayedCards.count {
                Button {
                    displayLimit += 50
                } label: {
                    Text("Showing \(displayedCards.count) of \(filteredCards.count) — load more")
                        .font(.custom("Pulang", size: 14, relativeTo: .subheadline))
                        .foregroundColor(KiwiColors.darkGreen)
                }
                .buttonStyle(.plain)
            } else {
                Text("\(filteredCards.count) \(filteredCards.count == 1 ? "paper" : "papers")")
                    .font(.custom("Pulang", size: 14, relativeTo: .subheadline))
                    .foregroundColor(KiwiColors.darkBrown)
            }

            Spacer()

            Text(resultSource == .fresh ? "arXiv" : "cached")
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundColor(KiwiColors.darkBrown.opacity(0.55))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(
            .clear,
            in: .rect(cornerRadius: 16)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { }
    }
}
