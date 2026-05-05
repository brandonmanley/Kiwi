import SwiftUI
import SwiftData
import LaTeXSwiftUI
import UIKit

struct AuthorView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settingsStore: SettingsStore

    @State private var authorQuery = ""
    @State private var papers: [Paper] = []
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var expandedPaperID: Paper.ID?
    @State private var selectedURL: IdentifiableURL?
    @State private var shareURL: IdentifiableURL?

    var body: some View {
        PaperScaffold(
            background: { KiwiColors.creamWhite },
            header: { headerView },
            items: papers,
            row: { paper in
                paperRow(paper)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        shareURL = IdentifiableURL(url: paper.url)
                    }
                    .onTapGesture {
                        expandedPaperID = (expandedPaperID == paper.id) ? nil : paper.id
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            paper.saved.toggle()
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
                    }
            },
            emptyState: { emptyState },
            bottomOverlay: {
                if hasSearched && !papers.isEmpty {
                    bottomBar
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                        .safeAreaPadding(.bottom)
                }
            }
        )
        .overlay(alignment: .bottom) {
            if isLoading && !papers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(KiwiColors.darkBrown)
                    Text("Fetching more papers…")
                        .font(.custom("ArialRoundedMTBold", size: 12))
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
                    .font(.custom("Pulang", size: 22))
                    .foregroundColor(KiwiColors.darkBrown)
            }

            HStack(spacing: 10) {
                Image(systemName: "person.magnifyingglass")
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.65))

                TextField("Search by author name…", text: $authorQuery)
                    .font(.custom("ArialRoundedMTBold", size: 14))
                    .foregroundColor(KiwiColors.darkBrown)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(true)
                    .submitLabel(.search)
                    .onSubmit { Task { await performSearch() } }

                if !authorQuery.isEmpty {
                    Button {
                        authorQuery = ""
                        papers = []
                        hasSearched = false
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
        }
        .padding(.top, 2)
    }

    // MARK: - Search

    private func performSearch() async {
        let query = authorQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            papers = []
            hasSearched = false
            return
        }

        hasSearched = true

        let local = localPapersByAuthor(query)
        papers = Array(local.prefix(10))

        if local.count >= 10 { return }

        isLoading = true
        let manager = NetworkManager(context: modelContext)
        let fetched = await manager.fetchPapersByAuthor(name: query)
        isLoading = false

        var byURL: [URL: Paper] = [:]
        for paper in local + fetched { byURL[paper.url] = paper }
        papers = Array(byURL.values.sorted { $0.date > $1.date }.prefix(10))
    }

    private func localPapersByAuthor(_ name: String) -> [Paper] {
        let lowered = name.lowercased()
        do {
            let all = try modelContext.fetch(FetchDescriptor<Paper>())
            return all.filter { paper in
                paper.authors.contains { $0.lowercased().contains(lowered) }
            }
            .sorted { $0.date > $1.date }
        } catch {
            return []
        }
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if isLoading {
                RefreshingDotsView()
                    .padding(.bottom, 20)
                Text("Searching arXiv…")
                    .font(.custom("ArialRoundedMTBold", size: 16))
                    .foregroundColor(KiwiColors.darkBrown)
            } else if hasSearched {
                Text("No papers found")
                    .font(.custom("ArialRoundedMTBold", size: 20))
                    .foregroundColor(KiwiColors.darkBrown)
                Text("Try a different author name.")
                    .font(.custom("ArialRoundedMTBold", size: 14))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.8))
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 40))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.3))
                Text("Search for an author")
                    .font(.custom("ArialRoundedMTBold", size: 20))
                    .foregroundColor(KiwiColors.darkBrown)
                Text("Find their latest papers on arXiv.")
                    .font(.custom("ArialRoundedMTBold", size: 14))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.8))
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Text("\(papers.count) papers")
                .font(.custom("Pulang", size: 14))
                .foregroundColor(KiwiColors.darkBrown)

            Spacer()

            if !authorQuery.isEmpty {
                Text("\"\(authorQuery)\"")
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
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { }
    }
}
