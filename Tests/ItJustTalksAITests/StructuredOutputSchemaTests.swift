import Foundation
import FoundationModels
import Testing
@testable import ItJustTalksAI

// Goldens were captured from the original @Generable macro output with Xcode 27
// (macOS 27 SDK) on 2026-11-06 and must not be regenerated from the hand-written code.
@Suite("Structured output schemas")
struct StructuredOutputSchemaTests {
    private func encodedSchema<T: Generable>(_ type: T.Type) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(T.generationSchema), as: UTF8.self)
    }

    @Test func classifiedTaskTypeSchema() throws {
        #expect(try encodedSchema(ClassifiedTaskType.self) == ##"{"enum":["proofread_rewrite","translate","transform","summarize","extract","explain_analyze","answer_question","compose_reply","insufficient_target","not_executable","requires_web"],"title":"ClassifiedTaskType","type":"string"}"##)
    }

    @Test func taskClassificationSchema() throws {
        #expect(try encodedSchema(TaskClassification.self) == ##"{"additionalProperties":false,"properties":{"isReplacementArtifact":{"type":"boolean"},"taskType":{"enum":["proofread_rewrite","translate","transform","summarize","extract","explain_analyze","answer_question","compose_reply","insufficient_target","not_executable","requires_web"],"type":"string"}},"required":["taskType","isReplacementArtifact"],"title":"TaskClassification","type":"object","x-order":["taskType","isReplacementArtifact"]}"##)
    }

    @Test func unifiedOutputIntentSchema() throws {
        #expect(try encodedSchema(UnifiedOutputIntent.self) == ##"{"enum":["automatic","insert_at_captured_target","show_result"],"title":"UnifiedOutputIntent","type":"string"}"##)
    }

    @Test func unifiedCommandResultSchema() throws {
        #expect(try encodedSchema(UnifiedCommandResult.self) == ##"{"additionalProperties":false,"properties":{"body":{"type":"string"},"outputIntent":{"enum":["automatic","insert_at_captured_target","show_result"],"type":"string"},"taskType":{"enum":["proofread_rewrite","translate","transform","summarize","extract","explain_analyze","answer_question","compose_reply","insufficient_target","not_executable","requires_web"],"type":"string"}},"required":["taskType","outputIntent","body"],"title":"UnifiedCommandResult","type":"object","x-order":["taskType","outputIntent","body"]}"##)
    }

    @Test func optimizedInstructionItemsSchema() throws {
        #expect(try encodedSchema(OptimizedInstructionItems.self) == ##"{"additionalProperties":false,"properties":{"items":{"description":"Short style preferences, one per item","items":{"type":"string"},"maxItems":5,"type":"array"}},"required":["items"],"title":"OptimizedInstructionItems","type":"object","x-order":["items"]}"##)
    }

    @Test func selfCorrectionPairSchema() throws {
        #expect(try encodedSchema(SelfCorrectionPair.self) == ##"{"additionalProperties":false,"properties":{"replacement":{"description":"Words that replace them, copied exactly from the transcript","type":"string"},"retracted":{"description":"Words the speaker took back, copied exactly from the transcript","type":"string"}},"required":["retracted","replacement"],"title":"SelfCorrectionPair","type":"object","x-order":["retracted","replacement"]}"##)
    }

    @Test func selfCorrectionListSchema() throws {
        #expect(try encodedSchema(SelfCorrectionList.self) == ##"{"$defs":{"SelfCorrectionPair":{"additionalProperties":false,"properties":{"replacement":{"description":"Words that replace them, copied exactly from the transcript","type":"string"},"retracted":{"description":"Words the speaker took back, copied exactly from the transcript","type":"string"}},"required":["retracted","replacement"],"title":"SelfCorrectionPair","type":"object","x-order":["retracted","replacement"]}},"additionalProperties":false,"properties":{"corrections":{"description":"Self-corrections in order; empty if none","items":{"$ref":"#\/$defs\/SelfCorrectionPair"},"maxItems":4,"type":"array"}},"required":["corrections"],"title":"SelfCorrectionList","type":"object","x-order":["corrections"]}"##)
    }

    @Test func enumRoundTrips() throws {
        for value in ClassifiedTaskType.allCases {
            #expect(try ClassifiedTaskType(value.generatedContent) == value)
        }
        for value in UnifiedOutputIntent.allCases {
            #expect(try UnifiedOutputIntent(value.generatedContent) == value)
        }
        #expect(ClassifiedTaskType.compose_reply.generatedContent.jsonString == ##""compose_reply""##)
    }

    @Test func structRoundTrips() throws {
        let classification = TaskClassification(taskType: .translate, isReplacementArtifact: true)
        #expect(try TaskClassification(classification.generatedContent) == classification)
        #expect(classification.generatedContent.jsonString == ##"{"taskType": "translate", "isReplacementArtifact": true}"##)
        let command = UnifiedCommandResult(taskType: .compose_reply, outputIntent: .show_result, body: "Reply")
        #expect(try UnifiedCommandResult(command.generatedContent) == command)
        let items = OptimizedInstructionItems(items: ["Concise", "Polite"])
        #expect(try OptimizedInstructionItems(items.generatedContent) == items)
        let pair = SelfCorrectionPair(retracted: "a", replacement: "b")
        #expect(try SelfCorrectionPair(pair.generatedContent) == pair)
        let list = SelfCorrectionList(corrections: [pair])
        #expect(try SelfCorrectionList(list.generatedContent) == list)
        #expect(list.generatedContent.jsonString == ##"{"corrections": [{"retracted": "a", "replacement": "b"}]}"##)
        let empty = SelfCorrectionList(corrections: [])
        #expect(try SelfCorrectionList(empty.generatedContent) == empty)
    }

    @Test func unknownEnumValuesThrow() {
        #expect(throws: StructuredOutputDecodingError.self) {
            try ClassifiedTaskType(GeneratedContent("no_such_case"))
        }
        #expect(throws: StructuredOutputDecodingError.self) {
            try UnifiedOutputIntent(GeneratedContent("no_such_case"))
        }
        // The macro version threw a parsing error mapped to .structuredParsingFailed, which drives the
        // classifier fallback and the optimizer's single regeneration. Keep that mapping.
        do {
            _ = try ClassifiedTaskType(GeneratedContent("no_such_case"))
            Issue.record("Expected a decoding error")
        } catch {
            #expect(AIFailureMapper.map(error) == .structuredParsingFailed)
        }
    }

    @Test func noXcodeOnlyMacrosInProductionSources() throws {
        let manager = FileManager.default
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !manager.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            let parent = root.deletingLastPathComponent()
            guard parent != root else {
                Issue.record("Could not find the package root containing Package.swift")
                return
            }
            root = parent
        }
        for directory in ["Sources", "Tools"] {
            let url = root.appendingPathComponent(directory)
            var traversalFailed = false
            guard let files = manager.enumerator(at: url, includingPropertiesForKeys: nil, errorHandler: { _, _ in
                traversalFailed = true
                return true
            }) else {
                Issue.record("Could not scan \(directory)")
                continue
            }
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    #expect(!line.contains("@Generable") && !line.contains("@Guide("),
                            "\(file.lastPathComponent):\(index + 1): These macros require full Xcode and break Command Line Tools builds.")
                    // In the macOS 27 SDK `@State` is the SwiftUIMacros `State()` macro (Xcode only); use `@ViewState`.
                    #expect(line.range(of: #"@State\b(?!Object)"#, options: .regularExpression) == nil,
                            "\(file.lastPathComponent):\(index + 1): Use @ViewState instead of @State so Command Line Tools can build the app.")
                }
            }
            #expect(!traversalFailed, "Could not read all files under \(directory)")
        }
    }
}
