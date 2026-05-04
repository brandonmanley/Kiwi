import SwiftUI
import SwiftData

struct DailyPapersView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settingsStore: SettingsStore

    @Query(sort: \Paper.date, order: .reverse)
    private var papers: [Paper]

    @State private var isRefreshing = false

    private static let dayCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }()

    // MARK: - Group papers by day (last 7 days only)
    private var days: [(day: Date, papers: [Paper])] {
        let cal = Self.dayCalendar
        let cutoff = cal.startOfDay(for: cal.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        let grouped = Dictionary(grouping: papers.filter { $0.date >= cutoff }) { cal.startOfDay(for: $0.date) }
        return grouped
            .map { (day: $0.key, papers: $0.value) }
            .sorted { $0.day > $1.day }
    }

    // Normalized once per render; rows do an O(1) lookup.
    private var clickedDaySet: Set<Date> {
        let cal = Self.dayCalendar
        return Set(settingsStore.clickedDays.map(cal.startOfDay))
    }

    private func refreshDailyPapers() async {
        let categories = settingsStore.selectedCategories
        guard !categories.isEmpty else { return }
        let manager = NetworkManager(context: modelContext)
        await manager.syncPapers(for: categories)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [KiwiColors.creamWhite, KiwiColors.creamWhite.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                KiwiAppNavBar {
                    Text("Daily papers")
                        .font(.custom("Pulang", size: 22))
                        .foregroundColor(KiwiColors.darkBrown)
                }

                if days.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        Text("No papers to show")
                            .font(.custom("ArialRoundedMTBold", size: 20))
                            .foregroundColor(KiwiColors.darkBrown)
                        Text("Pull to refresh, or update categories in Settings.")
                            .font(.custom("ArialRoundedMTBold", size: 14))
                            .foregroundColor(KiwiColors.darkBrown.opacity(0.75))
                        Spacer()
                    }
                    .padding(.horizontal)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if isRefreshing {
                                RefreshingDotsView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            ForEach(days, id: \.day) { entry in
                                NavigationLink {
                                    PapersForDayView(papers: entry.papers, day: entry.day)
                                } label: {
                                    DayShelfRow(
                                        day: entry.day,
                                        paperCount: entry.papers.count,
                                        clicked: clickedDaySet.contains(entry.day)
                                    )
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(TapGesture().onEnded {
                                    settingsStore.markDayClicked(entry.day)
                                })
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 18)
                    }
                    .refreshable {
                        isRefreshing = true
                        await refreshDailyPapers()
                        isRefreshing = false
                    }
                    .tint(.clear)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

// MARK: - Shelf Row

private struct DayShelfRow: View {
    let day: Date
    let paperCount: Int
    let clicked: Bool

    private var booksCount: Int { Self.booksForCount(paperCount, maxBooks: 16) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            shelfView
                .frame(height: 54)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.wide)))
                        .font(.custom("Pulang", size: 16))
                        .foregroundColor(KiwiColors.darkBrown)

                    Text(day.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.custom("ArialRoundedMTBold", size: 12))
                        .foregroundColor(KiwiColors.darkBrown.opacity(0.70))
                }

                Spacer()

                Text("\(paperCount) papers")
                    .font(.custom("Pulang", size: 14))
                    .foregroundColor(KiwiColors.darkBrown.opacity(clicked ? 0.65 : 0.90))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(KiwiColors.creamWhite.opacity(0.70))
        )
    }

    private var shelfView: some View {
        ZStack(alignment: .bottomLeading) {
            // Shelf line
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(KiwiColors.darkBrown.opacity(0.35))
                .frame(height: 3)
                .offset(y: 2)
                .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)

            // Books
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(0..<booksCount, id: \.self) { i in
                    bookSpine(index: i)
                }
            }
            .padding(.leading, 6)
            .padding(.bottom, 6)
        }
    }

    private func bookSpine(index i: Int) -> some View {
        let baseFill = clicked ?  KiwiColors.creamWhite : KiwiColors.darkGreen
        let outline = KiwiColors.darkBrown.opacity(clicked ? 0.25 : 0.35)

        let h = CGFloat(28 + (i * 7 % 20))          // 28..47
        let w = CGFloat(10 + (i * 5 % 6))           // 10..15

        // keep transform always finite + small
        let tilt = Double(((i * 13) % 5) - 2)       // -2..+2

        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(baseFill)
            .frame(width: w, height: h)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(outline, lineWidth: 1)
            )
            // Pages on right edge
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.70),
                                Color.white.opacity(0.35)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: max(2, w * 0.18))
                    .overlay(
                        VStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { _ in
                                Rectangle()
                                    .fill(KiwiColors.darkBrown.opacity(0.10))
                                    .frame(height: 1)
                                    .padding(.horizontal, 1)
                            }
                        }
                        .padding(.vertical, 4),
                        alignment: .center
                    )
                    .padding(.vertical, 2)
                    .padding(.trailing, 1)
            }
            // Vertical “title + author” emboss
            .overlay(alignment: .center) {
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(KiwiColors.darkBrown.opacity(clicked ? 0.22 : 0.12))
                        .frame(width: max(2, w * 0.22), height: h * 0.55)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(KiwiColors.darkBrown.opacity(clicked ? 0.18 : 0.08))
                        .frame(width: max(2, w * 0.18), height: h * 0.18)
                }
                .padding(.vertical, 5)
                .opacity(0.9)
            }
            // Top cap highlight
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(clicked ? 0.12 : 0.18))
                    .frame(height: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(.top, 1)
                    .padding(.horizontal, 1)
            }
            .shadow(color: .black.opacity(clicked ? 0.10 : 0.08), radius: 3, x: 0, y: 2)
            .rotationEffect(.degrees(tilt), anchor: .bottom)
            .offset(y: CGFloat((i * 3) % 3))
    }

    private static func booksForCount(_ n: Int, maxBooks: Int) -> Int {
        guard n > 0 else { return 0 }
        let clamped = min(n, 80)
        let t = Double(clamped) / 80.0
        let eased = 1.0 - pow(1.0 - t, 0.55)
        let raw = Int(round(eased * Double(maxBooks)))
        return max(2, min(maxBooks, raw))
    }
}
