import SwiftUI
import LaTeXSwiftUI

// Most arXiv titles and abstracts contain no math, yet routing every one through
// LaTeX spins up MathJax/JavaScriptCore. MathText renders plain `Text` when there
// are no math delimiters and only falls through to LaTeX (equation-only parsing)
// when there are. Outer modifiers (.font, .foregroundColor, …) apply to either
// branch via the environment, so call sites drop only `.parsingMode`.
struct MathText: View {
    private let content: String

    init(_ content: String) { self.content = content }

    private var containsMath: Bool {
        content.contains("$") || content.contains("\\(")
            || content.contains("\\[") || content.contains("\\begin{")
    }

    var body: some View {
        if containsMath {
            LaTeX(content).parsingMode(.onlyEquations)
        } else {
            Text(content)
        }
    }
}

// Shared context-menu content mirroring the swipe actions, so those actions
// (and Copy BibTeX) are discoverable and reachable by VoiceOver. Reading list
// adds Pin/Unpin on top of this.
@ViewBuilder
func paperContextMenuItems(
    saved: Bool,
    onToggleSave: @escaping () -> Void,
    onOpenArxiv: @escaping () -> Void,
    onOpenPDF: @escaping () -> Void,
    onShare: @escaping () -> Void,
    onCopyBibTeX: @escaping () -> Void
) -> some View {
    Group {
        Button(action: onToggleSave) {
            Label(saved ? "Remove from reading list" : "Save",
                  systemImage: saved ? "checkmark" : "plus")
        }
        Button(action: onOpenArxiv) { Label("Open on arXiv", systemImage: "safari") }
        Button(action: onOpenPDF) { Label("Open PDF", systemImage: "doc.text") }
        Button(action: onShare) { Label("Share", systemImage: "square.and.arrow.up") }
        Button(action: onCopyBibTeX) { Label("Copy BibTeX", systemImage: "text.quote") }
    }
}

// Extra detail shown in an expanded row: arXiv identifier, submission + listing
// dates, the full untruncated author list, and comment/journalRef/doi when known.
struct ExpandedPaperMeta: View {
    let arxivID: String
    var submittedDate: Date? = nil
    let listingDate: Date
    let authors: [String]
    var comment: String? = nil
    var journalRef: String? = nil
    var doi: String? = nil

    private func dateString(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("arXiv:\(arxivID)")
                Spacer()
                if let submittedDate {
                    Text("Submitted \(dateString(submittedDate)) · Listed \(dateString(listingDate))")
                } else {
                    Text(dateString(listingDate))
                }
            }
            .font(.system(.caption2, design: .rounded, weight: .medium))
            .foregroundColor(KiwiColors.darkBrown.opacity(0.6))

            if let journalRef, !journalRef.isEmpty { metaLine("Journal", journalRef) }
            if let doi, !doi.isEmpty { metaLine("DOI", doi) }
            if let comment, !comment.isEmpty { metaLine("Comment", comment) }

            if !authors.isEmpty {
                Text(authors.joined(separator: ", "))
                    .font(.system(.caption2, design: .rounded, weight: .regular))
                    .foregroundColor(KiwiColors.darkBrown.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private func metaLine(_ label: String, _ value: String) -> some View {
        (Text("\(label): ").bold() + Text(value))
            .font(.system(.caption2, design: .rounded, weight: .regular))
            .foregroundColor(KiwiColors.darkBrown.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
}

struct PaperScaffold<
    Background: View,
    Header: View,
    RowItem: Hashable,
    Row: View,
    Empty: View,
    BottomOverlay: View
>: View {

    @ViewBuilder let background: () -> Background
    @ViewBuilder let header: () -> Header
    let items: [RowItem]
    @ViewBuilder let row: (RowItem) -> Row
    @ViewBuilder let emptyState: () -> Empty
    @ViewBuilder let bottomOverlay: () -> BottomOverlay
    // When provided, both the populated list and the empty state become
    // pull-to-refreshable. Views with nothing to fetch from the network
    // (Search, Author, Reading list) leave this nil.
    var onRefresh: (() async -> Void)? = nil

    @State private var scrollProgress: CGFloat = 0
    @State private var lastMetrics: ScrollMetrics = ScrollMetrics(offset: 0, contentHeight: 0, containerHeight: 0)

    var body: some View {
        ZStack {
            background()
                .ignoresSafeArea()

            // safeAreaInset(edge:.bottom) with an EmptyView overlay corrupts the
            // List's scrollable range — content can scroll a full screen past its
            // end (seen on the reading list, which passes EmptyView). Only apply
            // the inset when there is a real overlay.
            if BottomOverlay.self == EmptyView.self {
                content
            } else {
                content
                    .safeAreaInset(edge: .bottom) {
                        bottomOverlay()
                    }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header()

            if items.isEmpty {
                if onRefresh != nil {
                    // Wrap in a full-height scroll view so the pull gesture works
                    // even when the empty state's own content is short.
                    GeometryReader { geo in
                        ScrollView {
                            emptyState()
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                        .scrollIndicators(.hidden)
                        .applyRefreshable(onRefresh)
                    }
                } else {
                    emptyState()
                }
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(KiwiColors.darkBrown.opacity(0.1))
                        Rectangle()
                            .fill(KiwiColors.darkGreen)
                            .frame(width: geo.size.width * scrollProgress)
                            .animation(.easeOut(duration: 0.15), value: scrollProgress)
                    }
                }
                .frame(height: 3)

                List(items, id: \.self) { item in
                    row(item)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(KiwiColors.darkBrown.opacity(0.35))
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                // Don't let the list scroll/bounce past its content when the
                // rows don't fill the screen — scrolling stops at the bottom.
                .scrollBounceBehavior(.basedOnSize)
                .applyRefreshable(onRefresh)
                .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                    ScrollMetrics(
                        offset: geo.contentOffset.y,
                        contentHeight: geo.contentSize.height,
                        containerHeight: geo.containerSize.height
                    )
                } action: { _, new in
                    updateScrollProgress(new)
                }
            }
        }
    }

    private func updateScrollProgress(_ new: ScrollMetrics) {
        // If the content size changed but offset did not, the user is expanding/
        // collapsing a row — keep the progress bar where it is to avoid jumps.
        let contentResized = abs(new.contentHeight - lastMetrics.contentHeight) > 1
            || abs(new.containerHeight - lastMetrics.containerHeight) > 1
        let offsetChanged = abs(new.offset - lastMetrics.offset) > 0.5

        lastMetrics = new

        guard offsetChanged || !contentResized else { return }

        let scrollable = new.contentHeight - new.containerHeight
        guard scrollable > 0 else {
            scrollProgress = 0
            return
        }
        scrollProgress = min(max(new.offset / scrollable, 0), 1)
    }
}

private extension View {
    // Installs `.refreshable` only when an action is provided, so views that
    // pass nil don't show a pull gesture that does nothing.
    @ViewBuilder
    func applyRefreshable(_ action: (() async -> Void)?) -> some View {
        if let action {
            self.refreshable { await action() }
        } else {
            self
        }
    }
}
