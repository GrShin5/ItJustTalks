import AppKit
import Foundation
import FoundationModels

/// Classifies an error into a short outcome code without including any message text.
func classify(_ error: any Error) -> String {
    let typeName = String(describing: type(of: error))
    let known: Set<String> = ["LanguageModelError", "GenerationError", "SystemLanguageModel.Error",
                              "LanguageModelSession.Error", "Error"]
    let isFM = known.contains(typeName)
        || String(reflecting: type(of: error)).hasPrefix("FoundationModels.")
    guard isFM else { return "other:\(typeName)" }
    let mirror = Mirror(reflecting: error)
    if mirror.displayStyle == .enum {
        if let label = mirror.children.first?.label { return label }
        // Payload-less case: the description is exactly the case name.
        return String(describing: error)
    }
    return "other:\(typeName)"
}

@MainActor
final class ProbeRunner {
    let options: ProbeOptions
    private var records: [RequestRecord] = []
    private var resultsHandle: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let startedAt = iso8601Now()

    init(options: ProbeOptions) {
        self.options = options
    }

    private func prepareOutput() throws {
        try FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
        let url = options.outDir.appendingPathComponent("results.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        resultsHandle = try FileHandle(forWritingTo: url)
    }

    private func availabilityString(_ model: SystemLanguageModel) -> String {
        switch model.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return "unavailable:\(reason)"
        }
    }

    private func modelFacts(_ model: SystemLanguageModel) -> (contextSize: Int?, variant: String?) {
        var variant: String?
        if #available(macOS 27, *) {
            variant = model.variant.displayName
        }
        return (model.contextSize, variant)
    }

    private func writeSummary(model: SystemLanguageModel, setupFailure: String?) {
        var counts: [String: Int] = [:]
        for r in records { counts[r.outcome, default: 0] += 1 }
        let latencies = records.map(\.latencyMs)
        let facts = modelFacts(model)
        let summary = SummaryRecord(
            mode: options.mode.rawValue,
            policy: options.policy.rawValue,
            requested: expectedTotal(),
            completed: records.count,
            outcomeCounts: counts,
            latencyP50Ms: Stats.percentile(latencies, 50),
            latencyP95Ms: Stats.percentile(latencies, 95),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            availability: availabilityString(model),
            contextSize: facts.contextSize,
            variant: facts.variant,
            startedAt: startedAt,
            finishedAt: iso8601Now(),
            allProbeNeverFrontmost: records.allSatisfy { !$0.probeIsFrontmost },
            setupFailure: setupFailure
        )
        let url = options.outDir.appendingPathComponent("summary.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? enc.encode(summary) {
            try? data.write(to: url)
        }
    }

    private func expectedTotal() -> Int {
        switch options.mode {
        case .burst, .interval: return options.count
        case .chunks: return options.count * options.rounds
        }
    }

    private func finish(model: SystemLanguageModel, setupFailure: String?) -> Never {
        writeSummary(model: model, setupFailure: setupFailure)
        try? resultsHandle?.close()
        exit(setupFailure == nil ? 0 : 1)
    }

    func run() async {
        let model = SystemLanguageModel.default
        do {
            try prepareOutput()
        } catch {
            // Output dir unusable: nothing can be written.
            FileHandle.standardError.write(Data("setup failure: cannot create output\n".utf8))
            exit(1)
        }
        guard case .available = model.availability else {
            finish(model: model, setupFailure: "model \(availabilityString(model))")
        }

        var index = 0
        switch options.mode {
        case .burst:
            for _ in 0..<options.count {
                await generate(model: model, index: index, round: 0, input: ProbeInputs.short(index))
                index += 1
            }
        case .chunks:
            for round in 0..<options.rounds {
                for _ in 0..<options.count {
                    await generate(model: model, index: index, round: round, input: ProbeInputs.medium(index))
                    index += 1
                }
                if round < options.rounds - 1, options.gapMs > 0 {
                    try? await Task.sleep(for: .milliseconds(options.gapMs))
                }
            }
        case .interval:
            for n in 0..<options.count {
                await generate(model: model, index: index, round: 0, input: ProbeInputs.short(index))
                index += 1
                if n < options.count - 1 {
                    try? await Task.sleep(for: .seconds(options.intervalS))
                }
            }
        }
        finish(model: model, setupFailure: nil)
    }

    private func generate(model: SystemLanguageModel, index: Int, round: Int, input: String) async {
        let start = iso8601Now()
        let clock = ContinuousClock()
        let t0 = clock.now
        var outcome = "ok"
        var chars = 0
        var resetInS: Double?
        do {
            let session = LanguageModelSession(model: model, instructions: ProbeInputs.instructions)
            let options = GenerationOptions(samplingMode: .greedy)
            let response = try await session.respond(to: input, options: options)
            chars = response.content.count
        } catch {
            outcome = classify(error)
            if #available(macOS 27, *),
               case .rateLimited(let info) = error as? LanguageModelError, let reset = info.resetDate {
                resetInS = (reset.timeIntervalSinceNow * 10).rounded() / 10
            }
        }
        let elapsed = clock.now - t0
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let myId = Bundle.main.bundleIdentifier
        let record = RequestRecord(
            index: index,
            mode: self.options.mode.rawValue,
            round: round,
            startTime: start,
            latencyMs: (ms * 10).rounded() / 10,
            outcome: outcome,
            outputChars: chars,
            appIsActive: NSApp.isActive,
            frontmostBundleId: frontmost,
            probeIsFrontmost: frontmost != nil && frontmost == myId,
            rateLimitResetInS: resetInS
        )
        records.append(record)
        if var line = try? encoder.encode(record) {
            line.append(0x0A)
            try? resultsHandle?.write(contentsOf: line)
        }
    }
}
