import Foundation
import NaturalLanguage

/// Deterministic result checks (§3.6, D9). Pure: no model calls, no logging.
///
/// Fail-closed: when a check cannot decide, the result is not `complete`. The rules are written so that a
/// faithful cleanup (fillers removed, punctuation added, self-corrections applied, kana→kanji) passes
/// naturally, while answers, preambles, postscripts and changed numbers do not.
///
/// Severity: for cleanup every rule fails the result (original text is inserted instead / not sent), except
/// the fidelity rules (kept self-correction, lost request ending, changed negation): `needsReview` normally, `failed` in
/// hands-free mode. For AI command tasks, truncation, length ratio, leading preamble and postscript are `needsReview`
/// (shown in the result window). Language mismatch is always `needsReview`.
public struct ResultValidator: Sendable {
    public var thresholds: ValidationThresholds

    public init(thresholds: ValidationThresholds = .provisionalDefault) {
        self.thresholds = thresholds
    }

    /// Only a list made entirely of at least two non-empty bullet lines qualifies.
    private static func isBulletList(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.count >= 2 && lines.allSatisfy { line in
            ["・", "-", "•", "*"].contains(where: { line.hasPrefix($0) })
                || line.range(of: #"^\d+[.）)]"#, options: .regularExpression) != nil
        }
    }

    // MARK: - Entry points

    public func validate(_ input: ValidationInput) -> ValidationOutcome {
        evaluate(input).outcome
    }

    /// A generation that threw never yields text; refusal/guardrail and every other failure are `failed`.
    public func validate(failure: AIFailure) -> ValidationOutcome {
        .failed([.generationFailed(failure)])
    }

    public func evaluate(_ input: ValidationInput) -> ValidationReport {
        var failures: [ValidationReason] = []
        var reviews: [ValidationReason] = []
        var metrics = ValidationMetrics()
        func fail(_ reason: ValidationReason) { if !failures.contains(reason) { failures.append(reason) } }
        func review(_ reason: ValidationReason) { if !reviews.contains(reason) { reviews.append(reason) } }

        if input.task == .translate {
            func translationForm(_ text: String) -> String {
                text.precomposedStringWithCompatibilityMapping
                    .folding(options: .widthInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    .filter { !$0.isWhitespace && !$0.isPunctuation }
            }
            // Identical text is only "untranslated" when the source has letters outside the target's script
            // (digits, codes or names already in the target script legitimately come back unchanged).
            func hasLettersForeign(to language: String?, in text: String) -> Bool {
                let key = (language ?? "").lowercased()
                let cjkTarget = ["ja", "zh", "ko", "日本", "中国", "韓国", "japanese", "chinese", "korean"]
                    .contains { key.hasPrefix($0) }
                let latinTarget = !cjkTarget && (key.hasPrefix("en") || key.hasPrefix("英") || key.hasPrefix("fr")
                    || key.hasPrefix("de") || key.hasPrefix("es") || key.hasPrefix("it") || key.hasPrefix("pt"))
                return text.unicodeScalars.contains { scalar in
                    guard scalar.properties.isAlphabetic else { return false }
                    guard cjkTarget || latinTarget else { return true }
                    let latin = (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
                        || (0xC0...0x24F).contains(scalar.value)
                    let kana = PhoneticReading.isKana(scalar)
                    let hangul = (0xAC00...0xD7AF).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value)
                        || (0x3130...0x318F).contains(scalar.value)
                    if key.hasPrefix("zh") || key.hasPrefix("中国") || key.hasPrefix("chinese") { return latin || kana || hangul }
                    if key.hasPrefix("ja") || key.hasPrefix("日本") { return latin || hangul }
                    if key.hasPrefix("ko") || key.hasPrefix("韓国") || key.hasPrefix("korean") { return latin || kana }
                    return cjkTarget ? latin : !latin
                }
            }
            if translationForm(input.source) == translationForm(input.output),
               hasLettersForeign(to: input.expectedOutputLanguage, in: input.source) {
                review(.translationUnchanged)
            }
        }

        let isCleanup = input.task == .cleanup
        // Only this request's own texts license output content (never persistent custom instructions).
        let licensed = isCleanup ? [input.source] : [input.source] + input.userSuppliedTexts
        let licensedNormalized = licensed.map(Self.normalizeForMatch)
        let sourceNormalized = Self.normalizeForMatch(input.source)

        // Input sanity: no protected instructions would silently disable the leak check.
        if !input.protectedInstructions.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            fail(.invalidInput)
        }

        // Truncation.
        if input.isTruncated {
            if isCleanup || input.task == .instructionOptimization { fail(.truncated) } else { review(.truncated) }
        }

        // Empty: nothing left after removing whitespace, punctuation, symbols and invisible characters.
        let trimmed = input.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // A registered symbol spelling ("→") is content even though it has no letters.
        let isRegisteredSymbol = input.languageIgnoringTerms.contains {
            let term = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            let outputCount = Self.occurrences(of: term, in: trimmed)
            let sourceCount = Self.occurrences(of: term, in: input.source)
            return !term.isEmpty && outputCount > 0 && outputCount <= sourceCount
        }
        if Self.normalizeForMatch(trimmed).isEmpty && !isRegisteredSymbol {
            fail(.emptyOutput)
            return ValidationReport(outcome: .from(failures: failures, reviews: reviews), metrics: metrics)
        }

        let pieces = Self.pieces(of: trimmed)

        // Format: label / preamble / postscript / scaffold / JSON.
        for (reason, severity) in formatProblems(trimmed, pieces: pieces, sourceNormalized: sourceNormalized, input: input) {
            switch severity {
            case .failure: fail(reason)
            case .review: review(reason)
            }
        }

        // Refusal phrases.
        switch refusal(pieces, licensedNormalized: licensedNormalized) {
        case .none: break
        case .unlicensed: fail(.refusalPhrase)
        case .partiallyLicensed: review(.refusalPhrase)
        }

        // Prompt leakage.
        if leaksInstructions(trimmed, protected: input.protectedInstructions, licensedNormalized: licensedNormalized) {
            fail(.promptLeakage)
        }

        // Cross-language cleanup (output language differs from the transcript, PromptTexts rule).
        let crossLanguage = isCleanup && Self.isCrossLanguage(source: input.languageSource ?? input.source, expected: input.expectedOutputLanguage)

        // Length ratio.
        if let range = thresholds.lengthRatio[crossLanguage ? .translate : input.task] {
            let sourceLength = Self.visibleLength(input.source)
            if sourceLength >= thresholds.lengthRatioMinimumSourceCharacters {
                let ratio = Double(Self.visibleLength(trimmed)) / Double(sourceLength)
                metrics.lengthRatio = ratio
                // Removing certified disfluencies may shorten a cleanup, but cannot license expansion.
                let retentionLength = isCleanup ? Self.visibleLength(CleanupFidelity.removingDisfluencies(input.source)) : sourceLength
                let retentionRatio = Double(Self.visibleLength(trimmed)) / Double(max(1, retentionLength))
                if (ratio < range.lowerBound && retentionRatio < range.lowerBound) || ratio > range.upperBound {
                    if isCleanup { fail(.lengthRatioOutOfRange) } else { review(.lengthRatioOutOfRange) }
                }
            }
        }

        // Content overlap (ADD-04: answering instead of cleaning).
        if crossLanguage {
            // Content words cannot be compared across languages. Hands-free must not send what it cannot verify.
            if input.handsFree { review(.overlapUnverifiable) }
        } else if let overlap = overlapThresholds(for: input) {
            // Words the speaker retracted with a self-correction are not expected in a cleanup.
            let excluded = isCleanup
                ? CleanupFidelity.retentionExclusions(source: input.source, spans: input.selfCorrections ?? [])
                : []
            // Speech that may license a katakana / spelled-out rendering, retracted segments excluded. Not used in
            // hands-free at all: an unpunctuated retraction ("てんぷれーといやふぉーまっと") is invisible to the cue
            // rules and stage A only runs on a detected cue, so the evidence cannot be trusted for sending.
            let evidence: String
            if !isCleanup {
                evidence = input.source
            } else if input.handsFree {
                evidence = ""
            } else {
                evidence = CleanupFidelity.removingRetractions(from: input.source, spans: input.selfCorrections ?? [])
            }
            let result = contentOverlap(
                // Fillers stripped from the source must not count as new content when the output keeps them.
                source: isCleanup ? CleanupFidelity.normalizingQualifierSpellings(CleanupFidelity.removingDisfluencies(input.source)) : input.source,
                output: isCleanup ? CleanupFidelity.normalizingQualifierSpellings(CleanupFidelity.removingEnglishFillers(trimmed)) : trimmed,
                allowedNewTerms: input.allowedNewTerms + Self.wholeTermsPresent(input.reviewOnlyTerms, in: trimmed),
                excludedFromRetention: excluded, phoneticEvidence: evidence
            )
            metrics.contentRetention = result.retention
            metrics.newContentRatio = result.newRatio
            var reasons: [ValidationReason] = []
            if result.sourceCount >= overlap.minimumSourceContentWords {
                if result.retention < overlap.minimumRetention { reasons.append(.lowContentRetention) }
                if result.newRatio > overlap.maximumNewContentRatio { reasons.append(.excessiveNewContent) }
            }
            if isCleanup, answerDetected(
                input: input, trimmed: trimmed, pieces: pieces, overlap: overlap, result: result, evidence: evidence
            ) {
                reasons.append(.excessiveNewContent)
            }
            for reason in reasons {
                if isCleanup { fail(reason) } else { review(reason) }
            }
        }

        // Dictionary spellings matched only by sound (hands-free), or used more often than the transcript
        // supports (a homophone rewritten too): never applied automatically. Retracted speech is no evidence:
        // selection runs on the corrected transcript, so a retracted 「佐藤さん、いや、…」 must not license 佐藤.
        let dictionarySource = isCleanup
            ? CleanupFidelity.removingRetractions(from: input.source, spans: input.selfCorrections ?? [])
            : input.source
        if Self.introducesTerm(input.reviewOnlyTerms, output: trimmed, source: dictionarySource)
            || (input.handsFree && Self.exceedsDictionaryEvidence(input.selectedDictionary, output: trimmed, source: dictionarySource)) {
            review(.unverifiedDictionaryReplacement)
        }

        // Cleanup fidelity: retracted self-corrections, dictated request/question endings and negations (P1 fix).
        if isCleanup, !crossLanguage {
            var fidelity: [ValidationReason] = []
            let retentionSource = droppedSpanSource(input)
            if CleanupFidelity.dropsContiguousSpan(input: input, source: retentionSource)
                || CleanupFidelity.dropsQualifier(source: retentionSource, output: trimmed)
                || CleanupFidelity.dropsDistinctPredicate(source: input.source, output: trimmed, spans: input.selfCorrections ?? [])
                || CleanupFidelity.dropsAuxiliary(source: input.source, output: trimmed, spans: input.selfCorrections ?? []) {
                fidelity.append(.lowContentRetention)
            }
            if CleanupFidelity.keepsRetractedSegment(source: input.source, output: trimmed)
                || CleanupFidelity.keepsRetractedSpan(input.selfCorrections ?? [], source: input.source, output: trimmed) {
                fidelity.append(.selfCorrectionKept)
            }
            let styledBulletList = input.hasStylePreferences && !input.handsFree && Self.isBulletList(trimmed)
            if !styledBulletList, CleanupFidelity.dropsRequestEnding(source: input.source, output: trimmed) {
                fidelity.append(.requestEndingLost)
            }
            if CleanupFidelity.changesNegation(source: input.source, output: trimmed, spans: input.selfCorrections ?? []) {
                fidelity.append(.negationChanged)
            }
            // Hands-free only: a filler the speaker used as a filler must not be sent.
            if input.handsFree, CleanupFidelity.keepsFiller(source: input.source, output: trimmed) {
                fidelity.append(.residualFiller)
            }
            for reason in fidelity {
                if input.handsFree { fail(reason) } else { review(reason) }
            }
        }

        // Numbers.
        if Self.checksNumbers(input.task) {
            let check = numberCheck(input: input, output: trimmed, crossLanguage: crossLanguage)
            metrics.newNumberCount = check.newCount
            if check.newCount > 0 { fail(.newNumbers(count: check.newCount)) }
            if check.mismatch { fail(.numberMismatch) }
            if check.newCount == 0, !check.mismatch {
                let dropped = droppedNumberCount(input: input, output: trimmed)
                if dropped > 0 {
                    if input.handsFree { fail(.numbersDropped(count: dropped)) } else { review(.numbersDropped(count: dropped)) }
                }
            }
        }

        // Translation script evidence also applies to short phrases and source-identical words.
        if input.task == .translate, let expected = input.expectedOutputLanguage,
           trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
           Self.containsExpectedLanguageScript(trimmed, expected: expected, source: input.languageSource ?? input.source) == false {
            review(.languageMismatch(expected: expected, detected: Self.dominantLanguage(trimmed)))
        }

        // Registered spellings are names, not evidence of a change in output language.
        var languageOutput = trimmed
        for term in input.languageIgnoringTerms.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            languageOutput = languageOutput.replacingOccurrences(of: term, with: " ", options: .caseInsensitive)
        }
        languageOutput = Self.languageRemainder(languageOutput, source: input.languageSource ?? input.source)
        let hasLanguageLetters = languageOutput.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        if let expected = input.expectedOutputLanguage, hasLanguageLetters,
           Self.visibleLength(languageOutput) >= thresholds.languageCheckMinimumCharacters {
            let detected = Self.dominantLanguage(languageOutput)
            metrics.detectedLanguage = detected
            if !Self.languageMatches(expected: expected, detected: detected) {
                review(.languageMismatch(expected: expected, detected: detected))
            }
        } else if let expected = input.expectedOutputLanguage
                    ?? (isCleanup && !input.languageIgnoringTerms.isEmpty ? Self.spokenScriptLanguage(input.languageSource ?? input.source) : nil),
                  Self.visibleLength(trimmed) >= thresholds.languageCheckMinimumCharacters,
                  hasLanguageLetters,
                  Self.containsExpectedLanguageScript(languageOutput, expected: expected, source: input.languageSource ?? input.source) == false {
            let detected = Self.dominantLanguage(languageOutput)
            metrics.detectedLanguage = detected
            review(.languageMismatch(expected: expected, detected: detected))
        }

        return ValidationReport(outcome: .from(failures: failures, reviews: reviews), metrics: metrics)
    }

