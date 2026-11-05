import Foundation
import FoundationModels

/// Guardrail configuration for one request. Which mode a task uses is decided by `AITask.guardrails` (G1):
/// `permissiveContentTransformations` only for cleanup and transformations of the user's own text.
public enum GuardrailsMode: String, Sendable, Hashable, CaseIterable {
    case `default`
    case permissiveContentTransformations
}

/// One generation request. Instructions are fixed (from `PromptCatalog`); the prompt carries all variable
/// data in delimited sections (see `PromptAssembler`). A new session is created per request (D6).
public struct GenerationRequest: Sendable, Hashable {
    public var instructions: String
    public var prompt: String
    /// Output reservation from `ContextBudgeter`. `nil` leaves the framework default.
    public var maximumResponseTokens: Int?
    /// Greedy sampling for reproducibility (D10). Defaults to true.
    public var greedy: Bool
    public var guardrails: GuardrailsMode

    public init(
        instructions: String,
        prompt: String,
        maximumResponseTokens: Int? = nil,
        greedy: Bool = true,
        guardrails: GuardrailsMode = .default
    ) {
        self.instructions = instructions
        self.prompt = prompt
        self.maximumResponseTokens = maximumResponseTokens
        self.greedy = greedy
        self.guardrails = guardrails
    }
}

/// Token usage reported by the framework for one response (macOS 27 `Response.usage`).
public struct TokenUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, cachedInputTokens: Int = 0, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }
}

/// Plain-text generation result. Contains the output text; callers must not log it.
public struct GenerationResult: Sendable, Hashable {
    public var text: String
    public var usage: TokenUsage?
    /// True when the response may be cut off (fail-closed): output tokens reached `maximumResponseTokens`,
    /// or came within 10% of it while the text does not end like a finished sentence, or a limit was set but
    /// usage is unknown. False only when no limit was requested.
    public var isTruncated: Bool
    public var latency: Duration

    public init(text: String, usage: TokenUsage?, isTruncated: Bool, latency: Duration) {
        self.text = text
        self.usage = usage
        self.isTruncated = isTruncated
        self.latency = latency
    }
}

/// Structured generation result for small `Generable` outputs (task classification, unified command,
/// instruction optimizer).
public struct StructuredGenerationResult<Output: Sendable>: Sendable {
    public var value: Output
    public var usage: TokenUsage?
    public var isTruncated: Bool
    public var latency: Duration

    public init(value: Output, usage: TokenUsage?, isTruncated: Bool, latency: Duration) {
        self.value = value
        self.usage = usage
        self.isTruncated = isTruncated
        self.latency = latency
    }
}

/// Why the on-device model cannot be used right now.
public enum ModelUnavailableReason: String, Sendable, Hashable, CaseIterable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// `SystemLanguageModel.Error.assetsUnavailable` thrown at generation time.
    case assetsUnavailable
    /// A reason added by a future OS that this build does not know.
    case unknown
}

public enum ModelAvailability: Sendable, Hashable {
    case available
    case unavailable(ModelUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// What a token count is measured for (Tf / Td in §5.1).
public enum TokenCountSubject: Sendable, Hashable {
    case instructions(String)
    case prompt(String)
}

/// Text generation backed by the on-device model, or a fake in tests.
///
/// Every failure is surfaced as `AIFailure` (typed throws) so callers can handle the §6.4 table exhaustively.
public protocol TextGenerating: Sendable {
    var availability: ModelAvailability { get }
    /// Runtime context size `C` in tokens.
    var contextSize: Int { get }
    /// Model variant display name (macOS 27+), for evaluation records only.
    var variantName: String? { get }

    func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int
    /// Schema size `Ts` for a structured output type.
    func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int

    func generate(_ request: GenerationRequest) async throws(AIFailure) -> GenerationResult
    func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest,
        generating type: Output.Type
    ) async throws(AIFailure) -> StructuredGenerationResult<Output>
}

/// Truncation rule shared by implementations (fail-closed, §3.6).
///
/// Signals: (1) output tokens reached the reserved maximum; (2) output tokens are within
/// `nearLimitRatio` of the maximum and the text does not end with sentence-final punctuation or a closing
/// bracket (second signal, in case the framework stops a few tokens early or counts differently);
/// (3) a limit was requested but usage is unknown, or the limit is not positive.
/// Callers that pass `maximumResponseTokens: nil` accept the framework default and get `false`.
enum TruncationRule {
    static let nearLimitRatio = 0.9
    private static let finalCharacters: Set<Character> = [
        "。", "．", ".", "!", "?", "！", "？", "」", "』", "）", ")", "】", "]", "}", "\"", "”", "'", "’", "…", "〜", "~",
    ]

    static func isTruncated(outputTokens: Int?, maximumResponseTokens: Int?, text: String?) -> Bool {
        guard let maximumResponseTokens else { return false }
        guard maximumResponseTokens > 0, let outputTokens else { return true }
        if outputTokens >= maximumResponseTokens { return true }
        guard let text, Double(outputTokens) >= Double(maximumResponseTokens) * nearLimitRatio else { return false }
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return true }
        return !finalCharacters.contains(last) && !last.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }
}

extension TextGenerating {
    static func isTruncated(outputTokens: Int?, maximumResponseTokens: Int?, text: String? = nil) -> Bool {
        TruncationRule.isTruncated(outputTokens: outputTokens, maximumResponseTokens: maximumResponseTokens, text: text)
    }
}
