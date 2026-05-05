import SwiftUI

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

    var body: some View {
        ZStack {
            background()
                .ignoresSafeArea()

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
                        }
                    }
                    .frame(height: 3)

                    List(items, id: \.self) { item in
                        row(item)
                            .listRowBackground(Color.clear)
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        let scrollable = geo.contentSize.height - geo.containerSize.height
                        guard scrollable > 0 else { return 0 }
                        return min(max(geo.contentOffset.y / scrollable, 0), 1)
                    } action: { _, newValue in
                        scrollProgress = newValue
                    }
                }
            }

            .safeAreaInset(edge: .bottom) {
                bottomOverlay()
            }
        }
    }
}
