import Foundation

struct LatencyStats: Codable, Sendable {
    var n: Int
    var p50Ms: Double?
    var p95Ms: Double?
    var maxMs: Double?

    init(_ values: [Double]) {
        let sorted = values.sorted()
        n = sorted.count
        p50Ms = Self.percentile(sorted, 0.50)
        p95Ms = Self.percentile(sorted, 0.95)
        maxMs = sorted.last
    }

    /// Nearest-rank percentile.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}

struct PassStats: Codable, Sendable {
    /// Records with a judgement (needsChunking records are not judged).
    var evaluated = 0
    var passed = 0
    var needsChunking = 0
    /// Judge passed and the validator accepted the result as `complete`.
    var acceptedByValidator = 0
    /// Judged records that went through the validator (routing has none).
    var validated = 0
    var rate: Double? { evaluated == 0 ? nil : Double(passed) / Double(evaluated) }
    var acceptedRate: Double? { validated == 0 ? nil : Double(acceptedByValidator) / Double(validated) }

    enum CodingKeys: String, CodingKey { case evaluated, passed, needsChunking, acceptedByValidator, validated, rate, acceptedRate }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(evaluated, forKey: .evaluated)
        try container.encode(passed, forKey: .passed)
        try container.encode(needsChunking, forKey: .needsChunking)
        try container.encode(acceptedByValidator, forKey: .acceptedByValidator)
        try container.encode(validated, forKey: .validated)
        try container.encodeIfPresent(rate, forKey: .rate)
        try container.encodeIfPresent(acceptedRate, forKey: .acceptedRate)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        evaluated = try container.decode(Int.self, forKey: .evaluated)
        passed = try container.decode(Int.self, forKey: .passed)
        needsChunking = try container.decode(Int.self, forKey: .needsChunking)
        acceptedByValidator = try container.decode(Int.self, forKey: .acceptedByValidator)
        validated = try container.decode(Int.self, forKey: .validated)
    }

    mutating func add(_ record: EvalRecord) {
        if record.outcome == "needsChunking" {
            needsChunking += 1
            return
        }
        guard let judge = record.judge else { return }
        evaluated += 1
        if record.validator != nil { validated += 1 }
        if judge.pass {
            passed += 1
            if record.validator?.status == "complete" { acceptedByValidator += 1 }
        }
    }
}

struct RefusalStats: Codable, Sendable {
    /// Cases where the model was called (successfully or not).
    var attempted = 0
    var refusalErrors = 0
    var guardrailErrors = 0
    var refusalPhraseRejects = 0
    var falseRefusalCases = 0
    var falseRefusalRate: Double?
}

struct CriticalStats: Codable, Sendable {
    var cases = 0
    var allRunsPassed = 0
    var failingIds: [String] = []
}

struct ConfusionCounts: Codable, Sendable {
    /// "expected -> predicted" : count
    var intent: [String: Int] = [:]
    var taskType: [String: Int] = [:]
    var kind: [String: Int] = [:]
}

struct RoutingSummary: Codable, Sendable {
    var evaluated = 0
    var outputIntentCorrect = 0
    var taskTypeCorrect = 0
    var kindCorrect = 0
    var allCorrect = 0
    var webPrecheckFired = 0
    var classifierFallbacks = 0
    /// Predicted content + automatic with a target where the label says otherwise.
    var wrongAutoReplace = 0
    var wrongAutoReplaceIds: [String] = []
    var expectedContentAutomatic = 0
    var predictedContentAutomaticHits = 0
    var contentAutomaticRecall: Double?
    var confusion = ConfusionCounts()
}

struct Summary: Codable, Sendable {
    var long: LongSummary? = nil
    var settings: SettingsRecord
    var model: ModelRecord
    var records: Int
    var outcomes: [String: Int]
    var passByCategory: [String: PassStats]
    var passByCategoryAndLang: [String: PassStats]
    var latencyCold: LatencyStats
    var latencyWarm: LatencyStats
    var latencyByCategory: [String: [String: LatencyStats]]
    var refusal: RefusalStats
    var failuresByCode: [String: Int]
    var validatorStatus: [String: Int]
    var validatorReasons: [String: Int]
    var critical: CriticalStats
    var routing: RoutingSummary?
    var averageInputTokens: Double?
    var averageOutputTokens: Double?
    var truncatedCount: Int
}

