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
                .foregroundColor(KiwiColors.darkBrown)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open menu")
    }
}

struct RefreshingDotsView: View {
    @State private var dotCount = 1

    var body: some View {
        Text(String(repeating: ".", count: dotCount))
            .font(.custom("ArialRoundedMTBold", size: 28))
            .foregroundColor(KiwiColors.darkBrown)
            .frame(width: 40)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    dotCount = dotCount % 3 + 1
                }
            }
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
                .foregroundColor(KiwiColors.darkBrown)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reading list")
    }
}
