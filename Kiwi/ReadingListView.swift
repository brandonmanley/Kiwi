import SwiftUI
import SwiftData
import LaTeXSwiftUI
import UIKit

enum ReadingListSort: String, CaseIterable {
    case recent = "Recent"
    case title = "Title"
    case author = "Author"
}

struct ReadingListView: View {
    @State private var selectedURL: IdentifiableURL?
    @State private var shareURL: IdentifiableURL?
    @State private var expandedPaperID: Paper.ID?
    @State private var sortOption: ReadingListSort = .recent

    @Query private var papers: [Paper]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settingsStore: SettingsStore

    private var savedPapers: [Paper] {
        let saved = papers.filter { $0.saved }
        switch sortOption {
        case .recent:
            return saved.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return (a.savedDate ?? a.date) > (b.savedDate ?? b.date)
            }
        case .title:
            return saved.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        case .author:
            return saved.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return (a.authors.first ?? "").localizedCaseInsensitiveCompare(b.authors.first ?? "") == .orderedAscending
            }
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
            header: { readingListNavBar },
            items: savedPapers,
            row: { paper in
                paperRow(paper)
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        shareURL = IdentifiableURL(url: paper.url)
                    }
                    .onTapGesture {
                        expandedPaperID = (expandedPaperID == paper.id) ? nil : paper.id
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            paper.saved = false
                            paper.pinned = false
                            paper.savedDate = nil
                        } label: {
                            Label("Remove", systemImage: "minus")
                        }

                        Button {
                            paper.pinned.toggle()
                        } label: {
                            Label(paper.pinned ? "Unpin" : "Pin",
                                  systemImage: paper.pinned ? "pin.slash" : "pin")
                        }
                        .tint(paper.pinned ? .gray : .orange)
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
            bottomOverlay: { EmptyView() }
        )
        .sheet(item: $selectedURL) { wrapper in
            SafariView(url: wrapper.url)
        }
        .sheet(item: $shareURL) { wrapper in
            ShareSheet(items: [wrapper.url])
                .presentationDetents([.medium])
        }
        .navigationBarBackButtonHidden(true)
    }
    
    // MARK: - Custom header with top-right toggle
    private var readingListNavBar: some View {
        KiwiNavBar(
            title: {
                Text("Reading list")
                    .font(.custom("Pulang", size: 22))
                    .foregroundColor(KiwiColors.darkBrown)
            },
            left: { SideMenuButton() },
            right: {
                Menu {
                    ForEach(ReadingListSort.allCases, id: \.self) { option in
                        Button {
                            sortOption = option
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                if sortOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(KiwiColors.darkBrown)
                        .frame(width: 44, height: 44)
                }
            }
        )
    }

    // MARK: - Row (HomeView style)
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

                    if paper.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(KiwiColors.darkGreen)
                    }
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

                    if let label = daysOnListText(paper) {
                        Text(label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(KiwiColors.darkBrown.opacity(0.55))
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
        .listRowBackground(Color.clear)
    }

    private func daysOnListText(_ paper: Paper) -> String? {
        guard let savedDate = paper.savedDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: savedDate, to: Date()).day ?? 0
        if days == 0 { return "Added today" }
        if days == 1 { return "1 day on list" }
        return "\(days) days on list"
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.custom("Pulang", size: 15))
            .bold()
            .foregroundColor(color)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No papers saved yet…")
                .foregroundColor(KiwiColors.darkBrown)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal)
    }
}
