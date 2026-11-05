import Testing
import FoundationModels
@testable import ItJustTalksAI

@Suite("On-device variant presentation")
struct OnDeviceVariantTests {
    @Test func core3DecisionUsesSuppliedVariantsWithoutAModel() {
        guard #available(macOS 27, *) else { return }
        #expect(OnDeviceGenerator.isCore3Variant(.core3))
        #expect(!OnDeviceGenerator.isCore3Variant(.coreAdvanced3))
    }
}
