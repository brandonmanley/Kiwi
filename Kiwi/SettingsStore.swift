import Foundation
import SwiftData
import SwiftUI
import Combine
import UIKit

@MainActor
final class SettingsStore: ObservableObject {
    
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    var hapticsDisabled: Bool { settings.hapticsDisabled }

    var appearance: Appearance {
        Appearance(rawValue: settings.appearancePreference) ?? .system
    }

    // nil lets the app follow the OS (System); otherwise force the scheme.
    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    func setHapticsDisabled(_ disabled: Bool) {
        settings.hapticsDisabled = disabled
        persist("setHapticsDisabled")
    }

    func setAppearance(_ appearance: Appearance) {
        settings.appearancePreference = appearance.rawValue
        persist("setAppearance")
    }

    @Published private(set) var settings: UserSettings
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.settings = SettingsStore.fetchOrCreate(in: modelContext)
        SettingsStore.cleanupDuplicates(in: modelContext, keep: self.settings)
    }

    var selectedCategories: [String] { settings.selectedCategories }
    var clickedDays: [Date] { settings.clickedDays }
    var hasCompletedOnboarding: Bool { settings.hasCompletedOnboarding }

    func setSelectedCategories(_ categories: [String]) {
        let normalized = Self.normalizeCategories(categories)
        guard normalized != settings.selectedCategories else { return }

        settings.selectedCategories = normalized
        settings.clickedDays = []          // ✅ reset only on change
        persist("setSelectedCategories")
    }

    func toggleCategory(_ category: String) {
        var set = Set(settings.selectedCategories)
        if set.contains(category) { set.remove(category) }
        else { set.insert(category) }
        settings.selectedCategories = Array(set).sorted()
        persist("toggleCategory")
    }

    func markDayClicked(_ date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        if !settings.clickedDays.contains(day) {
            settings.clickedDays.append(day)
            persist("markDayClicked")
        }
    }

    func resetClickedDays() {
        settings.clickedDays = []
        persist("resetClickedDays")
    }

    func setCompletedOnboarding(_ completed: Bool) {
        settings.hasCompletedOnboarding = completed
        persist("setCompletedOnboarding")
    }
    
    private func persist(_ caller: String) {
        do {
            try modelContext.save()
            #if DEBUG
            print("Settings saved (\(caller))")
            #endif
        } catch {
            assertionFailure("Failed to save settings (\(caller)): \(error)")
            #if DEBUG
            print("Failed to save settings (\(caller)): \(error)")
            #endif
        }
        objectWillChange.send()
    }

    // MARK: Fetch / create
    static func fetchOrCreate(in context: ModelContext) -> UserSettings {
        do {
            let descriptor = FetchDescriptor<UserSettings>()
            if let existing = try context.fetch(descriptor).first {
                return existing
            }
        } catch {
            #if DEBUG
            print("Failed to fetch settings: \(error)")
            #endif
        }

        let created = UserSettings(
            selectedCategories: ["hep-ph"],
            clickedDays: [],
            hasCompletedOnboarding: false
        )
        context.insert(created)
        do { try context.save() } catch {
            #if DEBUG
            print("Failed to save newly created settings: \(error)")
            #endif
        }
        return created
    }

    static func cleanupDuplicates(in context: ModelContext, keep: UserSettings) {
        do {
            let all = try context.fetch(FetchDescriptor<UserSettings>())
            let duplicates = all.filter { $0.id != keep.id }
            guard !duplicates.isEmpty else { return }

            for d in duplicates { context.delete(d) }
            try context.save()

            #if DEBUG
            print("Deleted \(duplicates.count) duplicate UserSettings rows")
            #endif
        } catch {
            #if DEBUG
            print("Failed to clean up duplicate settings: \(error)")
            #endif
        }
    }

    nonisolated static func normalizeCategories(_ categories: [String]) -> [String] {
        Array(Set(categories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
            .sorted()
    }
}



extension SettingsStore {
    var keywords: [String] { settings.keywords }

    func setKeywords(_ keywords: [String]) {
        let normalized = Self.normalizeKeywords(keywords)
        guard normalized != settings.keywords else { return }   // ✅ avoid unnecessary saves
        settings.keywords = normalized
        persist("setKeywords")
    }

    func addKeyword(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setKeywords(settings.keywords + [trimmed])              // ✅ normalize + persist
    }

    func removeKeyword(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setKeywords(settings.keywords.filter { $0 != trimmed }) // ✅ normalize + persist
    }

    nonisolated static func normalizeKeywords(_ keywords: [String]) -> [String] {
        Array(Set(keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        ))
        .sorted()
    }
}

// Central haptics gate. Every call site routes through here so the "Haptics"
// preference actually silences the whole app — previously only SettingsView and
// OnboardingView respected it and every other generator fired unconditionally.
@MainActor
enum Haptics {
    static func impact(
        _ style: UIImpactFeedbackGenerator.FeedbackStyle,
        intensity: CGFloat = 1.0,
        store: SettingsStore
    ) {
        guard !store.hapticsDisabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred(intensity: intensity)
    }

    static func notification(
        _ type: UINotificationFeedbackGenerator.FeedbackType,
        store: SettingsStore
    ) {
        guard !store.hapticsDisabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

extension SettingsStore {
    var followedAuthors: [String] { settings.followedAuthors }

    // Author-aware membership: "Manley, B." counts as following "Brandon Manley".
    func isFollowing(_ name: String) -> Bool {
        guard let target = AuthorName.parse(name) else {
            return settings.followedAuthors.contains(name)
        }
        return settings.followedAuthors.contains { stored in
            AuthorName.parse(stored).map { target.matches($0) } ?? (stored == name)
        }
    }

    func follow(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isFollowing(trimmed) else { return }
        settings.followedAuthors.append(trimmed)
        persist("follow")
    }

    func unfollow(_ name: String) {
        let target = AuthorName.parse(name)
        settings.followedAuthors.removeAll { stored in
            if let target, let parsed = AuthorName.parse(stored) { return target.matches(parsed) }
            return stored == name
        }
        persist("unfollow")
    }

    func toggleFollow(_ name: String) {
        if isFollowing(name) { unfollow(name) } else { follow(name) }
    }

    enum NotificationMode: String, CaseIterable, Identifiable {
        case off, daily, keywords
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off:      return "Off"
            case .daily:    return "Daily summary"
            case .keywords: return "Keyword matches"
            }
        }
    }

    var notificationMode: NotificationMode {
        NotificationMode(rawValue: settings.notificationMode) ?? .off
    }

    func setNotificationMode(_ mode: NotificationMode) {
        settings.notificationMode = mode.rawValue
        persist("setNotificationMode")
    }

    var recentAuthorSearches: [String] { settings.recentAuthorSearches }

    // Records a query most-recent-first, de-duplicated (case-insensitively) and
    // capped so the list stays short.
    func addRecentAuthorSearch(_ query: String, cap: Int = 8) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = settings.recentAuthorSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        settings.recentAuthorSearches = Array(list.prefix(cap))
        persist("addRecentAuthorSearch")
    }

    func clearRecentAuthorSearches() {
        guard !settings.recentAuthorSearches.isEmpty else { return }
        settings.recentAuthorSearches = []
        persist("clearRecentAuthorSearches")
    }
}

extension SettingsStore {
    var dailyPapersDays: Int { settings.dailyPapersDays }

    func setDailyPapersDays(_ days: Int) {
        let clamped = max(1, min(21, days))
        guard clamped != settings.dailyPapersDays else { return }
        settings.dailyPapersDays = clamped
        persist("setDailyPapersDays")
    }
}
