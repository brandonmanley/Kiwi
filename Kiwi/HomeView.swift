import SwiftUI
import SwiftData
import LaTeXSwiftUI
import Combine

struct HomeView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var selectedURL: IdentifiableURL?
    @State private var shareURL: IdentifiableURL?
    @State private var expandedPaperID: Paper.ID?

    @State private var activeFilter: PaperFilter = .new

    @State private var hasFetchedToday = false
    private let lastFetchKey = "lastArxivFetchDate"
    @State private var refreshMessage: String = ""
    @State private var showRefreshMessage = false
    @State private var refreshMessageTask: Task<Void, Never>?
    @State private var isRefreshing = false

    enum PaperFilter: String, CaseIterable {
        case new = "New"
        case crossList = "Cross-lists"
        case updates = "Updates"
    }

    // Reactive query: today's papers, sorted by date desc.
    // Re-evaluates automatically when SwiftData changes (saves, sync, etc.).
    @Query private var papers: [Paper]

    init() {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        _papers = Query(
            filter: #Predicate<Paper> { $0.date >= start && $0.date < end },
            sort: [SortDescriptor(\Paper.date, order: .reverse)]
        )
    }

    private var filteredPapers: [Paper] {
        let base: [Paper]
        switch activeFilter {
        case .new:
            base = papers.filter { !$0.isUpdate && !$0.isCrosslist }
        case .crossList:
            base = papers.filter { !$0.isUpdate && $0.isCrosslist }
        case .updates:
            base = papers.filter { $0.isUpdate }
        }

        guard let prepared = KeywordScorer.prepare(keywords: settingsStore.keywords) else { return base }

        return base
            .map { ($0, KeywordScorer.score(paper: $0, prepared: prepared)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.date > rhs.0.date
            }
            .map(\.0)
    }
    

    private var counts: (new: Int, crossList: Int, updates: Int) {
        (
            new: papers.filter { !$0.isUpdate && !$0.isCrosslist }.count,
            crossList: papers.filter { !$0.isUpdate && $0.isCrosslist }.count,
            updates: papers.filter { $0.isUpdate }.count
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
                KiwiAppNavBar {
                    Text("Today's papers")
                        .font(.custom("Pulang", size: 22))
                        .foregroundColor(KiwiColors.darkBrown)
                }
            },
            items: filteredPapers,
            row: { paper in
                paperRow(paper)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                            UINotificationFeedbackGenerator()
                                .notificationOccurred(paper.saved ? .success : .warning)
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
            },
            emptyState: { emptyState },
            bottomOverlay: {
                filterBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .safeAreaPadding(.bottom) // keeps it above home indicator
            }
        )
        .task { await autoFetchIfNeeded() }
        .sheet(item: $selectedURL) { wrapper in
            SafariView(url: wrapper.url)
        }
        .sheet(item: $shareURL) { wrapper in
            ShareSheet(items: [wrapper.url])
                .presentationDetents([.medium])
        }
        .navigationBarBackButtonHidden(true)
        .overlay(alignment: .bottom) {
            if showRefreshMessage {
                Text(refreshMessage)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(KiwiColors.darkBrown)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(KiwiColors.creamWhite.opacity(0.85))
                    )
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
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

            Text("\(activeCount) papers")
                .font(.custom("Pulang", size: 14))
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
                .font(.custom("Pulang", size: 13))
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
                    ForEach(Array(allCats.enumerated()), id: \.element) { index, cat in
                        Text(cat.lowercased())
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

                LaTeX(paper.abstract)
                    .font(.caption2)
                    .foregroundColor(KiwiColors.creamWhite)
                    .parsingMode(.onlyEquations)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(KiwiColors.darkBrown)
                    )
                    .allowsHitTesting(false)
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
            .font(.custom("Pulang", size: 15))
            .bold()
            .foregroundColor(color)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 10) {
                if isRefreshing {
                    RefreshingDotsView()
                        .padding(.top, 40)
                }

                Spacer(minLength: isRefreshing ? 100 : 140)

                Text("No papers for today yet")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(KiwiColors.darkBrown)

                Spacer(minLength: 400)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            isRefreshing = true
            await fetchLatestPapers()
            isRefreshing = false
        }
        .tint(.clear)
    }

    // MARK: - Fetch logic
    private func autoFetchIfNeeded() async {
        guard !hasFetchedToday else { return }

        let today = Calendar.current.startOfDay(for: Date())
        let lastFetchDay = (UserDefaults.standard.object(forKey: lastFetchKey) as? Date)
            .map(Calendar.current.startOfDay)

        if lastFetchDay == nil || lastFetchDay! < today {
            await fetchLatestPapers()
            UserDefaults.standard.set(Date(), forKey: lastFetchKey)
        }

        hasFetchedToday = true
    }

    private func fetchLatestPapers() async {
        let categories = settingsStore.selectedCategories
        guard !categories.isEmpty else {
            flashRefreshMessage("Choose categories in Settings")
            return
        }

        let manager = NetworkManager(context: modelContext)
        let result = await manager.syncPapers(for: categories)

        guard !result.cancelled else { return }
        if result.added > 0 {
            flashRefreshMessage("Added \(result.added) papers!")
        } else {
            flashRefreshMessage("Up to date — \(NetworkManager.friendlyNextAnnouncement())")
        }
    }

    private func flashRefreshMessage(_ message: String) {
        refreshMessageTask?.cancel()
        refreshMessage = message
        withAnimation { showRefreshMessage = true }
        refreshMessageTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showRefreshMessage = false }
        }
    }
}
