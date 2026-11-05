import Foundation
import ItJustTalksAI

struct CaseMeta: Sendable {
    var id: String
    var category: EvalCategory
    var lang: String
    var critical: Bool
}

struct DictionaryCaseEntry: Sendable {
    var preferred: String
    var readings: [String]
    var memo: String?
}

struct CleanupCase: Sendable {
    var meta: CaseMeta
    var transcript: String
    var customInstruction: String?
    var dictionary: [DictionaryCaseEntry]
    var outputLanguage: String
    var handsFree: Bool
    var mustContain: [String]
    var mustNotContain: [String]
    var language: String
    var noAnswer: Bool
    var correction: (old: String, new: String)?
}

struct RoutingCase: Sendable {
    var meta: CaseMeta
    var instruction: String
    var target: String?
    var expectedIntent: String
    var expectedTaskType: String
    var expectedKind: String
    var injection: Bool
}

struct GenerationCase: Sendable {
    var meta: CaseMeta
    var instruction: String
    var target: String?
    var taskType: String
    var outputLanguage: String
    var mustContain: [String]
    var mustNotContain: [String]
    var language: String
    var maxLengthRatio: Double?
}

struct OptimizationCase: Sendable {
    var meta: CaseMeta
    var draft: String
    var dictionary: [DictionaryCaseEntry]
    var maxItems: Int
    var maxGraphemes: Int
    var mustPreserve: [String]
    var flagsPermissionItems: Bool
    var mode: CustomInstructionKind = .cleanup
    var permissionFlaggedIndices: [Int]? = nil
    var permissionFlaggedItems: [String]? = nil
}

struct LongCase: Sendable {
    var handsFree: Bool
    var reviewAcceptable: Bool
    var corrections: [LongCorrection]
    var meta: CaseMeta
    var isTranscript: Bool
    var durationSec: Int?
    var targetChars: Int?
    var instruction: String?
    var text: String
    var checkpoints: [String]
    var language: String
}

struct LongCorrection: Sendable {
    var old: String
    var new: String
}