struct LongSummary: Codable, Sendable {
    struct Row: Codable, Sendable {
        var id: String
        var run: Int
        var pass: Bool
        var chunkCount: Int
        var outcome: String
        var totalSeconds: Double?
    }
    var cases: [Row]
    /// Counts failing runs, not individual missing or repeated checkpoints.
    var lossFailures: Int
    var duplicationFailures: Int
    var correctionLeakedAutomatic: Int

    init(_ records: [EvalRecord]) {
        cases = records.map { record in
            Row(id: record.id, run: record.run, pass: record.judge?.pass == true,
                chunkCount: Int(record.measures["chunk.count"] ?? 1), outcome: record.outcome,
                totalSeconds: record.totalLatencyMs.map { $0 / 1000 })
        }
        lossFailures = records.filter { $0.judge?.failedChecks.contains("loss") == true }.count
        duplicationFailures = records.filter { $0.judge?.failedChecks.contains(where: { $0.hasPrefix("duplicate") }) == true }.count
        correctionLeakedAutomatic = records.filter { $0.judge?.failedChecks.contains("correctionLeakedAutomatic") == true }.count
    }
}

enum SummaryBuilder {
    static func build(records: [EvalRecord], settings: SettingsRecord, model: ModelRecord) -> Summary {
        var outcomes: [String: Int] = [:]
        var byCategory: [String: PassStats] = [:]
        var byCategoryLang: [String: PassStats] = [:]
        var failures: [String: Int] = [:]
        var statuses: [String: Int] = [:]
        var reasons: [String: Int] = [:]
        var cold: [Double] = []
        var warm: [Double] = []
        var latencyByCategory: [String: [String: [Double]]] = [:]
        var refusal = RefusalStats()
        var inputTokens: [Double] = []
        var outputTokens: [Double] = []

        for record in records {
            outcomes[record.outcome, default: 0] += 1
            byCategory[record.category, default: PassStats()].add(record)
            byCategoryLang["\(record.category)/\(record.lang)", default: PassStats()].add(record)
            if let code = record.failureCode { failures[code, default: 0] += 1 }
            if let validator = record.validator {
                statuses[validator.status, default: 0] += 1
                for reason in validator.reasons { reasons[reason, default: 0] += 1 }
            }
            if ["ok", "complete", "needsReview"].contains(record.outcome), let latency = record.latencyMs, let isCold = record.cold {
                if isCold { cold.append(latency) } else { warm.append(latency) }
                latencyByCategory[record.category, default: [:]][isCold ? "cold" : "warm", default: []].append(latency)
            }
            if let value = record.inputTokens { inputTokens.append(Double(value)) }
            if let value = record.outputTokens { outputTokens.append(Double(value)) }

            if record.latencyMs != nil {
                refusal.attempted += 1
                var isRefusal = false
                if record.failureCode == "refusal" { refusal.refusalErrors += 1; isRefusal = true }
                if record.failureCode == "guardrailViolation" { refusal.guardrailErrors += 1; isRefusal = true }
                if record.validator?.reasons.contains("refusalPhrase") == true, record.failureCode == nil {
                    refusal.refusalPhraseRejects += 1
                    isRefusal = true
                }
                if isRefusal { refusal.falseRefusalCases += 1 }
            }
        }
        if refusal.attempted > 0 { refusal.falseRefusalRate = Double(refusal.falseRefusalCases) / Double(refusal.attempted) }

        // Critical cases: every run must pass.
        var runsById: [String: [EvalRecord]] = [:]
        for record in records where record.critical { runsById[record.id, default: []].append(record) }
        var critical = CriticalStats()
        for (id, runs) in runsById.sorted(by: { $0.key < $1.key }) {
            let judged = runs.filter { $0.outcome != "needsChunking" }
            guard !judged.isEmpty else { continue }
            critical.cases += 1
            if judged.allSatisfy({ $0.judge?.pass == true }) { critical.allRunsPassed += 1 } else { critical.failingIds.append(id) }
        }

        var latencyOut: [String: [String: LatencyStats]] = [:]
        for (category, parts) in latencyByCategory {
            latencyOut[category] = parts.mapValues { LatencyStats($0) }
        }

        return Summary(
            long: records.contains(where: { $0.category == "long" }) ? LongSummary(records.filter { $0.category == "long" }) : nil,
            settings: settings, model: model, records: records.count, outcomes: outcomes,
            passByCategory: byCategory, passByCategoryAndLang: byCategoryLang,
            latencyCold: LatencyStats(cold), latencyWarm: LatencyStats(warm), latencyByCategory: latencyOut,
            refusal: refusal, failuresByCode: failures, validatorStatus: statuses, validatorReasons: reasons,
            critical: critical, routing: routingSummary(records.filter { $0.category == "routing" && $0.routing != nil }),
            averageInputTokens: inputTokens.isEmpty ? nil : inputTokens.reduce(0, +) / Double(inputTokens.count),
            averageOutputTokens: outputTokens.isEmpty ? nil : outputTokens.reduce(0, +) / Double(outputTokens.count),
            truncatedCount: records.filter(\.truncated).count
        )
    }