    // MARK: - Pieces (sentences)

    struct Piece {
        var text: String
        /// The piece is a whole output line.
        var isWholeLine: Bool
    }

    /// Splits into sentences at 。．！？!?, at "：", at ":" / "." followed by whitespace, and at line breaks.
    static func pieces(of text: String) -> [Piece] {
        var result: [Piece] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let chars = Array(rawLine)
            var linePieces: [String] = []
            var current = ""
            let closers = "」』)）\"”"
            func isTerminal(_ i: Int) -> Bool {
                let c = chars[i]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                return "。．！？!?：".contains(c) || ((c == ":" || c == ".") && (next == nil || next!.isWhitespace))
            }
            for (i, c) in chars.enumerated() {
                current.append(c)
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let boundary = isTerminal(i) || (closers.contains(c) && i > 0 && isTerminal(i - 1))
                if boundary, !(next.map { "。．！？!?".contains($0) || closers.contains($0) } ?? false) {
                    linePieces.append(current)
                    current = ""
                }
            }
            linePieces.append(current)
            let trimmedPieces = linePieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for piece in trimmedPieces {
                result.append(Piece(text: piece, isWholeLine: trimmedPieces.count == 1))
            }
        }
        return result
    }

    // MARK: - Format

    enum Severity { case failure, review }

    private static let labelWords: [String] = [
        "整形結果", "整形後", "整形文", "出力", "結果", "回答", "翻訳", "要約", "本文", "修正後", "校正結果", "清書",
        "output", "result", "answer", "translation", "summary", "cleaned text", "cleaned", "text", "response",
        "corrected text", "final text", "transcript",
    ]

    /// Every prompt section title in every prompt language (echoing them is scaffold leakage).
    private static let sectionTitles: Set<String> = Set(PromptSection.allCases.flatMap { section in
        PromptLanguage.allCases.map { section.title($0).lowercased() }
    })

    private static let preamblePatterns: [String] = [
        "^以下(が|は|に|の)?[、,]?.{0,30}(です|ます|しました|になります|となります)[。.:：]?$",
        "^こちら(が|は).{0,30}(です|ます|になります)[。.:：]?$",
        "^(はい[、,]?\\s*)?(承知|かしこまり|了解)(しました|いたしました)[。!！]?$",
        "^(はい|もちろん(です)?|かしこまりました|了解です|わかりました|分かりました)[。!！]?$",
        "^(整形|校正|翻訳|要約|修正|清書|編集)(した|しました|後の|済みの|結果の?)?.{0,20}[:：。]$",
        "^(here is|here's|here are|below is|the following is) .{0,60}[:.]?$",
        "^(sure|certainly|of course|absolutely|okay|ok)[,!.]?( here (is|are|'s)\\b.{0,50})?$",
        "^(the )?(cleaned|corrected|rewritten|translated|summarized|edited|proofread)( up)?[- ]?(text|version|transcript)( is)?.{0,20}[:.]?$",
        "^i('ve| have) (cleaned|corrected|fixed|rewritten|translated|summarized|edited|proofread)\\b.{0,60}[:.]?$",
    ]

    private static let postscriptPatterns: [String] = [
        "^以上(です|になります|となります|でございます)?[。.!！]?$",
        "^(お役に立て|参考にな).{0,30}$",
        "^(ご不明な点|何か|なにか|他に|ほかに|その他).{0,40}(ください|どうぞ|ませ|ね)[。.!！]?$",
        "^(上記|以上)の?.{0,20}(整形|修正|校正|翻訳|要約|編集).{0,20}$",
        "^(整形|修正|校正|翻訳|要約|編集)(しました|いたしました|は以上です|完了)[。.!！]?$",
        "^(※|注[:：]|補足[:：]|備考[:：]|注意[:：])",
        "^いかがでしょうか[。?？]?$",
        "^(i )?hope (this|that|it) helps\\b",
        "^let me know\\b",
        "^feel free to\\b",
        "^(is there )?anything else\\b",
        "^(note|nb|p\\.?s\\.?)\\s*[:：]",
        "^i('ve| have) (cleaned|corrected|fixed|removed|edited)\\b",
    ]

    private func formatProblems(
        _ trimmed: String,
        pieces: [Piece],
        sourceNormalized: String,
        input: ValidationInput
    ) -> [(ValidationReason, Severity)] {
        var problems: [(ValidationReason, Severity)] = []
        let isCleanup = input.task == .cleanup

        // Leading labels / preambles (also inline "整形後：本文", multi-sentence "承知しました。以下が…").
        var index = 0
        var sawPreamble = false
        var sawLabel = false
        while index < pieces.count {
            let piece = pieces[index]
            if Self.isLabelPiece(piece) {
                // A dictated leading label ("回答、明日行きます" → "回答：明日行きます。") is content.
                let label = Self.normalizeForMatch(Self.strippedLabel(piece.text))
                if index == 0, pieces.count > 1, !label.isEmpty, sourceNormalized.hasPrefix(label) { break }
                sawLabel = true
                index += 1
                continue
            }
            if Self.isPreamble(piece.text), !Self.contained(piece.text, in: sourceNormalized) {
                sawPreamble = true
                index += 1
                continue
            }
            break
        }
        if index == pieces.count, sawPreamble || sawLabel,
           Self.normalizeForMatch(trimmed) != sourceNormalized {
            problems.append((sawPreamble ? .preambleOnly : .labelOnly, .failure))
        } else if sawPreamble || sawLabel {
            problems.append((.leadingPreamble, isCleanup ? .failure : .review))
        }

        // Trailing postscripts ("以上です。", "I hope this helps!").
        if let severity = Self.postscriptSeverity(input.task), index < pieces.count {
            var hasPostscript = false
            var tail = pieces.count - 1
            while tail >= index, Self.isPostscript(pieces[tail].text),
                  !Self.contained(pieces[tail].text, in: sourceNormalized) {
                hasPostscript = true
                tail -= 1
            }
            if let lastLine = trimmed.split(whereSeparator: \.isNewline).last.map(String.init),
               trimmed.split(whereSeparator: \.isNewline).count > 1,
               Self.isPostscript(lastLine.trimmingCharacters(in: .whitespaces)),
               !Self.contained(lastLine, in: sourceNormalized) {
                hasPostscript = true
            }
            if hasPostscript { problems.append((.trailingPostscript, severity)) }
        }

        // Prompt scaffold echo: section headings and fence lines the source did not contain.
        let jsonExpected = Self.jsonIsExpected(input)
        for rawLine in trimmed.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\"\"\"") || line.hasPrefix("'''") {
                if !input.source.contains(String(line.prefix(3))) { problems.append((.promptLeakage, .failure)) }
            } else if line.hasPrefix("```") {
                if !input.source.contains("```"), !jsonExpected {
                    problems.append((.promptLeakage, isCleanup ? .failure : .review))
                }
            } else if Self.sectionTitles.contains(Self.strippedLabel(line)),
                      !sourceNormalized.contains(Self.normalizeForMatch(Self.strippedLabel(line))) {
                problems.append((.promptLeakage, .failure))
            }
        }

        if Self.looksLikeJSON(trimmed), !jsonExpected {
            problems.append((.jsonFragment, .failure))
        }
        return problems
    }

    /// Cleanup fails; rewrites of the target are reviewed; free-form tasks may legitimately end with a closing.
    private static func postscriptSeverity(_ task: AITask) -> Severity? {
        switch task {
        case .cleanup: return .failure
        case .proofreadRewrite, .transform, .summarize, .extract, .unifiedCommand: return .review
        case .translate, .explainAnalyze, .answerQuestion, .composeReply, .taskClassification, .instructionOptimization,
             .selfCorrection:
            return nil
        }
    }

    static func strippedLabel(_ line: String) -> String {
        var text = line.lowercased()
        while let last = text.last, ":：-—「」『』[]【】#*".contains(last) || last.isWhitespace { text.removeLast() }
        while let first = text.first, "#*-「『[【".contains(first) || first.isWhitespace { text.removeFirst() }
        return text
    }

    static func isLabel(_ line: String) -> Bool {
        let text = strippedLabel(line)
        return labelWords.contains(text) || sectionTitles.contains(text)
    }

    /// A label word ending with a colon, or alone on its line.
    static func isLabelPiece(_ piece: Piece) -> Bool {
        guard isLabel(piece.text) else { return false }
        let trimmed = piece.text.trimmingCharacters(in: .whitespaces)
        return piece.isWholeLine || trimmed.hasSuffix(":") || trimmed.hasSuffix("：")
    }

    static func isPreamble(_ line: String) -> Bool {
        let lower = line.lowercased().replacingOccurrences(of: "’", with: "'")
        return preamblePatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    static func isPostscript(_ line: String) -> Bool {
        let lower = line.lowercased().replacingOccurrences(of: "’", with: "'")
        return postscriptPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    static func looksLikeJSON(_ text: String) -> Bool {
        var body = text
        if body.hasPrefix("```") {
            body = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n")
            if body.hasSuffix("```") { body.removeLast(3) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let first = body.first, first == "{" || first == "[" else { return false }
        if let data = body.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            return true
        }
        // Fragments such as `{"text": "…` (unterminated) still count.
        return body.range(of: "^\\{\\s*\"[A-Za-z_]+\"\\s*:", options: .regularExpression) != nil
    }

    /// JSON is expected only when the target already is JSON, or this request's spoken instruction asks for it.
    private static func jsonIsExpected(_ input: ValidationInput) -> Bool {
        let source = input.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("{") || source.hasPrefix("[") { return true }
        guard input.task != .cleanup else { return false }
        return input.userSuppliedTexts.contains { $0.lowercased().contains("json") }
    }

    // MARK: - Refusal

    private static let refusalPhrases: [String] = [
        "お手伝いできません", "お手伝いすることはできません", "お手伝いいたしかねます", "お応えできません",
        "お答えできません", "回答できません", "回答を控え", "対応できません", "対応することはできません",
        "対応いたしかねます", "提供できません", "できかねます", "お受けできません", "控えさせていただきます",
        "応じられません", "応じかねます", "お力になれません", "その依頼には", "このリクエストには",
        "言語モデルとして", "aiとして", "aiアシスタントとして",
        "i'm sorry, but i can't", "i am sorry, but i cannot", "i'm sorry, but i cannot", "i'm sorry, i can't",
        "i'm sorry but i can't", "i can't assist", "i cannot assist", "i can't help with", "i cannot help with",
        "i'm unable to", "i am unable to", "i'm not able to", "i am not able to", "unable to assist",
        "unable to help", "i cannot do that", "i can't do that", "i won't be able to", "i must decline",
        "i cannot provide", "i can't provide", "i cannot fulfill", "i can't fulfill", "i cannot complete",
        "i can't complete", "against my guidelines", "as an ai", "as a language model", "i can't comply",
        "i cannot comply",
    ]
    /// English phrases match on word boundaries ("as an ai" must not match "has an aim").
    private static let wordRefusalPhrases: [String] = refusalPhrases.filter { $0.contains(where: \.isASCII) && $0.contains(" ") }
        .map(wordNormalize)
    private static let plainRefusalPhrases: [String] = refusalPhrases
        .filter { !($0.contains(where: \.isASCII) && $0.contains(" ")) }.map(normalizeForMatch)

    /// Lowercased words separated by single spaces, apostrophes dropped ("I’m sorry, but" → " im sorry but ").
    static func wordNormalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return " " + words.joined(separator: " ") + " "
    }

    private static func refusalPhrase(in text: String) -> String? {
        let words = wordNormalize(text)
        if let phrase = wordRefusalPhrases.first(where: { words.contains($0) }) {
            return normalizeForMatch(phrase)
        }
        let plain = normalizeForMatch(text)
        return plainRefusalPhrases.first { plain.contains($0) }
    }

    enum RefusalFinding { case none, unlicensed, partiallyLicensed }

    /// A refusal phrase is exempt only when its whole output sentence was in this request's own text.
    /// If only the phrase (not the sentence) was there, the result goes to review.
    private func refusal(_ pieces: [Piece], licensedNormalized: [String]) -> RefusalFinding {
        var finding = RefusalFinding.none
        for piece in pieces {
            let sentence = Self.normalizeForMatch(piece.text)
            guard let phrase = Self.refusalPhrase(in: piece.text) else { continue }
            if licensedNormalized.contains(where: { $0.contains(sentence) }) { continue }
            if licensedNormalized.contains(where: { $0.contains(phrase) }) {
                finding = .partiallyLicensed
            } else {
                return .unlicensed
            }
        }
        return finding
    }

    // MARK: - Prompt leakage (ported idea of AppServerOutputSafetyGate)

    /// True when the output contains a verbatim window of a fixed instruction line that the user did not supply.
    func leaksInstructions(_ output: String, protected: [String], licensedNormalized: [String]) -> Bool {
        let window = max(8, thresholds.leakageWindowCharacters)
        let normalizedOutput = Self.normalizeForMatch(output)
        guard normalizedOutput.count >= window else { return false }
        for instruction in protected {
            for rawLine in instruction.components(separatedBy: .newlines) {
                let line = Array(Self.normalizeForMatch(rawLine))
                guard line.count >= window else { continue }
                var start = 0
                while start + window <= line.count {
                    let fragment = String(line[start..<(start + window)])
                    if normalizedOutput.contains(fragment),
                       !licensedNormalized.contains(where: { $0.contains(fragment) }) {
                        return true
                    }
                    start += 1
                }
            }
        }
        return false
    }

    // MARK: - Overlap

    private func overlapThresholds(for input: ValidationInput) -> OverlapThresholds? {
        switch input.task {
        case .cleanup:
            return input.handsFree ? thresholds.cleanupOverlapHandsFree : thresholds.cleanupOverlap
        case .proofreadRewrite:
            return thresholds.rewriteOverlap
        default:
            return nil
        }
    }

    struct OverlapResult {
        var sourceCount: Int
        var outputCount: Int
        var newCount: Int
        var retention: Double
        var newRatio: Double
        /// Decides whether an output content word is new (absent from the source in any spelling).
        var isNew: (String) -> Bool
    }

    /// Terms whose whole (normalized) spelling occurs in the output.
    static func wholeTermsPresent(_ terms: [String], in output: String) -> [String] {
        let normalizedOutput = normalizeForMatch(output)
        return terms.filter { term in
            let key = normalizeForMatch(term)
            return !key.isEmpty && normalizedOutput.contains(key)
        }
    }

    /// Per entry: the output contains the preferred spelling, or a word (2+ characters) inside it that the
    /// source lacks, more often than the source contains the spelling or one of its readings (folded, literal).
    static func exceedsDictionaryEvidence(_ entries: [DictionaryHint], output: String, source: String) -> Bool {
        guard !entries.isEmpty else { return false }
        let foldedSource = TextFolding.compact(source)
        let foldedOutput = TextFolding.compact(output)
        for entry in entries {
            let preferred = TextFolding.compact(entry.preferred)
            if preferred.isEmpty {
                // Symbols disappear under compact folding; require literal source support.
                let raw = entry.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
                if occurrences(of: raw, in: output) > occurrences(of: raw, in: source) { return true }
                continue
            }
            // Readings are counted longest first and masked, so nested readings are not counted twice.
            var remaining = foldedSource
            var supported = 0
            for reading in ([entry.preferred] + entry.readings).map(TextFolding.compact).filter({ !$0.isEmpty })
                .sorted(by: { $0.count > $1.count }) {
                supported += occurrences(of: reading, in: remaining)
                remaining = remaining.replacingOccurrences(of: reading, with: "|")
            }
            var terms = [preferred]
            for word in ContentWords.extract(from: entry.preferred) {
                let key = TextFolding.compact(word)
                if key.count >= 2, key != preferred, !foldedSource.contains(key) { terms.append(key) }
            }
            if terms.contains(where: { occurrences(of: $0, in: foldedOutput) > supported }) { return true }
        }
        return false
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    /// True when the output contains one of `terms` (normalized) that the source does not contain.
    static func introducesTerm(_ terms: [String], output: String, source: String) -> Bool {
        guard !terms.isEmpty else { return false }
        let normalizedOutput = normalizeForMatch(output)
        let normalizedSource = normalizeForMatch(source)
        return terms.contains { term in
            let key = normalizeForMatch(term)
            return !key.isEmpty && normalizedOutput.contains(key) && !normalizedSource.contains(key)
        }
    }

    func contentOverlap(
        source: String, output: String, allowedNewTerms: [String], excludedFromRetention: Set<String> = [],
        phoneticEvidence: String? = nil
    ) -> OverlapResult {
        let sourceWords = ContentWords.extract(from: source)
        let retainedWords = sourceWords.subtracting(excludedFromRetention)
        let outputWords = ContentWords.extract(from: output)
        // Whole words of a licensed spelling. A single character is licensed only as the whole term ("都" of
        // "東京都" is not licensed elsewhere); a word may be several whole words of the term (tokenization of
        // "ミナト物流" alone and inside a sentence can differ).
        var allowedParts = Set<String>()
        let allowed = allowedNewTerms.reduce(into: Set<String>()) { set, term in
            let words = ContentWords.extract(from: term)
            let whole = ContentWords.normalize(NumberExtractor.replacingNumerals(in: term))
            allowedParts.formUnion(words)
            // Digits are checked separately (numbers inside a term are licensed only where the term appears).
            set.formUnion(words.filter { $0.count >= 2 || $0 == whole || $0.allSatisfy(\.isNumber) })
        }
        let isAllowed: (String) -> Bool = { word in
            allowed.contains(word) || (word.count >= 2 && ContentWords.isSpelled(word, byAnyOf: allowedParts))
        }
        // Katakana / spelled-out renderings of whole words spoken in hiragana (てんぷれーと → テンプレート,
        // えーぴーあい → API), from the evidence (retracted speech excluded).
        let spokenInHiragana = PhoneticReading.wordsSpokenInHiragana(outputWords, source: phoneticEvidence ?? source)
        let normalizedSource = ContentWords.normalize(NumberExtractor.replacingNumerals(in: source))
        let normalizedOutput = ContentWords.normalize(NumberExtractor.replacingNumerals(in: output))
        // Kept / new also across spellings: substring (tokenization differs) and token-aligned reading
        // (かいぎしつ ↔ 会議室, わかった ↔ 分かった).
        let outputSpelledInSource = ContentWords.readingLicensedSurfaces(of: output, against: source)
        let sourceSpelledInOutput = ContentWords.readingLicensedSurfaces(of: source, against: output)
        let kept = retainedWords.filter {
            outputWords.contains($0) || normalizedOutput.contains($0) || ContentWords.isSpelled($0, byAnyOf: sourceSpelledInOutput)
        }.count
        let isNew: (String) -> Bool = { word in
            !sourceWords.contains(word) && !isAllowed(word) && !normalizedSource.contains(word)
                && !ContentWords.isSpelled(word, byAnyOf: outputSpelledInSource) && !spokenInHiragana.contains(word)
        }
        let newCount = outputWords.filter(isNew).count
        return OverlapResult(
            sourceCount: sourceWords.count,
            outputCount: outputWords.count,
            newCount: newCount,
            retention: retainedWords.isEmpty ? 1 : Double(kept) / Double(retainedWords.count),
            newRatio: outputWords.isEmpty ? 0 : Double(newCount) / Double(outputWords.count),
            isNew: isNew
        )
    }

    /// Cleanup-only "answered instead of cleaned" rules. A faithful cleanup adds no new content word, so each
    /// rule only fires when the output contains words the speaker never said.
    private func answerDetected(
        input: ValidationInput,
        trimmed: String,
        pieces: [Piece],
        overlap: OverlapThresholds,
        result: OverlapResult,
        evidence: String
    ) -> Bool {
        var input = input
        input.source = CleanupFidelity.normalizingQualifierSpellings(input.source)
        let trimmed = CleanupFidelity.normalizingQualifierSpellings(trimmed)
        let pieces = Self.pieces(of: trimmed)
        // Kana-only answers are invisible to content words: a content-word-free source may only come back
        // with its own (long) kana tokens, and no output sentence may consist mostly of unspoken kana words.
        if result.sourceCount == 0,
           ContentWords.longKanaTokens(of: trimmed, against: input.source, phoneticEvidence: evidence).new > 0 { return true }
        for piece in pieces where ContentWords.extract(from: piece.text).isEmpty {
            let kana = ContentWords.longKanaTokens(of: piece.text, against: input.source, phoneticEvidence: evidence)
            if kana.total > 0, Double(kana.new) / Double(kana.total) > overlap.maximumSentenceNewContentRatio { return true }
        }
        guard result.newCount > 0 else { return false }
        // Source without content words (はい / わかった) or short source: any new content word is an answer.
        if result.sourceCount == 0 || result.sourceCount <= overlap.shortSourceContentWords { return true }
        // A question dictated as a question must not come back as a statement with new words.
        if Self.isQuestionForm(input.source), let last = pieces.last, !Self.endsAsQuestion(last.text) { return true }
        // An appended/answer sentence is made mostly of new words.
        for piece in pieces {
            let words = ContentWords.extract(from: piece.text)
            guard !words.isEmpty else { continue }
            let newInSentence = words.filter(result.isNew).count
            if Double(newInSentence) / Double(words.count) > overlap.maximumSentenceNewContentRatio { return true }
        }
        return false
    }

    private static let japaneseQuestionEndings = ["か", "かな", "かしら", "の", "っけ", "かね", "でしょ", "だろう", "だろ"]
    private static let japaneseInterrogatives = [
        "何", "なに", "なん", "いつ", "どこ", "誰", "だれ", "どれ", "どの", "どう", "なぜ", "いくら", "いくつ", "どちら", "どっち",
    ]
    private static let englishQuestionStarters: Set<String> = [
        "what", "when", "where", "who", "whom", "whose", "why", "how", "which", "is", "are", "am", "was", "were",
        "do", "does", "did", "can", "could", "will", "would", "should", "shall", "may", "might", "have", "has",
    ]

    static func isQuestionForm(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。.、,")))
        if t.hasSuffix("？") || t.hasSuffix("?") { return true }
        if japaneseQuestionEndings.contains(where: { t.hasSuffix($0) }) { return true }
        if japaneseInterrogatives.contains(where: { t.contains($0) }) { return true }
        let firstWord = t.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return englishQuestionStarters.contains(firstWord)
    }

    static func endsAsQuestion(_ sentence: String) -> Bool {
        let t = sentence.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。.")))
        return t.hasSuffix("？") || t.hasSuffix("?") || ["か", "かな", "かしら", "っけ", "の"].contains(where: { t.hasSuffix($0) })
    }

    // MARK: - Numbers

    private static func checksNumbers(_ task: AITask) -> Bool {
        switch task {
        case .cleanup, .proofreadRewrite, .translate, .transform, .summarize, .extract, .unifiedCommand:
            return true
        case .explainAnalyze, .answerQuestion, .composeReply, .taskClassification, .instructionOptimization, .selfCorrection:
            return false
        }
    }

    private static let correctionCues: [String] = [
        "いや", "いえ", "じゃなくて", "じゃなく", "ではなくて", "ではなく", "でなく", "違う", "ちがう", "違った",
        "間違え", "訂正", "言い直", "やっぱり", "やっぱ", "というか", "っていうか", "もとい", "ごめん",
        "no wait", "actually", "i mean", "sorry", "scratch that", "make that", "rather", "correction",
    ]

    struct NumberCheck {
        var newCount: Int
        var mismatch: Bool
    }

    /// Numbers must be licensed by the source (and, for AI commands, this request's spoken instruction).
    /// Cleanup also keeps their order and multiplicity, and must not keep a value the speaker retracted
    /// ("5部、いや3部" → "5部"). Rewrites/translations keep multiplicity. Signs are part of the value.
    /// Only number checks for a joined result; callers choose whole-operation severity.
    func joinedNumberReasons(_ input: ValidationInput) -> [ValidationReason] {
        let crossLanguage = input.task == .cleanup && Self.isCrossLanguage(
            source: input.languageSource ?? input.source, expected: input.expectedOutputLanguage)
        let check = numberCheck(input: input, output: input.output, crossLanguage: crossLanguage)
        var reasons: [ValidationReason] = []
        if check.newCount > 0 { reasons.append(.newNumbers(count: check.newCount)) }
        if check.mismatch { reasons.append(.numberMismatch) }
        let dropped = droppedNumberCount(input: input, output: input.output)
        if dropped > 0 { reasons.append(.numbersDropped(count: dropped)) }
        return reasons
    }

    func numberCheck(input: ValidationInput, output: String, crossLanguage: Bool) -> NumberCheck {
        var outputText = Self.strippingListEnumerators(output)
        // Numbers inside a dictionary term ("iPhone 17") are licensed only where the term itself appears.
        // Review-only terms are licensed the same way (where the whole term appears); the result is then
        // `needsReview` through `unverifiedDictionaryReplacement`, never complete.
        for term in input.allowedNewTerms + input.reviewOnlyTerms
            where !NumberExtractor.sequence(in: term, excludingIdioms: false).isEmpty {
            outputText = outputText.replacingOccurrences(of: term, with: " ")
        }
        let produced = NumberExtractor.sequence(in: outputText, excludingIdioms: true)
        let sourceAnalysis = NumberExtractor.analyze(input.source, excludingIdioms: false)
        let sourceValues = sourceAnalysis.tokens.map(\.value)
        var licensedValues = sourceValues
        if input.task != .cleanup {
            for text in input.userSuppliedTexts {
                licensedValues += NumberExtractor.sequence(in: text, excludingIdioms: false)
            }
        }
        let newCount = Set(produced).subtracting(licensedValues).count
        guard newCount == 0 else { return NumberCheck(newCount: newCount, mismatch: false) }

        let retracted = input.task == .cleanup ? retractedIndices(sourceAnalysis) : []
        let keepsCue = !retracted.isEmpty && Self.containsCorrectionCue(output)
        let effective = sourceValues.enumerated().filter { !retracted.contains($0.offset) }.map(\.element)
        switch input.task {
        case .cleanup where !crossLanguage:
            let ordered = Self.isSubsequence(produced, of: effective) || (keepsCue && Self.isSubsequence(produced, of: sourceValues))
            return NumberCheck(newCount: 0, mismatch: !ordered)
        case .cleanup:
            let fits = Self.fitsMultiset(produced, in: effective) || (keepsCue && Self.fitsMultiset(produced, in: sourceValues))
            return NumberCheck(newCount: 0, mismatch: !fits)
        case .proofreadRewrite, .translate:
            return NumberCheck(newCount: 0, mismatch: !Self.fitsMultiset(produced, in: licensedValues))
        default:
            return NumberCheck(newCount: 0, mismatch: false)
        }
    }

    /// Source quantity occurrences tied to units and local facts. Only immediate repetitions and
    /// recognized corrections may disappear; equal values belonging to separate facts remain required.
    func droppedNumberCount(input: ValidationInput, output: String) -> Int {
        switch input.task {
        case .cleanup, .proofreadRewrite, .translate: break
        default: return 0
        }
        // Dictionary terms with digits are compared as whole terms, on both sides.
        var outputText = Self.strippingListEnumerators(output)
        var sourceText = Self.strippingListEnumerators(input.source)
        for term in input.allowedNewTerms + input.reviewOnlyTerms
            where !NumberExtractor.sequence(in: term, excludingIdioms: false).isEmpty {
            outputText = outputText.replacingOccurrences(of: term, with: " ")
            sourceText = sourceText.replacingOccurrences(of: term, with: " ")
        }
        if input.task == .cleanup {
            sourceText = CleanupFidelity.retentionSource(sourceText, spans: input.selfCorrections ?? [])
        }
        let analysis = NumberExtractor.analyze(sourceText, excludingIdioms: true)
        let retracted = input.task == .cleanup ? retractedIndices(analysis) : []
        let outputAnalysis = NumberExtractor.analyze(outputText, excludingIdioms: true)
        // Only a certified adjacent repetition may collapse; clauses with equal quantities remain distinct.
        var required: [String: Int] = [:]
        var bareMonths = NumberExtractor.bareCapitalizedMonths(in: outputAnalysis)
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        for (index, token) in analysis.tokens.enumerated() where !retracted.contains(index) {
            // A bare output month only preserves its corresponding source month, never a general quantity.
            if let month = NumberExtractor.ambiguousMonthName(token, in: analysis), bareMonths[month, default: 0] > 0 {
                bareMonths[month, default: 0] -= 1
                continue
            }
            if input.task == .cleanup, index > 0 {
                let previous = analysis.tokens[index - 1]
                let rawGap = String(analysis.text[previous.end..<token.offset])
                let before = String(analysis.text[max(0, previous.offset - 8)..<previous.offset]).lowercased()
                let after = String(analysis.text[token.end..<min(analysis.text.count, token.end + 16)]).lowercased()
                let nextIsListNumber = index + 1 < analysis.tokens.count && analysis.text[token.end..<analysis.tokens[index + 1].offset]
                    .allSatisfy { $0.isWhitespace || ",、，".contains($0) }
                // "5, 3, 3." — a number list continues on the left, so the second 3 is an item, not a restart.
                let previousIsListNumber = index >= 2 && analysis.text[analysis.tokens[index - 2].end..<previous.offset]
                    .allSatisfy { $0.isWhitespace || ",、，".contains($0) }
                let listContext = nextIsListNumber || previousIsListNumber || before.range(of: #"\b(?:and|or)\s*$"#, options: .regularExpression) != nil
                    || after.range(of: #"^[\s,、，]*(?:and|or)\b"#, options: .regularExpression) != nil
                let pauseRepeat = !listContext && !rawGap.isEmpty && rawGap.contains { ",、，".contains($0) }
                    && rawGap.allSatisfy { $0 == " " || $0 == "\t" || ",、，".contains($0) }
                let gap = rawGap
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if previous.value == token.value, !listContext, (pauseRepeat || (previous.unit == token.unit && gap == previous.unit)) { continue }
            }
            let key = token.value
            required[key, default: 0] += 1
        }
        let available = outputAnalysis.tokens.reduce(into: [String: Int]()) { counts, token in
            let key = token.value
            counts[key, default: 0] += 1
        }
        return required.reduce(0) { $0 + max(0, $1.value - available[$1.key, default: 0]) }
    }

    /// Cleanup source for the dropped-span check: certified retractions blanked, plus number corrections
    /// ("10時からです、いや11時") from the retracted number through its cue, as the number check excuses them.
    func droppedSpanSource(_ input: ValidationInput) -> String {
        let source = CleanupFidelity.retentionSource(input.source, spans: input.selfCorrections ?? [])
        let analysis = NumberExtractor.analyze(source, excludingIdioms: true)
        let retracted = retractedIndices(analysis)
        guard !retracted.isEmpty else { return source }
        var chars = Array(NumberExtractor.normalize(source))
        guard chars.count == analysis.text.count else { return source }
        for index in retracted where index + 1 < analysis.tokens.count {
            for k in analysis.tokens[index].offset..<analysis.tokens[index + 1].offset { chars[k] = " " }
        }
        return String(chars)
    }

    /// Indices of source numbers followed by a correction cue and a corrected number with the same unit
    /// (or immediately: "5, no wait, 3").
    func retractedIndices(_ analysis: NumberExtractor.Analysis) -> Set<Int> {
        var result = Set<Int>()
        let tokens = analysis.tokens
        guard tokens.count >= 2 else { return result }
        for i in 0..<(tokens.count - 1) {
            let a = tokens[i]
            let b = tokens[i + 1]
            guard a.end <= b.offset else { continue }
            let gap = String(analysis.text[a.end..<b.offset]).lowercased()
            guard let cue = Self.numberCorrectionCue(in: gap, afterUnit: a.unit == b.unit ? a.unit : "") else { continue }
            let slack = gap.count - cue.count
            let bareCue = gap.replacingOccurrences(of: cue, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
            let sameUnit = !a.unit.isEmpty && a.unit == b.unit
            if (sameUnit && slack <= thresholds.numberRetractionWindowCharacters) || slack <= 3 || bareCue {
                result.insert(i)
                continue
            }
            // A compound value ("1時41分から、いや、13時51分"): the corrected value's first unit matches an earlier
            // token of the same value, joined to `a` only by short unit text ("時").
            var j = i
            while j > 0, tokens[j - 1].end <= tokens[j].offset, tokens[j].offset - tokens[j - 1].end <= 2,
                  !String(analysis.text[tokens[j - 1].end..<tokens[j].offset]).contains(where: { "。、,.!?！？，．・〜～:：/-\n 　".contains($0) }) {
                j -= 1
                if !tokens[j].unit.isEmpty, tokens[j].unit == b.unit,
                   gap.count - cue.count <= thresholds.numberRetractionWindowCharacters {
                    for k in j...i { result.insert(k) }
                    break
                }
            }
        }
        return result
    }

    /// A cue must stand at a pause/word boundary, never inside 使いやすい or a Latin word.
    private static func numberCorrectionCue(in gap: String, afterUnit unit: String) -> String? {
        for cue in correctionCues {
            guard let range = gap.range(of: cue) else { continue }
            let before = gap[..<range.lowerBound].last
            let after = gap[range.upperBound...].first
            let unitBoundary = !unit.isEmpty && gap[..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) == unit
            let boundaryBefore = before == nil || before!.isWhitespace || before!.isPunctuation || unitBoundary
            let boundaryAfter = after == nil || after!.isWhitespace || after!.isPunctuation
            if boundaryBefore && boundaryAfter { return cue }
        }
        return nil
    }

    static func containsCorrectionCue(_ text: String) -> Bool {
        let lower = text.lowercased()
        return correctionCues.contains { lower.contains($0) }
    }

    static func isSubsequence(_ needle: [String], of haystack: [String]) -> Bool {
        var index = haystack.startIndex
        for value in needle {
            guard let found = haystack[index...].firstIndex(of: value) else { return false }
            index = found + 1
        }
        return true
    }

    static func fitsMultiset(_ values: [String], in available: [String]) -> Bool {
        var counts = available.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        for value in values {
            guard let count = counts[value], count > 0 else { return false }
            counts[value] = count - 1
        }
        return true
    }

    /// Line-leading list numbers ("1. ", "2) ", "３．") are formatting, not content — but only when they form a
    /// real list 1, 2, … n (n ≥ 2). "2、三日後" keeps its 2.
    static func strippingListEnumerators(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let pattern = "^\\s*([0-9０-９]{1,2})\\s*[.)．）](?![0-9０-９.])\\s*"
        var enumerators: [Int] = []
        for line in lines {
            if let range = line.range(of: pattern, options: .regularExpression) {
                let digits = line[range].precomposedStringWithCompatibilityMapping.filter(\.isNumber)
                enumerators.append(Int(digits) ?? -1)
            }
        }
        guard enumerators.count >= 2, enumerators == Array(1...enumerators.count) else { return text }
        return lines.map { $0.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    // MARK: - Language

    /// Original ASCII words are language-neutral evidence, just like registered spellings.
    private static func languageRemainder(_ output: String, source: String) -> String {
        let pattern = "[A-Za-z0-9_]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return output }
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let words = Set(regex.matches(in: source, range: sourceRange).compactMap { match in
            Range(match.range, in: source).map { String(source[$0]).lowercased() }
        })
        var remainder = output
        let outputRange = NSRange(output.startIndex..<output.endIndex, in: output)
        for match in regex.matches(in: output, range: outputRange).reversed() {
            guard let range = Range(match.range, in: remainder),
                  words.contains(String(remainder[range]).lowercased()) else { continue }
            remainder.replaceSubrange(range, with: " ")
        }
        return remainder
    }

    /// A short remainder still needs evidence of the requested script after registered names are removed.
    private static func containsExpectedLanguageScript(_ text: String, expected: String, source: String) -> Bool? {
        let language = expected.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        switch language {
        case "ja":
            return text.precomposedStringWithCompatibilityMapping.unicodeScalars.contains {
                PhoneticReading.isKana($0) || PhoneticReading.isHan($0)
            }
        case "en":
            return text.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
        case "zh":
            // A retained name must be isolated in the source, not a kana suffix inside Japanese prose.
            let normalizedSource = source.precomposedStringWithCompatibilityMapping
            let pattern = #"[ぁ-ゖァ-ヺー\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F]+"#
            var remainder = text.precomposedStringWithCompatibilityMapping
            if let regex = try? NSRegularExpression(pattern: pattern),
               let names = try? NSRegularExpression(pattern: #"(?<![\p{L}])"# + pattern + #"(?![\p{L}])"#) {
                let sourceRange = NSRange(normalizedSource.startIndex..., in: normalizedSource)
                let retainedNames = Set(names.matches(in: normalizedSource, range: sourceRange).compactMap { match in
                    Range(match.range, in: normalizedSource).map { String(normalizedSource[$0]) }
                })
                let matches = regex.matches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder))
                for match in matches.reversed() {
                    guard let range = Range(match.range, in: remainder),
                          retainedNames.contains(String(remainder[range])) else { continue }
                    remainder.replaceSubrange(range, with: " ")
                }
            }
            let scalars = remainder.unicodeScalars
            return scalars.contains { PhoneticReading.isHan($0) }
                && !scalars.contains { PhoneticReading.isKana($0) || (0xAC00...0xD7AF).contains($0.value)
                    || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }
        case "ko":
            return text.unicodeScalars.contains {
                (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value)
                    || (0x3130...0x318F).contains($0.value)
            }
        default: return nil
        }
    }

    /// Automatic output language: any kana/kanji in the transcript means Japanese, otherwise ASCII letters mean English.
    private static func spokenScriptLanguage(_ text: String) -> String? {
        let scalars = text.precomposedStringWithCompatibilityMapping.unicodeScalars
        if scalars.contains(where: { PhoneticReading.isKana($0) || PhoneticReading.isHan($0) }) { return "ja" }
        return scalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) ? "en" : nil
    }

    static func dominantLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    static func languageMatches(expected: String, detected: String?) -> Bool {
        guard let detected else { return false }
        func base(_ code: String) -> String {
            code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        }
        return base(expected) == base(detected)
    }

    /// Both script evidence and dominant language must disagree with the requested language.
    /// Ambiguous or undetectable sources keep the stricter same-language checks.
    static func isCrossLanguage(source: String, expected: String?) -> Bool {
        guard let expected, let scriptLanguage = spokenScriptLanguage(source),
              let detected = dominantLanguage(source) else { return false }
        return !languageMatches(expected: expected, detected: scriptLanguage)
            && !languageMatches(expected: expected, detected: detected)
    }

    // MARK: - Normalization

    /// Same normalization idea as `AppServerOutputSafetyGate`: fold width/case/diacritics, keep alphanumerics.
    static func normalizeForMatch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// The text (normalized, non-empty) occurs in the normalized source.
    static func contained(_ text: String, in sourceNormalized: String) -> Bool {
        let normalized = normalizeForMatch(text)
        return !normalized.isEmpty && sourceNormalized.contains(normalized)
    }

    static func visibleLength(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.whitespacesAndNewlines.contains($1) ? 0 : 1) }
    }
}
