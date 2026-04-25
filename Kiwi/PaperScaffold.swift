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

    var body: some View {
        ZStack {
            background()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header()

                if items.isEmpty {
                    emptyState()
                } else {
                    List(items, id: \.self) { item in
                        row(item)
                            .listRowBackground(Color.clear)
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                }
            }

            // Bottom overlay floats above list content
//            VStack {
//                Spacer()
//                bottomOverlay()
//            }
            .safeAreaInset(edge: .bottom) {
                bottomOverlay()
            }
        }
    }
}
