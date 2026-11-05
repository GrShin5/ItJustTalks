import Foundation
import ItJustTalksAI

struct SettingsRecord: Codable, Sendable {
    var contextLimit: Int? = nil
    var chunkContext: String? = nil
    var promptLang: String
    var guardrails: String
    var commandMethod: String
    var correctionMethod: String? = nil
    var dictionaryMemo: Bool
    var fake: Bool
}

struct ModelRecord: Codable, Sendable {
    var variant: String?
    var contextSize: Int
    var os: String
    var hardwareModel: String?
    var memoryGB: Int
}

struct ValidatorRecord: Codable, Sendable {
    /// complete | needsReview | failed
    var status: String
    /// Reason case names only (no payload text).
    var reasons: [String]
}

struct JudgeRecord: Codable, Sendable {
    var pass: Bool
    var failedChecks: [String]
    var strictLanguagePass: Bool? = nil
}

struct RoutingRecord: Codable, Sendable {
    var hasTarget: Bool
    var injection: Bool
    var expectedIntent: String
    var predictedIntent: String?
    var expectedTaskType: String
    var predictedTaskType: String?
    var expectedKind: String
    var predictedKind: String?
    var webPrecheck: Bool?
    var classifierFallback: Bool?
    var wrongAutoReplace: Bool?
    /// Raw classifier output before the library's deterministic overrides (nil when not classified).
    var classifierTaskType: String? = nil
    var classifierReplacement: Bool? = nil
}

/// One evaluation result. Contains codes, numbers and ids only: never case text.
struct EvalRecord: Codable, Sendable {
    var generationPath: String? = nil
    var optimizationMode: String? = nil
    var permissionFlaggedIndices: [Int]? = nil
    var calls: [EvalCallRecord]? = nil
    /// Wall time, including budgeting, retries and merges (long category).
    var totalLatencyMs: Double? = nil
    var id: String
    var category: String
    var lang: String
    var critical: Bool
    var run: Int
    var settings: SettingsRecord
    var model: ModelRecord
    /// Long: complete | needsReview | failed. Other categories: ok | failure | needsChunking | budgetImpossible.
    var outcome: String
    var failureCode: String?
    var validator: ValidatorRecord?
    var judge: JudgeRecord?
    /// Summed generation latency of the case's model calls.
    var latencyMs: Double?
    /// True when the case's first model call was the first generation in this process.
    var cold: Bool?
    var inputTokens: Int?
    var outputTokens: Int?
    var truncated: Bool
    var promptKeys: [String]
    var routing: RoutingRecord?
    /// Extra numeric measurements (checkpoint survival, item counts, budget numbers …).
    var measures: [String: Double]
    /// Dictionary entries handed to the model / omitted (counts).
    var dictionarySelected: Int?
    var dictionaryOmitted: Int?
}

struct EvalCallRecord: Codable, Sendable {
    var stage: String
    var latencyMs: Double
    var inputTokens: Int?
    var outputTokens: Int?
    var truncated: Bool
    var failureCode: String?
}

/// Output text for human review (synthetic data only). Kept in a separate file.
struct OutputRecord: Codable, Sendable {
    var id: String
    var run: Int
    var category: String
    var text: String
    /// Stage-A raw result of the two-stage cleanup (proposals or corrected transcript), for review only.
    var stageA: String? = nil
    // Portable producer-neutral metadata. Routing labels use afm-eval raw values.
    var outcome: String? = nil
    var failureCode: String? = nil
    var validator: ValidatorRecord? = nil
    var routing: RoutingRecord? = nil
    var permissionFlaggedIndices: [Int]? = nil
    var items: [String]? = nil
    /// oracle (labelled task) | e2e (instruction through classifier).
    var generationPath: String? = nil
}

enum JSONLines {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return encoder
    }()

    static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

/// Append-only JSONL writer.
final class JSONLinesFile {
    private let handle: FileHandle

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append<T: Encodable>(_ value: T) throws {
        try handle.write(contentsOf: JSONLines.line(value))
    }

    func close() {
        try? handle.close()
    }
}
