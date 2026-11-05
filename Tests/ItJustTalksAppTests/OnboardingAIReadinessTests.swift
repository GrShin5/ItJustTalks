import Testing
import ItJustTalksAI
@testable import ItJustTalks

@Suite("Onboarding AI readiness")
struct OnboardingAIReadinessTests {
    @Test func previewDoesNotQueryTheMac() {
        var queried = false
        let status = OnboardingAIReadinessPolicy.status(isPreview: true) {
            queried = true
            return .modelNotReady
        }
        #expect(status == .available)
        #expect(!queried)
    }

    @Test func livePresentationPreservesEverySettingsStatus() {
        for status in [AppleIntelligenceStatus.available, .appleIntelligenceOff,
                       .deviceNotEligible, .modelNotReady, .unavailable] {
            #expect(OnboardingAIReadinessPolicy.status(isPreview: false) { status } == status)
            #expect(AppLocalizer.hasTranslation(for: status.labelKey, language: .english))
            #expect(AppLocalizer.hasTranslation(for: status.detailKey, language: .english))
        }
    }

    @Test func core3NoticeUsesSuppliedInputAndStaysHiddenInPreview() {
        #expect(OnboardingAIReadinessPolicy.showsCore3Notice(isPreview: false, isCore3: true))
        #expect(!OnboardingAIReadinessPolicy.showsCore3Notice(isPreview: false, isCore3: false))
        for isCore3 in [true, false] {
            #expect(!OnboardingAIReadinessPolicy.showsCore3Notice(isPreview: true, isCore3: isCore3))
        }
    }

    @Test func historyExplanationMatchesAllModeDefaults() {
        let defaults = ItJustTalksSettings.default
        #expect(defaults.historyEnabled)
        #expect(defaults.handsFreeSendSettings.historyEnabled)
        #expect(defaults.aiCommandSettings.historyEnabled)
        #expect(defaults.historyRetentionDays == 180)
        #expect(defaults.historyRetentionDays == defaults.handsFreeSendSettings.historyRetentionDays)
        #expect(defaults.historyRetentionDays == defaults.aiCommandSettings.historyRetentionDays)
    }
}
