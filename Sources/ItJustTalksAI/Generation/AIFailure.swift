import Foundation

/// Domain failure for every AI request (§6.4). Payloads carry codes and numbers only — never text.
public enum AIFailure: Error, Sendable, Hashable {
    case modelUnavailable(ModelUnavailableReason)
    case contextSizeExceeded(contextSize: Int?, tokenCount: Int?)
    case rateLimited(resetDate: Date?)
    case guardrailViolation
    case refusal
    /// BCP-47 language code reported by the framework, if any.
    case unsupportedLanguageOrLocale(languageCode: String?)
    /// Framework timeout or the app's overall deadline.
    case timeout
    case concurrentRequests
    case transcriptMutationWhileResponding
    case unsupportedCapability
    case unsupportedTranscriptContent
    case unsupportedGenerationGuide
    /// `GeneratedContent.ParsingError` (structured output could not be decoded).
    case structuredParsingFailed
    case cancelled
    /// Anything else. `code` is a type/case name only, safe to record in diagnostics.
    case other(code: String)

    /// Retry policy from the §6.4 table. Retries happen only before insertion/sending.
    public enum RetryPolicy: Sendable, Hashable {
        case none
        /// Retry once with smaller chunks.
        case retryWithSmallerChunks
        /// Wait until `resetDate` (within the overall deadline), then retry once.
        case retryAfterReset
        /// Structured parsing: classification falls back to `answer`; optimizer regenerates once.
        case taskSpecificFallback
    }

    public var retryPolicy: RetryPolicy {
        switch self {
        case .contextSizeExceeded: return .retryWithSmallerChunks
        case .rateLimited: return .retryAfterReset
        case .structuredParsingFailed: return .taskSpecificFallback
        case .modelUnavailable, .guardrailViolation, .refusal, .unsupportedLanguageOrLocale, .timeout,
             .concurrentRequests, .transcriptMutationWhileResponding, .unsupportedCapability,
             .unsupportedTranscriptContent, .unsupportedGenerationGuide, .cancelled, .other:
            return .none
        }
    }

    /// Short stable code for diagnostics and evaluation records (no text content).
    public var code: String {
        switch self {
        case .modelUnavailable(let reason): return "modelUnavailable.\(reason.rawValue)"
        case .contextSizeExceeded: return "contextSizeExceeded"
        case .rateLimited: return "rateLimited"
        case .guardrailViolation: return "guardrailViolation"
        case .refusal: return "refusal"
        case .unsupportedLanguageOrLocale: return "unsupportedLanguageOrLocale"
        case .timeout: return "timeout"
        case .concurrentRequests: return "concurrentRequests"
        case .transcriptMutationWhileResponding: return "transcriptMutationWhileResponding"
        case .unsupportedCapability: return "unsupportedCapability"
        case .unsupportedTranscriptContent: return "unsupportedTranscriptContent"
        case .unsupportedGenerationGuide: return "unsupportedGenerationGuide"
        case .structuredParsingFailed: return "structuredParsingFailed"
        case .cancelled: return "cancelled"
        case .other(let code): return "other.\(code)"
        }
    }
}
