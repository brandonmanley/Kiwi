import SwiftUI

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
                emptyState()
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
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                // Don't let the list scroll/bounce past its content when the
                // rows don't fill the screen — scrolling stops at the bottom.
                .scrollBounceBehavior(.basedOnSize)
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
