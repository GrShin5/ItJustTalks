import Testing
@testable import ItJustTalks

@Suite("Onboarding screenshot presentation")
struct OnboardingScreenshotModeTests {
    @Test func debugScreenshotUsesFirstRunTitleAndCompletionLabel() {
        for mode in [OnboardingPresentationMode.debugPreview, .debugRehearsal] {
            for language in [AppLanguage.japanese, .english] {
                #expect(mode.title(for: language, screenshotMode: true) == OnboardingPresentationMode.firstRun.title(for: language))
                #expect(mode.title(for: language) != OnboardingPresentationMode.firstRun.title(for: language))
            }
            #expect(mode.completionButtonKey(screenshotMode: true) == "ItJustTalksを開始")
            #expect(mode.completionButtonKey(screenshotMode: false) == "Debugメニューへ戻る")
            #expect(!mode.showsDebugUI(screenshotMode: true))
            #expect(mode.showsDebugUI(screenshotMode: false))
        }
    }

    @Test func productionPresentationIgnoresScreenshotFlag() {
        for mode in [OnboardingPresentationMode.firstRun, .upgrade, .permissionRecovery, .guide] {
            for language in [AppLanguage.japanese, .english] {
                #expect(mode.title(for: language, screenshotMode: true) == mode.title(for: language))
            }
            #expect(mode.completionButtonKey(screenshotMode: true) == mode.completionButtonKey(screenshotMode: false))
            #expect(!mode.showsDebugUI(screenshotMode: true))
            #expect(!mode.showsDebugUI(screenshotMode: false))
        }
        #expect(OnboardingPresentationMode.guide.completionButtonKey(screenshotMode: false) == "閉じる")
        #expect(OnboardingPresentationMode.firstRun.completionButtonKey(screenshotMode: false) == "ItJustTalksを開始")
    }
}
