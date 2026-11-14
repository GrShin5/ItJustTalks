import Foundation

/// Identifier of a fixed instruction. Each id exists in both `ja` and `en` (V-05).
public enum PromptID: String, CaseIterable, Sendable, Hashable, Codable {
    case cleanup
    case taskClassifier = "task_classifier"
    case proofreadRewrite = "task.proofread_rewrite"
    case translate = "task.translate"
    case transform = "task.transform"
    case summarize = "task.summarize"
    case extract = "task.extract"
    case explainAnalyze = "task.explain_analyze"
    case answerQuestion = "task.answer_question"
    case composeReply = "task.compose_reply"
    /// Single structured generation (taskType + outputIntent + body) for the V-07 comparison.
    case unifiedCommand = "unified_command"
    case instructionOptimizer = "instruction_optimizer"
    /// Stage A of the two-stage cleanup (spoken self-corrections as exact transcript spans).
    case selfCorrection = "self_correction"

    /// Fixed instruction used for a task.
    public init(task: AITask) {
        switch task {
        case .cleanup: self = .cleanup
        case .proofreadRewrite: self = .proofreadRewrite
        case .translate: self = .translate
        case .transform: self = .transform
        case .summarize: self = .summarize
        case .extract: self = .extract
        case .explainAnalyze: self = .explainAnalyze
        case .answerQuestion: self = .answerQuestion
        case .composeReply: self = .composeReply
        case .taskClassification: self = .taskClassifier
        case .unifiedCommand: self = .unifiedCommand
        case .instructionOptimization: self = .instructionOptimizer
        case .selfCorrection: self = .selfCorrection
        }
    }
}

/// A versioned fixed instruction. Record `key` with every evaluation result and diagnostic (§5.5).
public struct PromptTemplate: Sendable, Hashable {
    public let id: PromptID
    public let version: Int
    public let language: PromptLanguage
    public let text: String

    /// e.g. "cleanup@1/ja".
    public var key: String { "\(id.rawValue)@\(version)/\(language.rawValue)" }
}

/// Short, single-purpose fixed instructions (target ≤ 350 tokens each). Variable data never goes here:
/// it is placed in delimited prompt sections by `PromptAssembler`.
public enum PromptCatalog {
    public static func template(_ id: PromptID, language: PromptLanguage) -> PromptTemplate {
        PromptTemplate(id: id, version: version(of: id), language: language, text: text(id, language))
    }

    /// Template in the language that follows the app's speech-recognition language setting (G1).
    public static func template(_ id: PromptID, sttLanguage: String) -> PromptTemplate {
        template(id, language: PromptLanguage(sttLanguage: sttLanguage))
    }

    public static var all: [PromptTemplate] {
        PromptID.allCases.flatMap { id in PromptLanguage.allCases.map { template(id, language: $0) } }
    }

    /// Bump when the text of either language changes.
    public static func version(of id: PromptID) -> Int {
        switch id {
        // v2: self-corrections, fillers, request endings, examples (cleanup); keep every preference (optimizer).
        // v3 (cleanup): dictionary entries are applied to heard-as / same-sounding words; memo is reference only.
        // v5 (cleanup; v4 was a reverted 2026-10-15 experiment): keep every word except fillers / retractions,
        // no full stop after a single word or short phrase, emphatic やっぱり is not a correction.
        // v6: concise dictionary rule and punctuation / unfinished-utterance examples.
        case .cleanup:
            return 6
        // v2 also has a prompt-side retry section requesting fewer/shorter items; protect it from leakage.
        case .instructionOptimizer:
            return 2
        // v2 (self-correction): order (before / after the cue) stated explicitly, cue never a span.
        // v3: every correction in order, whole-statement retractions, "actually" and two-correction examples.
        case .selfCorrection:
            return 3
        // v2 (compose reply): complete the requested intent and context in the requested tone.
        // v3: answer the Target's question instead of copying it (English text only; Japanese text unchanged).
        case .composeReply:
            return 3
        case .taskClassifier, .proofreadRewrite, .translate, .transform, .summarize, .extract,
             .explainAnalyze, .answerQuestion, .unifiedCommand:
            return 1
        }
    }

    static func text(_ id: PromptID, _ language: PromptLanguage) -> String {
        switch language {
        case .ja: return PromptTextsJA.text(id)
        case .en: return PromptTextsEN.text(id)
        }
    }
}
