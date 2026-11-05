import Foundation
import FoundationModels
import Testing
@testable import ItJustTalksAI

/// macOS 27 framework types: the suite is reported as skipped (not silently passed) on older systems.
let runsOnMacOS27: Bool = {
    if #available(macOS 27, *) { return true }
    return false
}()

@Suite("AIFailure mapping", .enabled(if: runsOnMacOS27, "FoundationModels macOS 27 API"))
struct AIFailureMappingTests {
    struct UnrelatedError: Error {}

    @available(macOS 27, *)
    static var languageModelErrors: [(LanguageModelError, AIFailure)] {
        let reset = Date(timeIntervalSince1970: 1_000)
        return [
            (.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "")),
             .contextSizeExceeded(contextSize: 4096, tokenCount: 5000)),
            (.rateLimited(.init(resetDate: reset, debugDescription: "")), .rateLimited(resetDate: reset)),
            (.rateLimited(.init(resetDate: nil, debugDescription: "")), .rateLimited(resetDate: nil)),
            (.guardrailViolation(.init(debugDescription: "")), .guardrailViolation),
            (.refusal(.init(explanation: "", debugDescription: "")), .refusal),
            (.unsupportedCapability(.init(capability: .toolCalling, debugDescription: "")), .unsupportedCapability),
            (.unsupportedTranscriptContent(.init(unsupportedContent: [], debugDescription: "")), .unsupportedTranscriptContent),
            (.unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: "")), .unsupportedGenerationGuide),
            (.unsupportedLanguageOrLocale(.init(languageCode: .init("xx"), debugDescription: "")),
             .unsupportedLanguageOrLocale(languageCode: "xx")),
            (.timeout(.init(debugDescription: "")), .timeout),
        ]
    }

    @available(macOS 27, *)
    @Test func everyLanguageModelErrorCase() throws {
        for (error, expected) in Self.languageModelErrors {
            #expect(AIFailureMapper.map(error as any Error) == expected)
        }
    }

    @available(macOS 27, *)
    @Test func otherFrameworkErrors() {
        #expect(AIFailureMapper.map(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "")))
            == .modelUnavailable(.assetsUnavailable))
        #expect(AIFailureMapper.map(LanguageModelSession.Error.concurrentRequests) == .concurrentRequests)
        #expect(AIFailureMapper.map(LanguageModelSession.Error.transcriptMutationWhileResponding)
            == .transcriptMutationWhileResponding)
        #expect(AIFailureMapper.map(GeneratedContent.ParsingError(rawContent: "", debugDescription: ""))
            == .structuredParsingFailed)
    }

    @available(macOS 27, *)
    @Test func nonFrameworkErrors() {
        #expect(AIFailureMapper.map(CancellationError()) == .cancelled)
        #expect(AIFailureMapper.map(AIFailure.timeout) == .timeout)
        #expect(AIFailureMapper.map(UnrelatedError()) == .other(code: "UnrelatedError"))
    }

    @available(macOS 27, *)
    @Test func availabilityReasons() {
        #expect(AIFailureMapper.map(.deviceNotEligible) == .deviceNotEligible)
        #expect(AIFailureMapper.map(.appleIntelligenceNotEnabled) == .appleIntelligenceNotEnabled)
        #expect(AIFailureMapper.map(.modelNotReady) == .modelNotReady)
        #expect(AIFailureMapper.map(SystemLanguageModel.Availability.available) == .available)
        #expect(AIFailureMapper.map(SystemLanguageModel.Availability.unavailable(.modelNotReady))
            == .unavailable(.modelNotReady))
    }

    /// M5: an error caught after cancellation is `.cancelled`, never a retryable failure.
    @available(macOS 27, *)
    @Test func cancellationWinsOverCaughtErrors() async {
        let retryable: [any Error] = [
            LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "")),
            LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "")),
            UnrelatedError(),
        ]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return retryable.map { AIFailureMapper.mapCaught($0) }
        }
        let mapped = await task.value
        #expect(mapped == [.cancelled, .cancelled, .cancelled])
        // Without cancellation the normal mapping (and its retry policy) applies.
        #expect(AIFailureMapper.mapCaught(retryable[0]).retryPolicy == .retryAfterReset)
    }

    @Test func retryPolicyFollowsTable() {
        #expect(AIFailure.contextSizeExceeded(contextSize: nil, tokenCount: nil).retryPolicy == .retryWithSmallerChunks)
        #expect(AIFailure.rateLimited(resetDate: nil).retryPolicy == .retryAfterReset)
        #expect(AIFailure.structuredParsingFailed.retryPolicy == .taskSpecificFallback)
        for failure: AIFailure in [.refusal, .guardrailViolation, .timeout, .cancelled, .concurrentRequests,
                                   .modelUnavailable(.modelNotReady), .unsupportedLanguageOrLocale(languageCode: nil),
                                   .other(code: "x")] {
            #expect(failure.retryPolicy == AIFailure.RetryPolicy.none)
        }
    }

    @Test func codesCarryNoText() {
        #expect(AIFailure.unsupportedLanguageOrLocale(languageCode: "xx").code == "unsupportedLanguageOrLocale")
        #expect(AIFailure.modelUnavailable(.modelNotReady).code == "modelUnavailable.modelNotReady")
    }
}
