import Foundation
import CryptoKit

/// Reproducibility metadata only. Missing provenance is explicit, never inferred.
struct RunManifest: Codable {
    var schemaVersion = 2
    var scoringRule = "accuracy-shared-fixed-grid-v2"
    var baselineProductRevision: String
    var toolRevision: String
    var appVersion: String
    var sourceRevision: String
    var sdkVersion: String
    var os: String
    var datasetSHA256: String
    var files: [String: String]

    static func capture(directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RunManifest {
        func metadata(_ key: String, pattern: String) -> String {
            guard let value = environment[key], value.range(of: pattern, options: .regularExpression) != nil else {
                return "unavailable"
            }
            return value
        }
        var files: [String: String] = [:]
        var combined = Data()
        for name in ["cleanup", "routing", "generation", "optimization", "long"].sorted() {
            let file = name + ".jsonl"
            let url = directory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files[file] = digest
            combined.append(Data((file + "\u{0}" + digest + "\n").utf8))
        }
        return RunManifest(
            baselineProductRevision: metadata("AFM_EVAL_BASELINE_PRODUCT_REVISION", pattern: #"^[a-fA-F0-9]{40,64}$"#),
            toolRevision: metadata("AFM_EVAL_TOOL_REVISION", pattern: #"^[a-fA-F0-9]{40,64}$"#),
            appVersion: metadata("AFM_EVAL_APP_VERSION", pattern: #"^[0-9]+(?:\.[0-9]+){1,3}$"#),
            sourceRevision: metadata("AFM_EVAL_SOURCE_REVISION", pattern: #"^[a-fA-F0-9]{40,64}$"#),
            sdkVersion: metadata("AFM_EVAL_SDK_VERSION", pattern: #"^[0-9]+(?:\.[0-9]+){0,3}$"#),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            datasetSHA256: SHA256.hash(data: combined).map { String(format: "%02x", $0) }.joined(), files: files
        )
    }
}
