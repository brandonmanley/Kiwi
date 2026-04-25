import SwiftUI
import SwiftData
import LaTeXSwiftUI

struct ReadingListView: View {
    @State private var selectedURL: IdentifiableURL?
    @State private var expandedPaperID: Paper.ID?

    @Query private var papers: [Paper]
    @Environment(\.modelContext) private var modelContext

    // Saved papers: pinned first, then by date descending
    private var savedPapers: [Paper] {
        papers
            .filter { $0.saved }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.date > b.date
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
                    .onTapGesture {
                        expandedPaperID = (expandedPaperID == paper.id) ? nil : paper.id
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            paper.saved = false
                            paper.pinned = false
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
                    }
            },
            emptyState: { emptyState },
            bottomOverlay: { EmptyView() }
        )
        .sheet(item: $selectedURL) { wrapper in
            SafariView(url: wrapper.url)
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
                Color.clear
                    .frame(width: 44, height: 44)
                    .allowsHitTesting(false)
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
        .listRowBackground(Color.clear)
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
                .font(.custom("ArialRoundedMTBold", size: 18))
            Spacer()
        }
        .padding(.horizontal)
    }
}