enum CaseLoader {
    enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)
        var description: String {
            switch self {
            case .unreadable(let name): return "cannot read \(name)"
            case .malformed(let detail): return "malformed case: \(detail)"
            }
        }
    }

    private typealias JSON = [String: Any]

    private static func rows(_ directory: URL, _ category: EvalCategory) throws -> [JSON] {
        let url = directory.appendingPathComponent("\(category.rawValue).jsonl")
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable("\(category.rawValue).jsonl") }
        var result: [JSON] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSON else {
                throw LoadError.malformed("\(category.rawValue).jsonl line")
            }
            result.append(object)
        }
        return result
    }

    private static func meta(_ row: JSON, _ category: EvalCategory) throws -> CaseMeta {
        guard let id = row["id"] as? String else { throw LoadError.malformed("id") }
        return CaseMeta(
            id: id, category: category, lang: row["lang"] as? String ?? "ja", critical: row["critical"] as? Bool ?? false
        )
    }

    private static func strings(_ value: Any?) -> [String] { value as? [String] ?? [] }

    private static func dictionary(_ value: Any?) -> [DictionaryCaseEntry] {
        (value as? [JSON] ?? []).compactMap { entry in
            guard let preferred = entry["preferred"] as? String else { return nil }
            return DictionaryCaseEntry(preferred: preferred, readings: strings(entry["readings"]), memo: entry["memo"] as? String)
        }
    }

    static func cleanup(_ directory: URL) throws -> [CleanupCase] {
        try rows(directory, .cleanup).map { row in
            let input = row["input"] as? JSON ?? [:]
            let expect = row["expect"] as? JSON ?? [:]
            var correction: (old: String, new: String)?
            if let value = expect["correction"] as? JSON, let old = value["old"] as? String, let new = value["new"] as? String {
                correction = (old, new)
            }
            return CleanupCase(
                meta: try meta(row, .cleanup),
                transcript: input["transcript"] as? String ?? "",
                customInstruction: input["customInstruction"] as? String,
                dictionary: dictionary(input["dictionary"]),
                outputLanguage: input["outputLanguage"] as? String ?? "auto",
                handsFree: input["handsFree"] as? Bool ?? false,
                mustContain: strings(expect["mustContain"]),
                mustNotContain: strings(expect["mustNotContain"]),
                language: expect["language"] as? String ?? "ja",
                noAnswer: expect["noAnswer"] as? Bool ?? false,
                correction: correction
            )
        }
    }

    static func routing(_ directory: URL) throws -> [RoutingCase] {
        try rows(directory, .routing).map { row in
            let input = row["input"] as? JSON ?? [:]
            let expect = row["expect"] as? JSON ?? [:]
            return RoutingCase(
                meta: try meta(row, .routing),
                instruction: input["instruction"] as? String ?? "",
                target: input["target"] as? String,
                expectedIntent: expect["outputIntent"] as? String ?? "automatic",
                expectedTaskType: expect["taskType"] as? String ?? "",
                expectedKind: expect["kind"] as? String ?? "",
                injection: expect["injection"] as? Bool ?? false
            )
        }
    }

    static func generation(_ directory: URL) throws -> [GenerationCase] {
        try rows(directory, .generation).map { row in
            let input = row["input"] as? JSON ?? [:]
            let expect = row["expect"] as? JSON ?? [:]
            return GenerationCase(
                meta: try meta(row, .generation),
                instruction: input["instruction"] as? String ?? "",
                target: input["target"] as? String,
                taskType: input["taskType"] as? String ?? "",
                outputLanguage: input["outputLanguage"] as? String ?? "auto",
                mustContain: strings(expect["mustContain"]),
                mustNotContain: strings(expect["mustNotContain"]),
                language: expect["language"] as? String ?? "ja",
                maxLengthRatio: expect["maxLengthRatio"] as? Double
            )
        }
    }

    static func optimization(_ directory: URL) throws -> [OptimizationCase] {
        try rows(directory, .optimization).map { row in
            let input = row["input"] as? JSON ?? [:]
            let expect = row["expect"] as? JSON ?? [:]
            let modeValue = input["mode"] as? String ?? "cleanup"
            guard let mode = CustomInstructionKind(rawValue: modeValue) else {
                throw LoadError.malformed("optimization mode")
            }
            if let flags = expect["permissionFlaggedIndices"],
               !(flags is [Int]) { throw LoadError.malformed("permissionFlaggedIndices") }
            return OptimizationCase(
                meta: try meta(row, .optimization),
                draft: input["draft"] as? String ?? "",
                dictionary: dictionary(input["dictionary"]),
                maxItems: expect["maxItems"] as? Int ?? 5,
                maxGraphemes: expect["maxGraphemes"] as? Int ?? 500,
                mustPreserve: strings(expect["mustPreserve"]),
                flagsPermissionItems: expect["flagsPermissionItems"] as? Bool ?? false,
                mode: mode,
                permissionFlaggedIndices: expect["permissionFlaggedIndices"] as? [Int],
                permissionFlaggedItems: expect["permissionFlaggedItems"] as? [String]
            )
        }
    }

    static func long(_ directory: URL) throws -> [LongCase] {
        try rows(directory, .long).map { row in
            let input = row["input"] as? JSON ?? [:]
            let expect = row["expect"] as? JSON ?? [:]
            return LongCase(
                handsFree: input["handsFree"] as? Bool ?? false,
                reviewAcceptable: expect["reviewAcceptable"] as? Bool ?? false,
                corrections: try (expect["corrections"] as? [JSON] ?? []).map { correction in
                    guard let old = correction["old"] as? String, !old.isEmpty,
                          let new = correction["new"] as? String, !new.isEmpty else {
                        throw LoadError.malformed("long correction fields")
                    }
                    return LongCorrection(old: old, new: new)
                },
                meta: try meta(row, .long),
                isTranscript: (input["kind"] as? String) == "transcript",
                durationSec: input["durationSec"] as? Int,
                targetChars: input["targetChars"] as? Int,
                instruction: input["instruction"] as? String,
                text: input["text"] as? String ?? "",
                checkpoints: strings(expect["checkpoints"]),
                language: expect["language"] as? String ?? "ja"
            )
        }
    }
}
