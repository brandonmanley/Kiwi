import Foundation
import SwiftData
import SwiftUI
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    
    var hapticsDisabled: Bool { settings.hapticsDisabled }
    var darkModeEnabled: Bool { settings.darkModeEnabled }

    func setHapticsDisabled(_ disabled: Bool) {
        settings.hapticsDisabled = disabled
        persist("setHapticsDisabled")
    }

    func setDarkModeEnabled(_ enabled: Bool) {
        settings.darkModeEnabled = enabled
        persist("setDarkModeEnabled")
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
