import Foundation
import FoundationModels

// Small structured outputs. Case names are snake_case on purpose: they are the literal values the model
// sees in the generation schema and that the prompts in `PromptCatalog` refer to.

/// Task type returned by the task classifier (§3.2 step 3). The classifier only sees the spoken
/// instruction and whether a target exists — never the target text.
@Generable
public enum ClassifiedTaskType: String, Sendable, CaseIterable {
    case proofread_rewrite
    case translate
    case transform
    case summarize
    case extract
    case explain_analyze
    case answer_question
    case compose_reply
    case insufficient_target
    case not_executable
    case requires_web

    /// Body-generation task for executable types; `nil` for types the app answers with a fixed message.
    public var generationTask: AITask? {
        switch self {
        case .proofread_rewrite: return .proofreadRewrite
        case .translate: return .translate
        case .transform: return .transform
        case .summarize: return .summarize
        case .extract: return .extract
        case .explain_analyze: return .explainAnalyze
        case .answer_question: return .answerQuestion
        case .compose_reply: return .composeReply
        case .insufficient_target, .not_executable, .requires_web: return nil
        }
    }
}

@Generable
public struct TaskClassification: Sendable, Equatable {
    public var taskType: ClassifiedTaskType
    /// Upstream definition: the output is a finished artifact that can replace the captured text.
    public var isReplacementArtifact: Bool

    public init(taskType: ClassifiedTaskType, isReplacementArtifact: Bool) {
        self.taskType = taskType
        self.isReplacementArtifact = isReplacementArtifact
    }
}

/// Destination intent for the V-07 unified-command comparison only. The product derives destination with
/// deterministic phrase rules (D5); this field exists to measure the single-generation alternative.
@Generable
public enum UnifiedOutputIntent: String, Sendable, CaseIterable {
    case automatic
    case insert_at_captured_target
    case show_result
}

/// Single structured generation (taskType + outputIntent + body) compared against the split design in V-07.
@Generable
public struct UnifiedCommandResult: Sendable, Equatable {
    public var taskType: ClassifiedTaskType
    public var outputIntent: UnifiedOutputIntent
    public var body: String

    public init(taskType: ClassifiedTaskType, outputIntent: UnifiedOutputIntent, body: String) {
        self.taskType = taskType
        self.outputIntent = outputIntent
        self.body = body
    }
}

/// Custom-instruction optimizer output: at most 5 items (OPT-05). The app still verifies the joined
/// length (500 graphemes) after generation.
@Generable
public struct OptimizedInstructionItems: Sendable, Equatable {
    @Guide(description: "Short style preferences, one per item", .maximumCount(5))
    public var items: [String]

    public init(items: [String]) {
        self.items = items
    }
}

/// One spoken self-correction proposed by stage A of the two-stage cleanup (`SelfCorrection`). The app
/// verifies both texts against the transcript before using them.
@Generable
public struct SelfCorrectionPair: Sendable, Equatable {
    @Guide(description: "Words the speaker took back, copied exactly from the transcript")
    public var retracted: String
    @Guide(description: "Words that replace them, copied exactly from the transcript")
    public var replacement: String

    public init(retracted: String, replacement: String) {
        self.retracted = retracted
        self.replacement = replacement
    }
}

/// Stage-A output: the self-corrections in a transcript (empty when there is none).
@Generable
public struct SelfCorrectionList: Sendable, Equatable {
    @Guide(description: "Self-corrections in order; empty if none", .maximumCount(4))
    public var corrections: [SelfCorrectionPair]

    public init(corrections: [SelfCorrectionPair]) {
        self.corrections = corrections
    }
}
