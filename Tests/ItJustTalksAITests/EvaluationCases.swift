import Foundation

/// Loads the synthetic evaluation cases (`Evaluation/cases/*.jsonl`) relative to this source file.
enum EvaluationCases {
    static var casesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ItJustTalksAITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Evaluation/cases", isDirectory: true)
    }

    static func load(_ name: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: casesDirectory.appendingPathComponent("\(name).jsonl"))
        let text = String(decoding: data, as: UTF8.self)
        return try text.split(separator: "\n").map { line in
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return object
        }
    }
}
