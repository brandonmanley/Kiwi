import SwiftUI

struct KiwiAppNavBar<Title: View>: View {
    let title: Title
    var showReadingListButton: Bool = true

    init(showReadingListButton: Bool = true, @ViewBuilder title: () -> Title) {
        self.title = title()
        self.showReadingListButton = showReadingListButton
    }

    var body: some View {
        KiwiNavBar(
            title: { title },
            left: { SideMenuButton() },
            right: {
                if showReadingListButton {
                    ReadingListNavButton()
                } else {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .allowsHitTesting(false)
                }
            }
        )
    }
}


struct KiwiNavBar<Title: View, Left: View, Right: View>: View {
    let title: Title
    let left: Left
    let right: Right

    init(
        @ViewBuilder title: () -> Title,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        self.title = title()
        self.left = left()
        self.right = right()
    }

    var body: some View {
        HStack {
            left
                .frame(width: 44, height: 44, alignment: .leading)

            Spacer()

            title

            Spacer()

            Group {
                right
                    .opacity(1)
            }
            .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(KiwiColors.creamWhite)
    }
}


