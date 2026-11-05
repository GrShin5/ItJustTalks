import Foundation
import NaturalLanguage
import ItJustTalksAI

/// Judging rules shared by every pipeline. Pure; reports check names only.
enum Judge {
    static func executionChecked(_ judge: JudgeRecord, outcome: String?, failureCode: String?, validator: ValidatorRecord?) -> JudgeRecord {
        var result = judge
        if let outcome, !["ok", "complete", "needsReview"].contains(outcome) { result.failedChecks.append("outcome") }
        if failureCode != nil { result.failedChecks.append("failure") }
        if validator?.status == "failed" { result.failedChecks.append("validatorFailed") }
        result.failedChecks = Array(Set(result.failedChecks)).sorted()
        result.pass = result.failedChecks.isEmpty && judge.pass
        return result
    }

    static func cleanup(_ item: CleanupCase, output: String) -> JudgeRecord {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var failed = checkMustContain(item.mustContain, in: text) + checkMustNotContain(item.mustNotContain, in: text)
        failed += checkCleanupLanguage(item, in: text)
        if let correction = item.correction {
            failed += checkCorrection(old: correction.old, new: correction.new, mustContain: item.mustContain, in: text)
        }
        if item.noAnswer { failed += checkNoAnswer(source: item.transcript, output: text) }
        return JudgeRecord(pass: failed.isEmpty, failedChecks: failed,
                           strictLanguagePass: checkLanguage(item.language, in: text).isEmpty)
    }

