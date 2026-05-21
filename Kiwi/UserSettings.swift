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

    init(
        id: UUID = UUID(),
        selectedCategories: [String] = ["hep-ph"],
        clickedDays: [Date] = [],
        hasCompletedOnboarding: Bool = false,
        hapticsDisabled: Bool = false,
        darkModeEnabled: Bool = false,
        keywords: [String] = [],
        dailyPapersDays: Int = 7
    ) {
        self.id = id
        self.selectedCategories = selectedCategories
        self.clickedDays = clickedDays
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.hapticsDisabled = hapticsDisabled
        self.darkModeEnabled = darkModeEnabled
        self.keywords = keywords
        self.dailyPapersDays = dailyPapersDays
    }
}
