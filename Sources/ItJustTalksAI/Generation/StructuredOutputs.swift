import Foundation
import FoundationModels

// Small structured outputs. Case names are snake_case on purpose: they are the literal values the model
// sees in the generation schema and that the prompts in `PromptCatalog` refer to.

/// Task type returned by the task classifier (§3.2 step 3). The classifier only sees the spoken
/// instruction and whether a target exists — never the target text.
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
public enum UnifiedOutputIntent: String, Sendable, CaseIterable {
    case automatic
    case insert_at_captured_target
    case show_result
}

/// Single structured generation (taskType + outputIntent + body) compared against the split design in V-07.
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
public struct OptimizedInstructionItems: Sendable, Equatable {
    public var items: [String]

    public init(items: [String]) {
        self.items = items
    }
}

/// One spoken self-correction proposed by stage A of the two-stage cleanup (`SelfCorrection`). The app
/// verifies both texts against the transcript before using them.
public struct SelfCorrectionPair: Sendable, Equatable {
    public var retracted: String
    public var replacement: String

    public init(retracted: String, replacement: String) {
        self.retracted = retracted
        self.replacement = replacement
    }
}

/// Stage-A output: the self-corrections in a transcript (empty when there is none).
public struct SelfCorrectionList: Sendable, Equatable {
    public var corrections: [SelfCorrectionPair]

    public init(corrections: [SelfCorrectionPair]) {
        self.corrections = corrections
    }
}

/// A structured output contained an unknown enum value.
public struct StructuredOutputDecodingError: Error, Sendable, CustomStringConvertible {
    public let description: String

    public init(typeName: String, rawValue: String) {
        description = "Unknown \(typeName) raw value: \(rawValue)"
    }
}

extension ClassifiedTaskType: Generable {
    fileprivate static var dynamicSchema: DynamicGenerationSchema {
        DynamicGenerationSchema(name: "ClassifiedTaskType", anyOf: allCases.map(\.rawValue))
    }

    public static var generationSchema: GenerationSchema { cachedGenerationSchema }

    private static let cachedGenerationSchema = try! GenerationSchema(
        root: dynamicSchema, dependencies: []
    )

    public init(_ content: GeneratedContent) throws {
        let rawValue = try content.value(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw StructuredOutputDecodingError(typeName: "ClassifiedTaskType", rawValue: rawValue)
        }
        self = value
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(rawValue)
    }
}

extension TaskClassification: Generable {
    fileprivate static var dynamicSchema: DynamicGenerationSchema {
        DynamicGenerationSchema(name: "TaskClassification", properties: [
            .init(name: "taskType", schema: DynamicGenerationSchema(referenceTo: "ClassifiedTaskType")),
            .init(name: "isReplacementArtifact", schema: DynamicGenerationSchema(type: Bool.self)),
        ])
    }

    public static var generationSchema: GenerationSchema { cachedGenerationSchema }

    private static let cachedGenerationSchema = try! GenerationSchema(
        root: dynamicSchema, dependencies: [ClassifiedTaskType.dynamicSchema]
    )

    public init(_ content: GeneratedContent) throws {
        self.taskType = try content.value(ClassifiedTaskType.self, forProperty: "taskType")
        self.isReplacementArtifact = try content.value(Bool.self, forProperty: "isReplacementArtifact")
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "taskType": taskType,
            "isReplacementArtifact": isReplacementArtifact,
        ])
    }
}

extension UnifiedOutputIntent: Generable {
    fileprivate static var dynamicSchema: DynamicGenerationSchema {
        DynamicGenerationSchema(name: "UnifiedOutputIntent", anyOf: allCases.map(\.rawValue))
    }

    public static var generationSchema: GenerationSchema { cachedGenerationSchema }

    private static let cachedGenerationSchema = try! GenerationSchema(
        root: dynamicSchema, dependencies: []
    )

    public init(_ content: GeneratedContent) throws {
        let rawValue = try content.value(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw StructuredOutputDecodingError(typeName: "UnifiedOutputIntent", rawValue: rawValue)
        }
        self = value
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(rawValue)
    }
}

extension UnifiedCommandResult: Generable {
    fileprivate static var dynamicSchema: DynamicGenerationSchema {
        DynamicGenerationSchema(name: "UnifiedCommandResult", properties: [
            .init(name: "taskType", schema: DynamicGenerationSchema(referenceTo: "ClassifiedTaskType")),
            .init(name: "outputIntent", schema: DynamicGenerationSchema(referenceTo: "UnifiedOutputIntent")),
            .init(name: "body", schema: DynamicGenerationSchema(type: String.self)),
        ])
    }

    public static var generationSchema: GenerationSchema { cachedGenerationSchema }

    private static let cachedGenerationSchema = try! GenerationSchema(
        root: dynamicSchema, dependencies: [ClassifiedTaskType.dynamicSchema, UnifiedOutputIntent.dynamicSchema]
    )

    public init(_ content: GeneratedContent) throws {
        self.taskType = try content.value(ClassifiedTaskType.self, forProperty: "taskType")
        self.outputIntent = try content.value(UnifiedOutputIntent.self, forProperty: "outputIntent")
        self.body = try content.value(String.self, forProperty: "body")
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "taskType": taskType,
            "outputIntent": outputIntent,
            "body": body,
        ])
    }
}

extension OptimizedInstructionItems: Generable {
    fileprivate static var dynamicSchema: DynamicGenerationSchema {
        DynamicGenerationSchema(name: "OptimizedInstructionItems", properties: [
            .init(name: "items", description: "Short style preferences, one per item", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), maximumElements: 5)),
        ])
    }

    public static var generationSchema: GenerationSchema { cachedGenerationSchema }

    private static let cachedGenerationSchema = try! GenerationSchema(
        root: dynamicSchema, dependencies: []
    )

    public init(_ content: GeneratedContent) throws {
        self.items = try content.value([String].self, forProperty: "items")
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "items": items,
        ])
    }
}

extension SelfCorrectionPair: Generable {
    fileprivate static var dynamicSchema: DynamicGenerationSchema {
        DynamicGenerationSchema(name: "SelfCorrectionPair", properties: [
            .init(name: "retracted", description: "Words the speaker took back, copied exactly from the transcript", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "replacement", description: "Words that replace them, copied exactly from the transcript", schema: DynamicGenerationSchema(type: String.self)),
        ])
    }

    public static var generationSchema: GenerationSchema { cachedGenerationSchema }

    private static let cachedGenerationSchema = try! GenerationSchema(
        root: dynamicSchema, dependencies: []
    )

    public init(_ content: GeneratedContent) throws {
        self.retracted = try content.value(String.self, forProperty: "retracted")
        self.replacement = try content.value(String.self, forProperty: "replacement")
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "retracted": retracted,
            "replacement": replacement,
        ])
    }
}

extension SelfCorrectionList: Generable {
    fileprivate static var dynamicSchema: DynamicGenerationSchema {
        DynamicGenerationSchema(name: "SelfCorrectionList", properties: [
            .init(name: "corrections", description: "Self-corrections in order; empty if none", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "SelfCorrectionPair"), maximumElements: 4)),
        ])
    }

    public static var generationSchema: GenerationSchema { cachedGenerationSchema }

    private static let cachedGenerationSchema = try! GenerationSchema(
        root: dynamicSchema, dependencies: [SelfCorrectionPair.dynamicSchema]
    )

    public init(_ content: GeneratedContent) throws {
        self.corrections = try content.value([SelfCorrectionPair].self, forProperty: "corrections")
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "corrections": corrections,
        ])
    }
}
