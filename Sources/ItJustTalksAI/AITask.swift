import Foundation

/// The kind of AI work a single generation performs. Used by the budgeter, the validator and the
/// prompt catalog so that per-task policies live in one vocabulary.
public enum AITask: String, CaseIterable, Sendable, Hashable, Codable {
    /// Normal dictation cleanup (§3.1).
    case cleanup
    // AI command body generation, one per executable task type (§3.2 step 4).
    case proofreadRewrite = "proofread_rewrite"
    case translate
    case transform
    case summarize
    case extract
    case explainAnalyze = "explain_analyze"
    case answerQuestion = "answer_question"
    case composeReply = "compose_reply"
    /// Small structured generation that classifies the spoken instruction (§3.2 step 3).
    case taskClassification = "task_classification"
    /// Single structured generation (taskType + outputIntent + body) compared in V-07.
    case unifiedCommand = "unified_command"
    /// Custom-instruction optimizer (§3.5).
    case instructionOptimization = "instruction_optimization"
    /// Stage A of the two-stage cleanup: small structured generation that lists spoken self-corrections
    /// (`SelfCorrectionList`). Runs only when `SelfCorrection.hasCue(in:)` finds a cue.
    case selfCorrection = "self_correction"

    /// Tasks whose output is expected to be a rewrite of the source body (length and content checks apply).
    public var isSourceRewrite: Bool {
        switch self {
        case .cleanup, .proofreadRewrite, .translate, .transform:
            return true
        default:
            return false
        }
    }

    /// Guardrail mode for this task's generation (G1, 2026-10-14). Cleanup and transformations of the
    /// user's own text (proofread, translate, transform, summarize, extract) use
    /// `permissiveContentTransformations`, the SDK mode meant for transforming possibly sensitive input text.
    /// Stage A of the cleanup (`selfCorrection`) only copies spans out of the user's own transcript, so it
    /// follows cleanup (permissive); a refusal there would only drop back to the single-stage cleanup.
    /// Answers, explanations, replies, classification and the optimizer keep `default`.
    public var guardrails: GuardrailsMode {
        switch self {
        case .cleanup, .proofreadRewrite, .translate, .transform, .summarize, .extract, .selfCorrection:
            return .permissiveContentTransformations
        case .explainAnalyze, .answerQuestion, .composeReply, .taskClassification, .unifiedCommand,
             .instructionOptimization:
            return .default
        }
    }
}

/// Language of a fixed prompt (V-05 compares Japanese and English instructions).
public enum PromptLanguage: String, CaseIterable, Sendable, Hashable, Codable {
    case ja
    case en

    /// Prompt language for the app's speech-recognition language setting (G1: fixed prompts follow the STT
    /// language, not the display or AI output language). Accepts BCP-47 codes such as "ja", "ja-JP",
    /// "en-US" or "en_GB". English STT → `.en`; Japanese and anything else → `.ja`.
    public init(sttLanguage: String) {
        let base = sttLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        self = base == "en" ? .en : .ja
    }
}
