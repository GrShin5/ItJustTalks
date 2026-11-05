import AppKit
import Testing
@testable import ItJustTalks

@Suite("Result panel presentation")
struct ResultPanelPresentationPolicyTests {
    @Test func bothPresentationsStayVisibleIndependentlyOfActivation() {
        for presentation in [AICommandResultPresentation.activatesApplication, .nonactivatingConfirmation] {
            let policy = ResultPanelPresentationPolicy(presentation: presentation)
            #expect(policy.isFloatingPanel)
            #expect(!policy.hidesOnDeactivate)
            #expect(policy.level == .floating)
            #expect(policy.collectionBehavior.contains(.canJoinAllSpaces))
            #expect(policy.collectionBehavior.contains(.fullScreenAuxiliary))
        }
    }

    @Test func normalResultActivatesAndMakesKeyForCopying() {
        let policy = ResultPanelPresentationPolicy(presentation: .activatesApplication)
        #expect(policy.activatesApp)
        #expect(policy.makesKey)
        #expect(policy.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])
        #expect(policy.styleMask == [.titled, .closable, .resizable])
        #expect(!policy.becomesKeyOnlyIfNeeded)
    }

    @Test func confirmationPreservesNonactivatingAttributes() {
        let policy = ResultPanelPresentationPolicy(presentation: .nonactivatingConfirmation)
        #expect(!policy.activatesApp)
        #expect(!policy.makesKey)
        #expect(policy.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        #expect(policy.styleMask == [.titled, .closable, .resizable, .nonactivatingPanel])
        #expect(policy.becomesKeyOnlyIfNeeded)
    }
}
