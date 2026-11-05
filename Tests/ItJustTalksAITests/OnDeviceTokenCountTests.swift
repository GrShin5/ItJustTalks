import Foundation
import Testing
@testable import ItJustTalksAI

/// Measures each fixed instruction with the on-device tokenizer. Opt-in (needs the model on this Mac):
/// `ITJT_COUNT_TOKENS=1 swift test --filter OnDeviceTokenCount`. Prints counts only, never text.
@Suite("OnDeviceTokenCount", .enabled(if: ProcessInfo.processInfo.environment["ITJT_COUNT_TOKENS"] == "1"))
struct OnDeviceTokenCountTests {
    @Test func fixedInstructionTokenCounts() async throws {
        guard #available(macOS 27, *) else { return }
        let generator = OnDeviceGenerator()
        guard generator.availability.isAvailable else {
            print("TOKENS unavailable \(generator.availability)")
            return
        }
        print("TOKENS context=\(generator.contextSize) variant=\(generator.variantName ?? "-")")
        for template in PromptCatalog.all {
            let count = try await generator.tokenCount(for: .instructions(template.text))
            print("TOKENS \(template.key) \(count)\(count > 350 ? " OVER" : "")")
        }
        for (name, type) in [("TaskClassification", 0), ("UnifiedCommandResult", 1), ("OptimizedInstructionItems", 2)] {
            let count: Int
            switch type {
            case 0: count = try await generator.schemaTokenCount(for: TaskClassification.self)
            case 1: count = try await generator.schemaTokenCount(for: UnifiedCommandResult.self)
            default: count = try await generator.schemaTokenCount(for: OptimizedInstructionItems.self)
            }
            print("TOKENS schema.\(name) \(count)")
        }
    }
}