    /// Deterministic contamination guard, not a semantic answer oracle. Preserve questions and reject
    /// newly introduced answer/assistant framing; phrases already dictated are allowed.
    static func checkNoAnswer(source: String, output: String) -> [String] {
        // Count each framing family independently, anywhere in the dictated source. Removing a
        // filler may move an existing phrase to sentence start; it must not turn into a new answer.
        let patterns = [#"(?i)\banswer\s*:"#, #"(?i)\bthe\s+answer\s+is\b"#,
                        #"(?i)\bsure\s*[,!]"#, #"(?i)\bcertainly\s*[,!]"#,
                        #"(?i)\bhere(?:'s|\s+is)\s+(?:the|your)\b"#,
                        #"回答[：:]"#, #"答えは"#, #"はい[、,]"#, #"もちろん[、,]"#]
        func occurrences(_ pattern: String, in text: String) -> Int {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
            return expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        var failed: [String] = []
        if patterns.contains(where: { occurrences($0, in: output) > occurrences($0, in: source) }) {
            failed.append("noAnswer(framing)")
        }
        let question = #"(?i)[?？]|(?:ですか|ますか|でしょうか)[。\s]*$|^(?:what|why|how|when|where|who|can|could|is|are|do|does)\b"#
        if source.range(of: question, options: .regularExpression) != nil,
           output.range(of: question, options: .regularExpression) == nil { failed.append("noAnswer(questionLost)") }
        return failed
    }

    static func routing(_ item: RoutingCase, intent: String?, task: String?, kind: String?) -> JudgeRecord {
        var failed: [String] = []
        if intent != item.expectedIntent { failed.append("outputIntent") }
        if task != item.expectedTaskType { failed.append("taskType") }
        if kind != item.expectedKind { failed.append("kind") }
        return JudgeRecord(pass: failed.isEmpty, failedChecks: failed)
    }

    static func generation(_ item: GenerationCase, output: String, path: String? = nil, predictedTask: String? = nil) -> JudgeRecord {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var failed = checkMustContain(item.mustContain, in: text) + checkMustNotContain(item.mustNotContain, in: text)
        failed += checkLanguage(item.language, in: text)
        if path == "e2e", predictedTask != item.taskType { failed.append("taskType") }
        if let path, !["oracle", "e2e"].contains(path) { failed.append("generationPath") }
        let source = item.target ?? ""
        if let ratio = item.maxLengthRatio, visibleLength(source) > 0,
           Double(visibleLength(text)) / Double(visibleLength(source)) > ratio { failed.append("maxLengthRatio") }
        return JudgeRecord(pass: failed.isEmpty, failedChecks: failed)
    }

    static func optimization(_ item: OptimizationCase, items: [String], flags: [Int]) -> JudgeRecord {
        var failed = checkPermissionFlags(expected: item.permissionFlaggedIndices, actual: flags)
        failed += checkPermissionItems(expected: item.permissionFlaggedItems, items: items, actual: flags)
        if items.count > item.maxItems { failed.append("maxItems") }
        if graphemes(items) > item.maxGraphemes { failed.append("maxGraphemes") }
        failed += checkMustContain(item.mustPreserve, in: items.joined(separator: "\n"))
            .map { $0.replacingOccurrences(of: "mustContain", with: "mustPreserve") }
        return JudgeRecord(pass: failed.isEmpty, failedChecks: failed)
    }

    static func longTask(_ item: LongCase) -> AITask {
        if item.isTranscript { return .cleanup }
        let text = (item.instruction ?? "").lowercased()
        if text.contains("要約") || text.contains("summar") { return .summarize }
        if text.contains("抜き出") || text.contains("抽出") || text.contains("extract") { return .extract }
        if text.contains("翻訳") || text.contains("translate") { return .translate }
        if text.contains("校正") || text.contains("proofread") || text.contains("丁寧") || text.contains("polite") { return .proofreadRewrite }
        return .transform
    }

    /// Long-category QA emits codes only, never content.
    static func checkLong(_ item: LongCase, task: AITask, outcome: String, output: String) -> [String] {
        var failed: [String] = []
        let survived = item.checkpoints.filter { satisfied($0, in: output) }.count
        let required = task.isSourceRewrite ? item.checkpoints.count : (item.checkpoints.count + 1) / 2
        if survived < required { failed.append("loss") }
        if task.isSourceRewrite {
            for cp in item.checkpoints {
                let occurrences = alternatives(cp).reduce(0) { count, alternative in
                    count + output.components(separatedBy: alternative).count - 1
                }
                if occurrences >= 2 { failed.append("duplicate(cp)") }
            }
        }
        // NFKC + case/width folding and punctuation/space removal makes formatting irrelevant.
        func normalized(_ text: String) -> String {
            text.precomposedStringWithCompatibilityMapping
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init).joined()
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = output
        var previous: String?
        tokenizer.enumerateTokens(in: output.startIndex..<output.endIndex) { range, _ in
            let sentence = normalized(String(output[range]))
            if !sentence.isEmpty {
                if sentence == previous, !failed.contains("duplicateSentence") { failed.append("duplicateSentence") }
                previous = sentence
            }
            return true
        }
        if task == .extract {
            var seen: Set<String> = []
            for line in output.split(whereSeparator: \.isNewline) {
                let value = normalized(String(line))
                if !value.isEmpty, !seen.insert(value).inserted {
                    failed.append("duplicateLine")
                    break
                }
            }
        }
        if outcome != "needsReview" {
            for correction in item.corrections {
                if !output.contains(correction.new) { failed.append("correction.new") }
                if output.contains(correction.old) {
                    failed.append(outcome == "complete" ? "correctionLeakedAutomatic" : "correction.old")
                }
            }
        }
        if outcome != "complete" && !(item.reviewAcceptable && outcome == "needsReview") {
            failed.append("outcome")
        }
        failed += checkLanguage(item.language, in: output)
        return Array(Set(failed)).sorted()
    }

    /// `entry` holds `|`-separated alternatives; true when any occurs (exact match, no case folding).
    static func satisfied(_ entry: String, in output: String) -> Bool {
        alternatives(entry).contains { output.contains($0) }
    }

    static func alternatives(_ entry: String) -> [String] {
        entry.split(separator: "|", omittingEmptySubsequences: true).map(String.init)
    }

    static func checkMustContain(_ entries: [String], in output: String) -> [String] {
        entries.enumerated().filter { !satisfied($0.element, in: output) }.map { "mustContain[\($0.offset)]" }
    }

    static func checkMustNotContain(_ entries: [String], in output: String) -> [String] {
        entries.enumerated().filter { satisfied($0.element, in: output) }.map { "mustNotContain[\($0.offset)]" }
    }

    /// Dominant language of `text` is `expected` ("ja" / "en"). Very short outputs are not judged.
    static func checkLanguage(_ expected: String, in text: String, minimumLength: Int = 8) -> [String] {
        guard visibleLength(text) >= minimumLength else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage?.rawValue else { return [] }
        let base = detected.split(separator: "-").first.map(String.init) ?? detected
        return base == expected ? [] : ["language(expected \(expected), got \(base))"]
    }

    /// Score surrounding prose while preserving the historical strict score separately.
    static func languageRemainder(_ item: CleanupCase, output: String, includeReadings: Bool = false) -> String {
        var spellings: [String] = []
        for entry in item.dictionary {
            var sourceNames = [entry.preferred] + entry.readings
            // Synthetic STT aliases: a kana reading prefix followed by a Latin spelling suffix.
            // Keep at least two characters from each; never strip a bare partial name.
            if entry.preferred.range(of: #"^[A-Za-z]+$"#, options: .regularExpression) != nil {
                for reading in entry.readings where reading.range(of: #"^[ァ-ヶー]+$"#, options: .regularExpression) != nil {
                    guard reading.count > 2, entry.preferred.count > 2 else { continue }
                    for prefixLength in 2..<reading.count {
                        for suffixLength in 2..<entry.preferred.count {
                            let alias = String(reading.prefix(prefixLength)) + String(entry.preferred.suffix(suffixLength))
                            if item.transcript.contains(alias) { sourceNames.append(alias) }
                        }
                    }
                }
            }
            if sourceNames.contains(where: { !$0.isEmpty && item.transcript.contains($0) }) {
                spellings += includeReadings ? sourceNames : [entry.preferred]
            }
        }
        // Required Latin proper-name tokens are fixed by the synthetic case, never by the response.
        for term in item.mustContain.flatMap({ alternatives($0) }) {
            if term.range(of: #"^[A-Z][A-Za-z0-9]*(?:[ -][A-Z][A-Za-z0-9]*)*$"#,
                          options: .regularExpression) != nil { spellings.append(term) }
        }
        var remainder = output
        for spelling in Set(spellings).sorted(by: { $0.count > $1.count }) where !spelling.isEmpty {
            let prefix = includeReadings && spelling.range(of: #"^[ァ-ヶー]"#, options: .regularExpression) != nil
                ? "" : #"(?<![A-Za-z0-9_])"#
            let pattern = prefix + NSRegularExpression.escapedPattern(for: spelling) + #"(?![A-Za-z0-9_])"#
            remainder = remainder.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return remainder
    }

    static func checkCleanupLanguage(_ item: CleanupCase, in output: String) -> [String] {
        let remainder = languageRemainder(item, output: output)
        guard remainder != output else { return checkLanguage(item.language, in: output) }
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        if remainder.unicodeScalars.allSatisfy({ separators.contains($0) }) {
            let sourceRemainder = languageRemainder(item, output: item.transcript, includeReadings: true)
            // A names-only response cannot stand in for source prose.
            return sourceRemainder.unicodeScalars.allSatisfy({ separators.contains($0) })
                ? [] : ["language(missingProse)"]
        }
        // Even short added prose is judged; only separators qualify as neutral.
        return checkLanguage(item.language, in: remainder, minimumLength: 1)
    }

    static func checkPermissionFlags(expected: [Int]?, actual: [Int]) -> [String] {
        guard let expected else { return [] }
        return expected.sorted() == actual.sorted() ? [] : ["permissionFlaggedIndices"]
    }

    /// Match expected permission targets without imposing an arbitrary generated item order.
    static func checkPermissionItems(expected: [String]?, items: [String], actual: [Int]) -> [String] {
        guard let expected else { return [] }
        return expected.enumerated().compactMap { index, term in
            let matches = items.indices.filter { satisfied(term, in: items[$0]) }
            return !matches.isEmpty && matches.allSatisfy({ actual.contains($0) })
                ? nil : "permissionFlaggedItems[\(index)]"
        }
    }

    /// A spoken self-correction: the corrected value survives (directly or via a satisfied mustContain
    /// alternative list that names it) and the discarded one does not.
    static func checkCorrection(old: String, new: String, mustContain: [String], in output: String) -> [String] {
        var failed: [String] = []
        let newSurvives = output.contains(new)
            || mustContain.contains { alternatives($0).contains(new) && satisfied($0, in: output) }
        if !newSurvives { failed.append("correction.new") }
        if output.contains(old) { failed.append("correction.old") }
        return failed
    }

    static func visibleLength(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    static func graphemes(_ items: [String]) -> Int {
        items.reduce(0) { $0 + $1.count }
    }
}
