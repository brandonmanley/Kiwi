import SwiftUI
import SwiftData
import LaTeXSwiftUI
import Combine
import UIKit

struct HomeView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var syncService: PaperSyncService

    @State private var selectedURL: IdentifiableURL?
    @State private var shareURL: IdentifiableURL?
    @State private var expandedPaperID: Paper.ID?

    // The day boundary the list shows, held in state so it can advance while the
    // app stays alive (crossing local midnight) rather than being frozen at the
    // value baked into the @Query predicate at init.
    @State private var dayStart: Date = Calendar.current.startOfDay(for: Date())

    // One-time hint naming the swipe directions. Persisted so it shows once.
    @AppStorage("hasSeenSwipeHint") private var hasSeenSwipeHint = false

    @State private var activeFilter: PaperFilter = .new

    // Cached filtered + scored order, stored as IDs and resolved against the
    // live @Query results on each render (same pattern as SearchView). Caching
    // avoids re-lemmatizing the whole list when a row expands; caching *IDs*
    // instead of model objects matters: sync deletes papers (pruning), and a
    // cached Paper reference whose backing data is gone crashes on first
    // property access.
    @State private var displayedIDs: [UUID] = []

    private var displayedPapers: [Paper] {
        let byID = Dictionary(uniqueKeysWithValues: papers.map { ($0.id, $0) })
        return displayedIDs.compactMap { byID[$0] }
    }

    @State private var didAttemptAutoFetch = false

    enum PaperFilter: String, CaseIterable {
        case new = "New"
        case crossList = "Cross-lists"
        case updates = "Updates"
    }

    // Reactive query over a rolling recent window (not just "today"): the visible
    // day is narrowed from `dayStart` in `windowPapers`, so the window can advance
    // at midnight without rebuilding the query. Re-evaluates automatically when
    // SwiftData changes (saves, sync, etc.).
    @Query private var papers: [Paper]

    init() {
        let today = Calendar.current.startOfDay(for: Date())
        // Retention prunes to ~30 days; 40 keeps a safe margin in the query while
        // `windowPapers` narrows to the shown day.
        let cutoff = Calendar.current.date(byAdding: .day, value: -40, to: today) ?? today
        _papers = Query(
            filter: #Predicate<Paper> { $0.date >= cutoff },
            sort: [SortDescriptor(\Paper.date, order: .reverse)]
        )
    }

    // The day actually shown: today when it has papers, otherwise the most recent
    // day that does — so Saturday/Sunday aren't blank. The header labels this day.
    private var effectiveDay: Date {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        if papers.contains(where: { $0.date >= dayStart && $0.date < end }) { return dayStart }
        if let latest = papers.first?.date { return cal.startOfDay(for: latest) } // papers sorted desc
        return dayStart
    }

    private var isShowingToday: Bool {
        Calendar.current.isDate(effectiveDay, inSameDayAs: dayStart)
    }

    // Papers for the currently-shown day.
    private var windowPapers: [Paper] {
        let cal = Calendar.current
        let day = effectiveDay
        let end = cal.date(byAdding: .day, value: 1, to: day) ?? day
        return papers.filter { $0.date >= day && $0.date < end }
    }

    private func computeDisplayedIDs() -> [UUID] {
        let base: [Paper]
        switch activeFilter {
        case .new:
            base = windowPapers.filter { !$0.isUpdate && !$0.isCrosslist }
        case .crossList:
            base = windowPapers.filter { !$0.isUpdate && $0.isCrosslist }
        case .updates:
            base = windowPapers.filter { $0.isUpdate }
        }

        let ordered: [Paper]
        if let prepared = TextScorer.prepare(keywords: settingsStore.keywords) {
            TokenCache.shared.evict(keeping: Set(papers.map(\.id)))
            ordered = base
                .map { paper -> (Paper, Double) in
                    let t = TokenCache.shared.tokens(for: paper)
                    let score = TextScorer.score(
                        titleTokens: t.title, authorTokens: t.authors, abstractTokens: t.abstract,
                        haystack: t.haystack, prepared: prepared, weights: .keyword
                    )
                    return (paper, score)
                }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return lhs.0.date > rhs.0.date
                }
                .map(\.0)
        } else {
            ordered = base
        }

        // Papers by followed authors float to the top — a lightweight "section
        // above the general list" without restructuring the flat scaffold.
        let followed = followedAuthorNames
        guard !followed.isEmpty else { return ordered.map(\.id) }
        let byFollowed = ordered.filter { isByFollowedAuthor($0, followed: followed) }
        let rest = ordered.filter { !isByFollowedAuthor($0, followed: followed) }
        return (byFollowed + rest).map(\.id)
    }

    private var followedAuthorNames: [AuthorName] {
        settingsStore.followedAuthors.compactMap(AuthorName.parse)
    }

    private func isByFollowedAuthor(_ paper: Paper, followed: [AuthorName]) -> Bool {
        guard !followed.isEmpty else { return false }
        return paper.authors.contains { authorString in
            guard let parsed = AuthorName.parse(authorString) else { return false }
            return followed.contains { $0.matches(parsed) }
        }
    }


    private var counts: (new: Int, crossList: Int, updates: Int) {
        (
            new: windowPapers.filter { !$0.isUpdate && !$0.isCrosslist }.count,
            crossList: windowPapers.filter { !$0.isUpdate && $0.isCrosslist }.count,
            updates: windowPapers.filter { $0.isUpdate }.count
        )
    }

    private var activeCount: Int {
        switch activeFilter {
        case .new: return counts.new
        case .crossList: return counts.crossList
        case .updates: return counts.updates
        }
    }
    
    
    var body: some View {
        PaperScaffold(
            background: {
                LinearGradient(
                    colors: [KiwiColors.creamWhite, KiwiColors.creamWhite.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            },
            header: {
                VStack(spacing: 8) {
                    KiwiAppNavBar {
                        VStack(spacing: 2) {
                            Text(isShowingToday ? "Today's papers" : effectiveDay.formatted(.dateTime.weekday(.wide)))
                                .font(.custom("Pulang", size: 22, relativeTo: .title))
                                .foregroundColor(KiwiColors.darkBrown)
                            // Always show which listing day is on screen.
                            Text(effectiveDay.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(.system(.caption2, design: .rounded, weight: .medium))
                                .foregroundColor(KiwiColors.darkBrown.opacity(0.6))
                        }
                    }
                    if !hasSeenSwipeHint { swipeHint }
                }
            },
            items: displayedPapers,
            row: { paper in
                paperRow(paper)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        Haptics.impact(.medium, store: settingsStore)
                        shareURL = IdentifiableURL(url: paper.url)
                    }
                    .onTapGesture {
                        let isExpanded = (expandedPaperID == paper.id)
                        expandedPaperID = isExpanded ? nil : paper.id
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            paper.saved.toggle()
                            paper.savedDate = paper.saved ? Date() : nil
                            Haptics.notification(paper.saved ? .success : .warning, store: settingsStore)
                        } label: {
                            Label(paper.saved ? "Remove" : "Save",
                                  systemImage: paper.saved ? "checkmark" : "plus")
                        }
                        .tint(paper.saved ? .gray : .green)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            selectedURL = IdentifiableURL(url: paper.url)
                        } label: {
                            Label("arXiv", systemImage: "safari")
                        }
                        .tint(.blue)

                        Button {
                            selectedURL = IdentifiableURL(url: paper.url.arxivPDF)
                        } label: {
                            Label("PDF", systemImage: "doc.text")
                        }
                        .tint(.purple)
                    }
                    .contextMenu {
                        paperContextMenuItems(
                            saved: paper.saved,
                            onToggleSave: {
                                paper.saved.toggle()
                                paper.savedDate = paper.saved ? Date() : nil
                                Haptics.notification(paper.saved ? .success : .warning, store: settingsStore)
                            },
                            onOpenArxiv: { selectedURL = IdentifiableURL(url: paper.url) },
                            onOpenPDF: { selectedURL = IdentifiableURL(url: paper.url.arxivPDF) },
                            onShare: { shareURL = IdentifiableURL(url: paper.url) },
                            onCopyBibTeX: { UIPasteboard.general.string = Citation.bibtex(for: paper) }
                        )
                    }
            },
            emptyState: { emptyState },
            bottomOverlay: {
                filterBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .safeAreaPadding(.bottom) // keeps it above home indicator
            },
            onRefresh: { await fetchLatestPapers() }
        )
        .task { await autoFetchIfNeeded() }
        .onAppear { displayedIDs = computeDisplayedIDs() }
        .onChange(of: activeFilter) { _, _ in displayedIDs = computeDisplayedIDs() }
        .onChange(of: papers) { _, _ in displayedIDs = computeDisplayedIDs() }
        .onChange(of: dayStart) { _, _ in displayedIDs = computeDisplayedIDs() }
        .onChange(of: settingsStore.keywords) { _, _ in displayedIDs = computeDisplayedIDs() }
        .onChange(of: settingsStore.followedAuthors) { _, _ in displayedIDs = computeDisplayedIDs() }
        // Advance the visible day when the app crosses local midnight while alive.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            dayStart = Calendar.current.startOfDay(for: Date())
        }
        // Returning to the app rolls the day forward and pulls any new batch that
        // landed while backgrounded (e.g. after the 20:00 ET announcement).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            dayStart = Calendar.current.startOfDay(for: Date())
            // Re-arm the one-shot daily summary so it repeats across days.
            if settingsStore.notificationMode == .daily {
                Task { await NotificationManager.scheduleDailySummary() }
            }
            guard settingsStore.hasCompletedOnboarding else { return }
            Task {
                await syncService.autoSync(
                    context: modelContext,
                    categories: settingsStore.selectedCategories
                )
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

    // One-time discoverability hint naming the swipe directions.
    private var swipeHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw")
                .font(.system(size: 13))
                .foregroundColor(KiwiColors.darkBrown.opacity(0.7))
            Text("Swipe left to save · right for arXiv/PDF · long-press to share")
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundColor(KiwiColors.darkBrown.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                withAnimation { hasSeenSwipeHint = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.55))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss hint")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(KiwiColors.creamWhite.opacity(0.85))
        )
        .padding(.horizontal, 14)
    }

    // MARK: - Bottom filter bar (material + transparent)
    private var filterBar: some View {
        HStack {
            HStack(spacing: 10) {
                filterButton(.new)
                filterButton(.crossList)
                filterButton(.updates)
            }

            Spacer()

            Text("\(activeCount) \(activeCount == 1 ? "paper" : "papers")")
                .font(.custom("Pulang", size: 14, relativeTo: .subheadline))
                .foregroundColor(KiwiColors.darkBrown)
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

    private func filterButton(_ filter: PaperFilter) -> some View {
        Button { activeFilter = filter } label: {
            Text(label(for: filter))
                .font(.custom("Pulang", size: 13, relativeTo: .footnote))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .foregroundColor(activeFilter == filter ? KiwiColors.creamWhite : KiwiColors.darkBrown)
                .background(activeFilter == filter ? KiwiColors.darkGreen : Color.clear)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Row
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
                        text: paper.authors.truncatedAuthors(),
                        keywords: settingsStore.keywords
                    )
                    .font(.caption)

                    Spacer()

                    if isByFollowedAuthor(paper, followed: followedAuthorNames) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(KiwiColors.darkGreen)
                            .accessibilityLabel("By an author you follow")
                    }
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

    private func label(for filter: PaperFilter) -> String {
        switch filter {
        case .new: return "New"
        case .crossList: return "Cross"
        case .updates: return "Updates"
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.custom("Pulang", size: 15, relativeTo: .headline))
            .bold()
            .foregroundColor(color)
    }

    private var emptyState: some View {
        // The scaffold wraps this in a refreshable scroll view when onRefresh is
        // set, so this stays plain content. Reached only when there are no papers
        // at all (a day with content is picked up by effectiveDay's fallback).
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundColor(KiwiColors.darkBrown.opacity(0.3))
            Text("No papers yet")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundColor(KiwiColors.darkBrown)
            Text(NetworkManager.friendlyNextAnnouncement())
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundColor(KiwiColors.darkBrown.opacity(0.75))
                .multilineTextAlignment(.center)
            Button {
                Task { await fetchLatestPapers() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(KiwiColors.creamWhite)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(KiwiColors.darkGreen))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }

    // MARK: - Fetch logic

    private func autoFetchIfNeeded() async {
        #if DEBUG
        // Seeded UI-test runs must stay hermetic — no live arXiv traffic.
        if KiwiApp.isUITestSeedRun { return }
        #endif
        // Don't race the onboarding sync: on first launch Home is not shown until
        // onboarding completes, and OnboardingView owns that first fetch.
        guard settingsStore.hasCompletedOnboarding else { return }
        guard !didAttemptAutoFetch else { return }
        didAttemptAutoFetch = true
        await syncService.autoSync(
            context: modelContext,
            categories: settingsStore.selectedCategories
        )
    }

    private func fetchLatestPapers() async {
        // Sync runs on a service-owned unstructured Task — it can't be killed
        // by view dismissal or SwiftUI cancelling the .refreshable closure.
        await syncService.sync(
            context: modelContext,
            categories: settingsStore.selectedCategories
        )
    }
}
