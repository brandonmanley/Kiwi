import SwiftUI
import SwiftData
import LaTeXSwiftUI
import UIKit

enum ReadingListSort: String, CaseIterable {
    case recent = "Recent"
    case title = "Title"
    case author = "Author"
}

enum ReadingListFilter: String, CaseIterable {
    case all = "All"
    case unread = "Unread"
    case pinned = "Pinned"
}

struct ReadingListView: View {
    @State private var selectedURL: IdentifiableURL?
    @State private var shareURL: IdentifiableURL?
    @State private var expandedPaperID: Paper.ID?
    @State private var sortOption: ReadingListSort = .recent
    @State private var filter: ReadingListFilter = .all
    @State private var exportURL: IdentifiableURL?

    @Query private var papers: [Paper]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var uiState: KiwiUIState

    private var savedPapers: [Paper] {
        var saved = papers.filter { $0.saved }
        switch filter {
        case .all: break
        case .unread: saved = saved.filter { !$0.isRead }
        case .pinned: saved = saved.filter { $0.pinned }
        }
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
            header: {
                VStack(spacing: 8) {
                    readingListNavBar
                    filterChips
                }
            },
            items: savedPapers,
            row: { paper in
                paperRow(paper)
                    .contentShape(Rectangle())
                    .onLongPressGesture {
                        Haptics.impact(.medium, store: settingsStore)
                        shareURL = IdentifiableURL(url: paper.url)
                    }
                    .onTapGesture {
                        expandedPaperID = (expandedPaperID == paper.id) ? nil : paper.id
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            removeWithUndo(paper)
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
                    .contextMenu {
                        Button {
                            paper.isRead.toggle()
                            try? modelContext.save()
                        } label: {
                            Label(paper.isRead ? "Mark as unread" : "Mark as read",
                                  systemImage: paper.isRead ? "circle" : "checkmark.circle")
                        }
                        Button {
                            paper.pinned.toggle()
                            try? modelContext.save()
                        } label: {
                            Label(paper.pinned ? "Unpin" : "Pin",
                                  systemImage: paper.pinned ? "pin.slash" : "pin")
                        }
                        paperContextMenuItems(
                            saved: true,
                            onToggleSave: { removeWithUndo(paper) },
                            onOpenArxiv: { selectedURL = IdentifiableURL(url: paper.url) },
                            onOpenPDF: { selectedURL = IdentifiableURL(url: paper.url.arxivPDF) },
                            onShare: { shareURL = IdentifiableURL(url: paper.url) },
                            onCopyBibTeX: { UIPasteboard.general.string = Citation.bibtex(for: paper) }
                        )
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
        .sheet(item: $exportURL) { wrapper in
            ShareSheet(items: [wrapper.url])
        }
        .navigationBarBackButtonHidden(true)
    }

    // Writes the current reading list to a temporary .bib file and hands it to
    // the share sheet.
    private func exportBib() {
        let body = savedPapers.map { Citation.bibtex(for: $0) }.joined(separator: "\n\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiwi-reading-list.bib")
        do {
            try body.data(using: .utf8)?.write(to: url, options: .atomic)
            exportURL = IdentifiableURL(url: url)
        } catch {
            #if DEBUG
            print("⚠️ Failed to write .bib export: \(error)")
            #endif
        }
    }
    
    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(ReadingListFilter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    Text(f.rawValue)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundColor(filter == f ? KiwiColors.creamWhite : KiwiColors.darkBrown)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(filter == f ? KiwiColors.darkGreen : KiwiColors.creamWhite.opacity(0.75))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Custom header with top-right toggle
    private var readingListNavBar: some View {
        KiwiNavBar(
            title: {
                Text("Reading list")
                    .font(.custom("Pulang", size: 22, relativeTo: .title))
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
                    if !savedPapers.isEmpty {
                        Divider()
                        Button {
                            exportBib()
                        } label: {
                            Label("Export reading list (.bib)", systemImage: "square.and.arrow.up")
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
                    // Read papers are dimmed; unread carry a small green dot.
                    MathText(paper.title)
                        .font(.subheadline)
                        .foregroundColor(KiwiColors.darkBrown.opacity(paper.isRead ? 0.5 : 1.0))
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)

                    Spacer()

                    if !paper.isRead {
                        Circle()
                            .fill(KiwiColors.darkGreen)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Unread")
                    }
                    if paper.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(KiwiColors.darkGreen)
                    }
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

                    if let label = daysOnListText(paper) {
                        Text(label)
                            .font(.system(.caption2, design: .rounded, weight: .medium))
                            .foregroundColor(KiwiColors.darkBrown.opacity(0.55))
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

                // Free-text note, persisted as the user types.
                TextField("Add a note…", text: Binding(
                    get: { paper.note },
                    set: { paper.note = $0; try? modelContext.save() }
                ), axis: .vertical)
                .font(.system(.caption, design: .rounded))
                .foregroundColor(KiwiColors.darkBrown)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(KiwiColors.creamWhite.opacity(0.9))
                )
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
    }

    // Full-swipe remove is destructive, so flash an Undo toast that restores the
    // exact saved/pinned/savedDate state. The row is only unsaved, never deleted,
    // so the reference stays valid for the restore closure.
    private func removeWithUndo(_ paper: Paper) {
        let wasPinned = paper.pinned
        let priorSavedDate = paper.savedDate

        paper.saved = false
        paper.pinned = false
        paper.savedDate = nil
        try? modelContext.save()
        Haptics.notification(.warning, store: settingsStore)

        uiState.flashRefreshMessage("Removed from reading list", duration: 4,
            action: .init(label: "Undo") {
                paper.saved = true
                paper.pinned = wasPinned
                paper.savedDate = priorSavedDate ?? Date()
                try? modelContext.save()
            }
        )
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
            .font(.custom("Pulang", size: 15, relativeTo: .headline))
            .bold()
            .foregroundColor(color)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No papers saved yet…")
                .foregroundColor(KiwiColors.darkBrown)
                .font(.system(.headline, design: .rounded, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal)
    }
}
