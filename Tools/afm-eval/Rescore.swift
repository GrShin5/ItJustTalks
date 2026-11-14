import Foundation

/// The out directory must not be inside the repository (output files hold review text).
func repositoryRoot(for directory: URL) -> URL? {
    var candidate = URL(fileURLWithPath: canonicalPath(directory))
    while true {
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path),
           FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
            return candidate
        }
        // "/" has no parent; deletingLastPathComponent would keep appending "..".
        if candidate.pathComponents.count <= 1 { return nil }
        candidate = candidate.deletingLastPathComponent().standardizedFileURL
    }
}

func isRepositoryOutput(_ output: URL, casesDirectory: URL) -> Bool {
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return [casesDirectory, current, output].compactMap { repositoryRoot(for: $0) }
        .contains { isInside(output, $0) }
}

/// resolvingSymlinksInPath leaves a path untouched when its leaf does not exist yet, so resolve the deepest
/// existing ancestor and re-append the missing components (output folders are usually not created yet).
func canonicalPath(_ url: URL) -> String {
    var existing = url.standardizedFileURL
    var missing: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
        missing.insert(existing.lastPathComponent, at: 0)
        existing = existing.deletingLastPathComponent().standardizedFileURL
    }
    return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL.path
}

func isInside(_ child: URL, _ parent: URL) -> Bool {
    let childPath = canonicalPath(child)
    let parentPath = canonicalPath(parent)
    return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
}

/// Compatibility entrypoint for older portable-kit callers.
func rescoreCleanup(_ options: RunOptions, recordsDirectory: URL) throws {
    var cleanupOptions = options
    cleanupOptions.categories = [.cleanup]
    cleanupOptions.allCategories = false
    try rescore(cleanupOptions, recordsDirectory: recordsDirectory)
}

