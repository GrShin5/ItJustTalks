import Foundation

struct RequestRecord: Codable, Sendable {
    var index: Int
    var mode: String
    var round: Int
    var startTime: String
    var latencyMs: Double
    var outcome: String
    var outputChars: Int
    var appIsActive: Bool
    var frontmostBundleId: String?
    var probeIsFrontmost: Bool
    /// Seconds until the reported reset date, only for `rateLimited` (nil when absent).
    var rateLimitResetInS: Double?
}

struct SummaryRecord: Codable, Sendable {
    var mode: String
    var policy: String
    var requested: Int
    var completed: Int
    var outcomeCounts: [String: Int]
    var latencyP50Ms: Double?
    var latencyP95Ms: Double?
    var osVersion: String
    var availability: String
    var contextSize: Int?
    var variant: String?
    var startedAt: String
    var finishedAt: String
    var allProbeNeverFrontmost: Bool
    var setupFailure: String?
}

enum Stats {
    /// Nearest-rank percentile on an unsorted list.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p / 100.0 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

func iso8601Now() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}
