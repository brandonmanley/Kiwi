import Foundation
import SwiftData

@Model
final class UserSettings {

    var id: UUID
    var selectedCategories: [String]
    var clickedDays: [Date]
    var hasCompletedOnboarding: Bool
    var hapticsDisabled: Bool
    var darkModeEnabled: Bool
    var keywords: [String]
    var dailyPapersDays: Int
    // Three-way appearance: "system" / "light" / "dark". Replaces the boolean
    // darkModeEnabled (kept only so the additive migration is lossless).
    var appearancePreference: String = "system"
    // Canonical display names of followed authors (e.g. "Brandon Manley").
    var followedAuthors: [String] = []
    // Recent author-search queries, most-recent first (capped).
    var recentAuthorSearches: [String] = []
    // Notification mode: "off" / "daily" (summary at announcement) / "keywords".
    var notificationMode: String = "off"

    init(
        id: UUID = UUID(),
        selectedCategories: [String] = ["hep-ph"],
        clickedDays: [Date] = [],
        hasCompletedOnboarding: Bool = false,
        hapticsDisabled: Bool = false,
        darkModeEnabled: Bool = false,
        keywords: [String] = [],
        dailyPapersDays: Int = 7,
        appearancePreference: String = "system",
        followedAuthors: [String] = [],
        recentAuthorSearches: [String] = [],
        notificationMode: String = "off"
    ) {
        self.id = id
        self.selectedCategories = selectedCategories
        self.clickedDays = clickedDays
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.hapticsDisabled = hapticsDisabled
        self.darkModeEnabled = darkModeEnabled
        self.keywords = keywords
        self.dailyPapersDays = dailyPapersDays
        self.appearancePreference = appearancePreference
        self.followedAuthors = followedAuthors
        self.recentAuthorSearches = recentAuthorSearches
        self.notificationMode = notificationMode
    }
}