/// Score the expected case/run grid, never the observed-output denominator. No model calls.
func rescore(_ options: RunOptions, recordsDirectory: URL) throws {
    guard !isRepositoryOutput(options.outDirectory, casesDirectory: options.casesDirectory),
          !isInside(options.outDirectory, recordsDirectory), !isInside(recordsDirectory, options.outDirectory) else {
        throw OptionError.message("rescore output must be separate from source records and repository")
    }
    guard options.limit == nil else { throw OptionError.message("rescore does not allow --limit") }
    func key(_ category: String, _ id: String, _ run: Int) -> String { "\(category)/\(id)/\(run)" }
    var expected: [(CaseMeta, Int, (OutputRecord) -> JudgeRecord)] = []
    func add<T>(_ items: [T], meta: (T) -> CaseMeta, score: @escaping (T, OutputRecord) -> JudgeRecord) {
        for item in items {
            let value = meta(item)
            for run in 1...(value.critical ? options.repeatCount : 1) {
                expected.append((value, run, { score(item, $0) }))
            }
        }
    }
    for category in options.categories {
        if options.allCategories && !FileManager.default.fileExists(atPath: options.casesDirectory.appendingPathComponent("\(category.rawValue).jsonl").path) { continue }
        switch category {
        case .cleanup:
            add(try CaseLoader.cleanup(options.casesDirectory), meta: { $0.meta }, score: { Judge.cleanup($0, output: $1.text) })
        case .routing:
            add(try CaseLoader.routing(options.casesDirectory), meta: { $0.meta }, score: {
                Judge.routing($0, intent: $1.routing?.predictedIntent, task: $1.routing?.predictedTaskType, kind: $1.routing?.predictedKind)
            })
        case .generation:
            add(try CaseLoader.generation(options.casesDirectory), meta: { $0.meta }, score: { item, output in
                Judge.generation(item, output: output.text, path: output.generationPath,
                                 predictedTask: output.routing?.predictedTaskType)
            })
        case .optimization:
            add(try CaseLoader.optimization(options.casesDirectory), meta: { $0.meta }, score: {
                Judge.optimization($0, items: $1.items ?? $1.text.components(separatedBy: "\n"), flags: $1.permissionFlaggedIndices ?? [])
            })
        case .long:
            add(try CaseLoader.long(options.casesDirectory), meta: { $0.meta }, score: { item, output in
                let failed = Judge.checkLong(item, task: Judge.longTask(item), outcome: output.outcome ?? "missingOutcome",
                                             output: output.text.trimmingCharacters(in: .whitespacesAndNewlines))
                return JudgeRecord(pass: failed.isEmpty, failedChecks: failed)
            })
        }
    }
    let expectedKeys = expected.map { key($0.0.category.rawValue, $0.0.id, $0.1) }
    guard !expectedKeys.isEmpty, Set(expectedKeys).count == expectedKeys.count else {
        throw OptionError.message("rescore requires nonempty unique case ids")
    }
    let allowed = Set(expectedKeys)
    let decoder = JSONDecoder()
    func load<T: Decodable>(_ name: String, as: T.Type) throws -> [T] {
        let url = recordsDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(decoding: Data(contentsOf: url), as: UTF8.self).split(separator: "\n").map {
            try decoder.decode(T.self, from: Data($0.utf8))
        }
    }
    var outputs: [String: OutputRecord] = [:]
    for output in try load("outputs.jsonl", as: OutputRecord.self) {
        let k = key(output.category, output.id, output.run)
        guard allowed.contains(k), outputs[k] == nil else { throw OptionError.message("unexpected or duplicate output key") }
        outputs[k] = output
    }
    var records: [String: EvalRecord] = [:]
    for record in try load("records.jsonl", as: EvalRecord.self) {
        let k = key(record.category, record.id, record.run)
        guard allowed.contains(k), records[k] == nil else { throw OptionError.message("unexpected or duplicate record key") }
        records[k] = record
    }
    var results: [[String: Any]] = []
    for (meta, run, score) in expected {
        let k = key(meta.category.rawValue, meta.id, run)
        var failed = ["missingOutput"]
        var fidelity: FidelityMetrics? = nil
        var strict: Bool? = nil
        var languagePass = false
        let record = records[k]
        var output = outputs[k]
        if var value = output {
            if let recordedPath = record?.generationPath, let outputPath = value.generationPath,
               recordedPath != outputPath {
                throw OptionError.message("conflicting generation paths in records and outputs")
            }
            value.generationPath = record?.generationPath ?? value.generationPath
            value.outcome = record?.outcome ?? value.outcome
            value.validator = record?.validator ?? value.validator
            value.routing = record?.routing ?? value.routing
            value.permissionFlaggedIndices = record?.permissionFlaggedIndices ?? value.permissionFlaggedIndices
            output = value
            let judged = Judge.executionChecked(score(value), outcome: value.outcome,
                failureCode: record?.failureCode ?? value.failureCode, validator: value.validator)
            failed = judged.failedChecks
            fidelity = judged.fidelity
            strict = judged.strictLanguagePass
            languagePass = !failed.contains { $0.hasPrefix("language(") }
        }
        var row: [String: Any] = ["id": meta.id, "category": meta.category.rawValue, "run": run,
                                  "pass": failed.isEmpty, "failedChecks": Array(Set(failed)).sorted(),
                                  "validator": ["status": output?.validator?.status ?? "unavailable"]]
        if let fidelity {
            row["fidelity"] = try JSONSerialization.jsonObject(with: JSONLines.encoder.encode(fidelity))
        }
        if let validator = output?.validator ?? record?.validator {
            row["validator"] = ["status": validator.status, "reasons": validator.reasons]
        }
        if meta.category == .cleanup {
            row["languagePass"] = languagePass
            row["strictLanguagePass"] = strict ?? false
        }
        if meta.category == .generation { row["generationPath"] = record?.generationPath ?? output?.generationPath ?? "oracle" }
        results.append(row)
    }
    try FileManager.default.createDirectory(at: options.outDirectory, withIntermediateDirectories: true)
    try JSONLines.prettyEncoder.encode(RunManifest.capture(directory: options.casesDirectory))
        .write(to: options.outDirectory.appendingPathComponent("manifest.json"))
    let report: [String: Any] = ["records": results, "evaluated": results.count,
        "passed": results.filter { $0["pass"] as? Bool == true }.count,
        "languagePassed": results.filter { $0["languagePass"] as? Bool == true }.count,
        "strictLanguagePassed": results.filter { $0["strictLanguagePass"] as? Bool == true }.count]
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        .write(to: options.outDirectory.appendingPathComponent("rescore.json"))
    print("rescore: evaluated=\(results.count)")
}