    private static func routingSummary(_ records: [EvalRecord]) -> RoutingSummary? {
        guard !records.isEmpty else { return nil }
        var summary = RoutingSummary()
        for record in records {
            guard let routing = record.routing else { continue }
            summary.evaluated += 1
            let intentOK = routing.predictedIntent == routing.expectedIntent
            let taskOK = routing.predictedTaskType == routing.expectedTaskType
            let kindOK = routing.predictedKind == routing.expectedKind
            if intentOK { summary.outputIntentCorrect += 1 }
            if taskOK { summary.taskTypeCorrect += 1 }
            if kindOK { summary.kindCorrect += 1 }
            if intentOK && taskOK && kindOK { summary.allCorrect += 1 }
            if routing.webPrecheck == true { summary.webPrecheckFired += 1 }
            if routing.classifierFallback == true { summary.classifierFallbacks += 1 }
            if routing.wrongAutoReplace == true {
                summary.wrongAutoReplace += 1
                summary.wrongAutoReplaceIds.append(record.id)
            }
            if routing.hasTarget && routing.expectedKind == "content" && routing.expectedIntent == "automatic" {
                summary.expectedContentAutomatic += 1
                if routing.predictedKind == "content" && routing.predictedIntent == "automatic" {
                    summary.predictedContentAutomaticHits += 1
                }
            }
            summary.confusion.intent["\(routing.expectedIntent) -> \(routing.predictedIntent ?? "none")", default: 0] += 1
            summary.confusion.taskType["\(routing.expectedTaskType) -> \(routing.predictedTaskType ?? "none")", default: 0] += 1
            summary.confusion.kind["\(routing.expectedKind) -> \(routing.predictedKind ?? "none")", default: 0] += 1
        }
        if summary.expectedContentAutomatic > 0 {
            summary.contentAutomaticRecall = Double(summary.predictedContentAutomaticHits) / Double(summary.expectedContentAutomatic)
        }
        return summary
    }

