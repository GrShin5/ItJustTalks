import Foundation
import FoundationModels

/// Maps every error thrown around a FoundationModels request to `AIFailure` (§6.4).
///
/// Total by construction: known framework types are switched exhaustively (with `@unknown default` for
/// non-frozen enums added by future OS versions), and anything else becomes `.other(code:)`.
@available(macOS 27, *)
public enum AIFailureMapper {
    /// Mapping for errors caught around a request: if the current task was cancelled, the result is always
    /// `.cancelled`, whatever the framework threw (e.g. `rateLimited` / `contextSizeExceeded`, which would
    /// otherwise be retried).
    public static func mapCaught(_ error: any Error) -> AIFailure {
        if Task.isCancelled { return .cancelled }
        return map(error)
    }

    public static func map(_ error: any Error) -> AIFailure {
        if let failure = error as? AIFailure { return failure }
        if error is CancellationError { return .cancelled }
        if let error = error as? LanguageModelError { return map(error) }
        if let error = error as? SystemLanguageModel.Error { return map(error) }
        if let error = error as? LanguageModelSession.Error { return map(error) }
        if error is GeneratedContent.ParsingError { return .structuredParsingFailed }
        if error is StructuredOutputDecodingError { return .structuredParsingFailed }
        if let legacy = (LegacyGenerationErrorMapper.self as any LegacyErrorMapping.Type).map(error) {
            return legacy
        }
        return .other(code: String(describing: type(of: error)))
    }

    public static func map(_ error: LanguageModelError) -> AIFailure {
        switch error {
        case .contextSizeExceeded(let info):
            return .contextSizeExceeded(contextSize: info.contextSize, tokenCount: info.tokenCount)
        case .rateLimited(let info):
            return .rateLimited(resetDate: info.resetDate)
        case .guardrailViolation:
            return .guardrailViolation
        case .refusal:
            return .refusal
        case .unsupportedCapability:
            return .unsupportedCapability
        case .unsupportedTranscriptContent:
            return .unsupportedTranscriptContent
        case .unsupportedGenerationGuide:
            return .unsupportedGenerationGuide
        case .unsupportedLanguageOrLocale(let info):
            return .unsupportedLanguageOrLocale(languageCode: info.languageCode.identifier)
        case .timeout:
            return .timeout
        @unknown default:
            return .other(code: "LanguageModelError.unknown")
        }
    }

    public static func map(_ error: SystemLanguageModel.Error) -> AIFailure {
        switch error {
        case .assetsUnavailable:
            return .modelUnavailable(.assetsUnavailable)
        @unknown default:
            return .other(code: "SystemLanguageModel.Error.unknown")
        }
    }

    public static func map(_ error: LanguageModelSession.Error) -> AIFailure {
        switch error {
        case .concurrentRequests:
            return .concurrentRequests
        case .transcriptMutationWhileResponding:
            return .transcriptMutationWhileResponding
        @unknown default:
            return .other(code: "LanguageModelSession.Error.unknown")
        }
    }

    public static func map(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> ModelUnavailableReason {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        @unknown default: return .unknown
        }
    }

    public static func map(_ availability: SystemLanguageModel.Availability) -> ModelAvailability {
        switch availability {
        case .available: return .available
        case .unavailable(let reason): return .unavailable(map(reason))
        }
    }
}

/// The pre-27 `LanguageModelSession.GenerationError` is deprecated on macOS 27 and should no longer be
/// thrown, but it is still mapped so the mapping stays total if it ever is. Calling through a protocol
/// keeps the deprecated references confined to this one deprecated witness (no build warnings).
private protocol LegacyErrorMapping {
    static func map(_ error: any Error) -> AIFailure?
}

private enum LegacyGenerationErrorMapper: LegacyErrorMapping {
    @available(macOS, deprecated: 27.0)
    static func map(_ error: any Error) -> AIFailure? {
        guard let error = error as? LanguageModelSession.GenerationError else { return nil }
        switch error {
        case .exceededContextWindowSize: return .contextSizeExceeded(contextSize: nil, tokenCount: nil)
        case .assetsUnavailable: return .modelUnavailable(.assetsUnavailable)
        case .guardrailViolation: return .guardrailViolation
        case .unsupportedGuide: return .unsupportedGenerationGuide
        case .unsupportedLanguageOrLocale: return .unsupportedLanguageOrLocale(languageCode: nil)
        case .decodingFailure: return .structuredParsingFailed
        case .rateLimited: return .rateLimited(resetDate: nil)
        case .concurrentRequests: return .concurrentRequests
        case .refusal: return .refusal
        @unknown default: return .other(code: "GenerationError.unknown")
        }
    }
}
