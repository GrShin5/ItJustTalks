import Foundation

/// Stable, content-free reason for a request that did not produce an applicable result (§6.4). The app maps
/// each case to its own message; nothing here carries user text. Raw values are stable identifiers.
public enum AIFailureReason: String, Sendable, Hashable, CaseIterable, Codable {
    // Model unavailable (never retried).
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case assetsUnavailable
    /// Unavailable for a reason this build does not know.
    case modelUnavailable
    /// The request does not fit the context (framework `contextSizeExceeded`, or the budget needs chunking /
    /// is impossible). Chunking belongs to P6; until then this is final.
    case contextSizeExceeded
    /// The custom instruction prevents processing a body that would otherwise fit (CUSTOM-06).
    case customInstructionTooLong
    /// Still rate limited after the single retry, or the wait would not fit the deadline.
    case rateLimited
    /// `guardrailViolation` or `refusal`.
    case guardrail
    case unsupportedLanguage
    /// Framework timeout or the app's deadline.
    case timeout
    case cancelled
    /// A result was generated but the validator rejected it (`ValidationReport` holds the reasons).
    case validationFailed
    /// Inconsistencies and implementation errors (concurrent requests, unsupported capability, parsing, other).
    case generationError

    public init(_ failure: AIFailure) {
        switch failure {
        case .modelUnavailable(let reason):
            switch reason {
            case .deviceNotEligible: self = .deviceNotEligible
            case .appleIntelligenceNotEnabled: self = .appleIntelligenceNotEnabled
            case .modelNotReady: self = .modelNotReady
            case .assetsUnavailable: self = .assetsUnavailable
            case .unknown: self = .modelUnavailable
            }
        case .contextSizeExceeded: self = .contextSizeExceeded
        case .rateLimited: self = .rateLimited
        case .guardrailViolation, .refusal: self = .guardrail
        case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
        case .timeout: self = .timeout
        case .cancelled: self = .cancelled
        case .concurrentRequests, .transcriptMutationWhileResponding, .unsupportedCapability,
             .unsupportedTranscriptContent, .unsupportedGenerationGuide, .structuredParsingFailed, .other:
            self = .generationError
        }
    }
}
