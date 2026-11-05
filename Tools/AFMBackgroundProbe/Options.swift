import Foundation

enum ProbeMode: String, Sendable {
    case burst, chunks, interval
}

enum ProbePolicy: String, Sendable {
    case regular, accessory
}

struct ProbeOptions: Sendable {
    var mode: ProbeMode = .burst
    var policy: ProbePolicy = .regular
    var count = 10
    var rounds = 1
    var gapMs = 0
    var intervalS: Double = 1
    var outDir: URL

    /// Returns nil and a message when arguments are invalid.
    static func parse(_ args: [String]) -> (ProbeOptions?, String?) {
        var mode = ProbeMode.burst
        var policy = ProbePolicy.regular
        var count = 10
        var rounds = 1
        var gapMs = 0
        var intervalS = 1.0
        var out: String?
        var i = 0
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--mode":
                guard let v = next(), let m = ProbeMode(rawValue: v) else { return (nil, "invalid --mode") }
                mode = m
            case "--policy":
                guard let v = next(), let p = ProbePolicy(rawValue: v) else { return (nil, "invalid --policy") }
                policy = p
            case "--count":
                guard let v = next(), let n = Int(v), n > 0 else { return (nil, "invalid --count") }
                count = n
            case "--rounds":
                guard let v = next(), let n = Int(v), n > 0 else { return (nil, "invalid --rounds") }
                rounds = n
            case "--gap-ms":
                guard let v = next(), let n = Int(v), n >= 0 else { return (nil, "invalid --gap-ms") }
                gapMs = n
            case "--interval-s":
                guard let v = next(), let n = Double(v), n >= 0 else { return (nil, "invalid --interval-s") }
                intervalS = n
            case "--out":
                guard let v = next() else { return (nil, "missing --out value") }
                out = v
            default:
                // Ignore unknown arguments (e.g. LaunchServices-injected ones such as -psn_*).
                break
            }
            i += 1
        }
        guard let out else { return (nil, "--out is required") }
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        return (ProbeOptions(mode: mode, policy: policy, count: count, rounds: rounds,
                             gapMs: gapMs, intervalS: intervalS, outDir: url), nil)
    }
}
