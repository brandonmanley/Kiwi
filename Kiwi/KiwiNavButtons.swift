import SwiftUI

struct SideMenuButton: View {
    @EnvironmentObject private var uiState: KiwiUIState

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                uiState.isMenuOpen.toggle()
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 16)
                .padding(10)
                .background(Circle().fill(KiwiColors.creamWhite))
//                .overlay(Circle().stroke(KiwiColors.creamWhite, lineWidth: 1))
                .foregroundColor(KiwiColors.darkBrown)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open menu")
    }
}

struct ReadingListNavButton: View {
    @EnvironmentObject private var router: KiwiRouter

    var body: some View {
        Button {
            router.go(.readingList)
        } label: {
            Image(systemName: "book.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .padding(10)
                .background(Circle().fill(KiwiColors.creamWhite))
//                .overlay(Circle().stroke(KiwiColors.lightGreen, lineWidth: 1))
                .foregroundColor(KiwiColors.darkBrown)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reading list")
    }
}