    // MARK: - Markdown

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f%%", value * 100)
    }

    private static func ms(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.0f", value)
    }

    private static func table(_ header: [String], _ rows: [[String]]) -> String {
        var lines = ["| " + header.joined(separator: " | ") + " |", "|" + header.map { _ in " --- " }.joined(separator: "|") + "|"]
        lines += rows.map { "| " + $0.joined(separator: " | ") + " |" }
        return lines.joined(separator: "\n")
    }

    static func markdown(_ summary: Summary) -> String {
        var out: [String] = []
        let settings = summary.settings
        out.append("# afm-eval summary")
        out.append("""
        - settings: prompt-lang `\(settings.promptLang)`, guardrails `\(settings.guardrails)`, command-method `\(settings.commandMethod)`, correction-method `\(settings.correctionMethod ?? "-")`, dictionary-memo \(settings.dictionaryMemo ? "on" : "off"), fake \(settings.fake)
        - model: variant `\(summary.model.variant ?? "-")`, contextSize \(summary.model.contextSize), OS `\(summary.model.os)`, hardware `\(summary.model.hardwareModel ?? "-")`, memory \(summary.model.memoryGB) GB
        - records: \(summary.records); outcomes: \(summary.outcomes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        """)

        out.append("## Pass rate by category")
        out.append("Judge = checks against `expect`. Legacy needsChunking records are counted separately. Failures, refusals and empty outputs are included as failed.")
        out.append(table(
            ["category", "evaluated", "passed", "pass rate", "judge pass + validator complete (of validated)", "needsChunking"],
            summary.passByCategory.sorted { $0.key < $1.key }.map { [
                $0.key, "\($0.value.evaluated)", "\($0.value.passed)", percent($0.value.rate),
                percent($0.value.acceptedRate), "\($0.value.needsChunking)",
            ] }
        ))
        out.append("## Pass rate by category and language")
        out.append(table(
            ["category/lang", "evaluated", "passed", "pass rate", "needsChunking"],
            summary.passByCategoryAndLang.sorted { $0.key < $1.key }.map { [
                $0.key, "\($0.value.evaluated)", "\($0.value.passed)", percent($0.value.rate), "\($0.value.needsChunking)",
            ] }
        ))

        out.append("## Latency (generation, ms)")
        var latencyRows = [
            ["all", "cold", "\(summary.latencyCold.n)", ms(summary.latencyCold.p50Ms), ms(summary.latencyCold.p95Ms)],
            ["all", "warm", "\(summary.latencyWarm.n)", ms(summary.latencyWarm.p50Ms), ms(summary.latencyWarm.p95Ms)],
        ]
        for (category, parts) in summary.latencyByCategory.sorted(by: { $0.key < $1.key }) {
            for (temperature, stats) in parts.sorted(by: { $0.key < $1.key }) {
                latencyRows.append([category, temperature, "\(stats.n)", ms(stats.p50Ms), ms(stats.p95Ms)])
            }
        }
        out.append(table(["category", "temperature", "n", "p50", "p95"], latencyRows))
        out.append("Cold = the first generation in this process; every later case is warm.")

        out.append("## Refusals and guardrails (false refusals: every case is legitimate text)")
        let refusal = summary.refusal
        out.append("- model-call cases \(refusal.attempted); refusal errors \(refusal.refusalErrors); guardrail errors \(refusal.guardrailErrors); refusal phrases rejected by the validator \(refusal.refusalPhraseRejects); false-refusal rate \(percent(refusal.falseRefusalRate))")
        if !summary.failuresByCode.isEmpty {
            out.append("- failure codes: " + summary.failuresByCode.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }

        out.append("## Validator")
        out.append("- status: " + (summary.validatorStatus.isEmpty ? "-" : summary.validatorStatus.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))
        out.append(summary.validatorReasons.isEmpty
            ? "- reject/review reasons: none"
            : table(["reason", "count"], summary.validatorReasons.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map { [$0.key, "\($0.value)"] }))

        if let long = summary.long {
            out.append("## Long text")
            out.append(table(["case", "run", "pass/fail", "chunks", "outcome", "total seconds"], long.cases.map { row in
                [row.id, "\(row.run)", row.pass ? "pass" : "fail", "\(row.chunkCount)", row.outcome,
                 row.totalSeconds.map { String(format: "%.3f", $0) } ?? "-"]
            }))
            out.append("- loss failures: \(long.lossFailures); duplication failures: \(long.duplicationFailures); correctionLeakedAutomatic: \(long.correctionLeakedAutomatic) (counts per run)")
            out.append("- context-limit: \(settings.contextLimit.map(String.init) ?? "real"); chunk-context: \(settings.chunkContext ?? "none")")
        }

        out.append("## Critical cases")
        out.append("- \(summary.critical.allRunsPassed)/\(summary.critical.cases) critical cases passed in every run" + (summary.critical.failingIds.isEmpty ? "" : "; failing: \(summary.critical.failingIds.joined(separator: ", "))"))

        if let routing = summary.routing {
            out.append("## Routing")
            func fraction(_ value: Int) -> String { "\(value)/\(routing.evaluated) (\(percent(Double(value) / Double(max(1, routing.evaluated)))))" }
            out.append("""
            - outputIntent \(fraction(routing.outputIntentCorrect)); taskType \(fraction(routing.taskTypeCorrect)); kind \(fraction(routing.kindCorrect)); all three \(fraction(routing.allCorrect))
            - web pre-check fired \(routing.webPrecheckFired); classifier fallbacks \(routing.classifierFallbacks)
            - wrong auto-replace (predicted content + automatic + target, expected otherwise): \(routing.wrongAutoReplace)\(routing.wrongAutoReplaceIds.isEmpty ? "" : " [\(routing.wrongAutoReplaceIds.joined(separator: ", "))]")
            - content+automatic recall: \(routing.predictedContentAutomaticHits)/\(routing.expectedContentAutomatic) (\(percent(routing.contentAutomaticRecall)))
            """)
            for (title, counts) in [("outputIntent", routing.confusion.intent), ("taskType", routing.confusion.taskType), ("kind", routing.confusion.kind)] {
                out.append("### Confusion: \(title) (expected -> predicted)")
                out.append(table(["pair", "count"], counts.sorted { $0.key < $1.key }.map { [$0.key, "\($0.value)"] }))
            }
        }

        out.append("## Tokens")
        out.append("- average input \(summary.averageInputTokens.map { String(format: "%.0f", $0) } ?? "-"), average output \(summary.averageOutputTokens.map { String(format: "%.0f", $0) } ?? "-"); truncated results: \(summary.truncatedCount)")
        return out.joined(separator: "\n\n") + "\n"
    }
}
