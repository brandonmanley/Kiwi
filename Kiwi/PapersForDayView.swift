import SwiftUI
import SwiftData
import LaTeXSwiftUI
import SafariServices
import UIKit


struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

extension Array where Element == String {
    func truncatedAuthors(maxAuthors: Int = 4) -> String {
        guard !isEmpty else { return "" }

        func normalizeAuthor(_ s: String) -> String {
            // Convert spacing-accent characters to combining marks so NFC
            // composes them onto the previous letter (á, ñ, ç …).
            let combiningMap: [Character: Character] = [
                "\u{00B4}": "\u{0301}", // ´ -> combining acute
                "\u{0060}": "\u{0300}", // ` -> combining grave
                "\u{005E}": "\u{0302}", // ^ -> combining circumflex
                "\u{007E}": "\u{0303}"  // ~ -> combining tilde
            ]

            var out: [Character] = []
            out.reserveCapacity(s.count)

            for ch in s {
                if let combining = combiningMap[ch], !out.isEmpty {
                    out.append(combining)
                } else {
                    out.append(ch)
                }
            }

            return String(out)
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let cleaned = self.map(normalizeAuthor)
        if cleaned.count <= maxAuthors {
            return cleaned.joined(separator: ", ")
        }
        return cleaned.prefix(maxAuthors).joined(separator: ", ") + ", et al"
    }
}

struct PapersForDayView: View {
    let papers: [Paper]
    let day: Date

    @State private var selectedURL: IdentifiableURL?
    @State private var expandedPaperID: Paper.ID?
    @EnvironmentObject private var settingsStore: SettingsStore

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var activeFilter: PaperFilter = .new

    enum PaperFilter: String, CaseIterable {
        case new = "New"
        case crossList = "Cross-lists"
        case updates = "Updates"
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
                KiwiColors.creamWhite
            },
            header: {
                KiwiNavBar(
                    title: {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)
                            .month(.abbreviated)
                            .day()
                            .year()))
                        .font(.custom("Pulang", size: 22))
                        .foregroundColor(KiwiColors.darkBrown)
                    },
                    left: {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 12, height: 16)
                                .padding(10)
                                .background(Circle().fill(KiwiColors.creamWhite))
                                .foregroundColor(KiwiColors.darkBrown)
                        }
                        .buttonStyle(.plain)
                    },
                    right: {
                        ReadingListNavButton()
                    }
                )
            },
            items: filteredPapers,
            row: { paper in
                paperRow(paper)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let isExpanded = (expandedPaperID == paper.id)
                        expandedPaperID = isExpanded ? nil : paper.id
                    }
                    // Same swipe behavior as HomeView
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
            emptyState: {
                emptyState
            },
            bottomOverlay: {
                filterBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .safeAreaPadding(.bottom)
            }
        )
        .sheet(item: $selectedURL) { wrapper in
            SafariView(url: wrapper.url)
        }
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Bottom filter bar (same as HomeView)
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
            Text(letter(for: filter))
                .font(.custom("Pulang", size: 16))
                .frame(width: 32, height: 28)
                .foregroundColor(activeFilter == filter ? KiwiColors.creamWhite : KiwiColors.darkBrown)
                .background(activeFilter == filter ? KiwiColors.darkGreen : Color.clear)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func letter(for filter: PaperFilter) -> String {
        switch filter {
        case .new: return "N"
        case .crossList: return "C"
        case .updates: return "U"
        }
    }

    // MARK: - Row (HomeView style: inline expand abstract)
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
                    Text(paper.authors.truncatedAuthors())
                        .font(.caption)
                        .foregroundColor(KiwiColors.darkBrown)

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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No papers for this day")
                .font(.custom("ArialRoundedMTBold", size: 20))
                .foregroundColor(KiwiColors.darkBrown)

            Text("Try a different day from the calendar.")
                .font(.custom("ArialRoundedMTBold", size: 14))
                .foregroundColor(KiwiColors.darkBrown.opacity(0.8))

            Spacer()
        }
        .padding(.horizontal)
    }
}
