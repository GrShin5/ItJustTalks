import Foundation
import ItJustTalksAI

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func runEvaluation(_ options: RunOptions) async throws {
    if isRepositoryOutput(options.outDirectory, casesDirectory: options.casesDirectory) {
        throw OptionError.message("--out must be outside the repository")
    }
    try FileManager.default.createDirectory(at: options.outDirectory, withIntermediateDirectories: true)
    let manifest = try RunManifest.capture(directory: options.casesDirectory)
    try JSONLines.prettyEncoder.encode(manifest).write(to: options.outDirectory.appendingPathComponent("manifest.json"))
    let harness = try Harness(options: options)
    guard harness.availability.isAvailable else {
        throw OptionError.message("model unavailable: \(harness.availability)")
    }
    let pipelines = Pipelines(harness: harness)
    let recordsFile = try JSONLinesFile(url: options.outDirectory.appendingPathComponent("records.jsonl"))
    let outputsFile = try JSONLinesFile(url: options.outDirectory.appendingPathComponent("outputs.jsonl"))
    defer {
        recordsFile.close()
        outputsFile.close()
    }

    var records: [EvalRecord] = []
    func emit(_ outcome: CaseOutcome) throws {
        var record = outcome.record
        record.judge = Judge.executionChecked(record.judge ?? JudgeRecord(pass: false, failedChecks: ["missingJudge"]),
            outcome: record.outcome, failureCode: record.failureCode, validator: record.validator)
        try recordsFile.append(record)
        if let text = outcome.output {
            try outputsFile.append(OutputRecord(id: record.id, run: record.run, category: record.category, text: text,
                stageA: outcome.stageA, outcome: record.outcome, failureCode: record.failureCode,
                validator: record.validator, routing: record.routing,
                permissionFlaggedIndices: record.permissionFlaggedIndices, items: outcome.items,
                generationPath: record.generationPath))
        }
        records.append(record)
    }
    func limited<T>(_ items: [T]) -> [T] { options.limit.map { Array(items.prefix($0)) } ?? items }
    func runs(_ meta: CaseMeta) -> Int { meta.critical ? options.repeatCount : 1 }

    for category in options.categories {
        if options.allCategories,
           !FileManager.default.fileExists(atPath: options.casesDirectory.appendingPathComponent("\(category.rawValue).jsonl").path) {
            print("\(category.rawValue): skipped (no case file)")
            continue
        }
        let before = records.count
        switch category {
        case .cleanup:
            for item in limited(try CaseLoader.cleanup(options.casesDirectory)) {
                for run in 1...runs(item.meta) { try emit(await pipelines.cleanup(item, run: run)) }
            }
        case .routing:
            for item in limited(try CaseLoader.routing(options.casesDirectory)) {
                for run in 1...runs(item.meta) { try emit(await pipelines.routing(item, run: run)) }
            }
        case .generation:
            for item in limited(try CaseLoader.generation(options.casesDirectory)) {
                for run in 1...runs(item.meta) { try emit(await pipelines.generation(item, run: run)) }
            }
        case .optimization:
            for item in limited(try CaseLoader.optimization(options.casesDirectory)) {
                for run in 1...runs(item.meta) { try emit(await pipelines.optimization(item, run: run)) }
            }
        case .long:
            for item in limited(try CaseLoader.long(options.casesDirectory)) {
                for run in 1...runs(item.meta) { try emit(await pipelines.long(item, run: run)) }
            }
        }
        print("\(category.rawValue): \(records.count - before) records")
    }

    guard try RunManifest.capture(directory: options.casesDirectory).datasetSHA256 == manifest.datasetSHA256 else {
        throw OptionError.message("dataset changed during evaluation")
    }
    let summary = SummaryBuilder.build(records: records, settings: harness.settings, model: harness.model)
    try JSONLines.prettyEncoder.encode(summary).write(to: options.outDirectory.appendingPathComponent("summary.json"))
    try SummaryBuilder.markdown(summary).write(to: options.outDirectory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)

    for (category, stats) in summary.passByCategory.sorted(by: { $0.key < $1.key }) {
        let rate = stats.rate.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
        print("summary \(category): passed \(stats.passed)/\(stats.evaluated) (\(rate)) needsChunking \(stats.needsChunking)")
    }
    func ms(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "-" }
    print("latency ms cold n=\(summary.latencyCold.n) p50=\(ms(summary.latencyCold.p50Ms)) p95=\(ms(summary.latencyCold.p95Ms)); warm n=\(summary.latencyWarm.n) p50=\(ms(summary.latencyWarm.p50Ms)) p95=\(ms(summary.latencyWarm.p95Ms))")
    print("false refusals \(summary.refusal.falseRefusalCases)/\(summary.refusal.attempted); failures \(summary.outcomes["failure", default: 0]); validator status \(summary.validatorStatus.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
    if let routing = summary.routing {
        print("routing: intent \(routing.outputIntentCorrect)/\(routing.evaluated) taskType \(routing.taskTypeCorrect)/\(routing.evaluated) kind \(routing.kindCorrect)/\(routing.evaluated) wrongAutoReplace \(routing.wrongAutoReplace) content+automatic recall \(routing.predictedContentAutomaticHits)/\(routing.expectedContentAutomatic)")
    }
    print("wrote \(options.outDirectory.lastPathComponent)/{records.jsonl,outputs.jsonl,summary.json,summary.md}")
}

do {
    switch try OptionParser.parse(Array(CommandLine.arguments.dropFirst())) {
    case .run(let options):
        try await runEvaluation(options)
    case .rescore(let options, let input):
        try rescore(options, recordsDirectory: input)
    case .cancelTest(let options):
        if isInside(options.outDirectory, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)),
           FileManager.default.fileExists(atPath: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Package.swift").path) {
            throw OptionError.message("--out must be outside the repository")
        }
        try await CancelTest.run(options)
    }
} catch let error as OptionError {
    fail("\(error)")
} catch {
    fail("error: \(type(of: error))", code: 1)
}
