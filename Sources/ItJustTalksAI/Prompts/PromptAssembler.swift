import Foundation

/// Dictionary entry selected for one request (selection itself is a separate component, `DictionarySelector`).
public struct DictionaryHint: Sendable, Hashable {
    /// Preferred spelling.
    public var preferred: String
    /// Readings / known mis-recognitions ("聞き取り例").
    public var readings: [String]
    /// Optional note (メモ) shown as reference information. `nil` or empty adds nothing to the line.
    public var memo: String?

    public init(preferred: String, readings: [String] = [], memo: String? = nil) {
        self.preferred = preferred
        self.readings = readings
        self.memo = memo
    }
}

/// Output language resolved by the app (existing resolution order). `name` is shown to the model.
public struct OutputLanguage: Sendable, Hashable {
    /// BCP-47 code, also used by the validator's language check.
    public var code: String
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

/// Which custom instruction the optimizer is condensing (§3.5: two kinds).
public enum CustomInstructionKind: String, Sendable, Hashable, CaseIterable {
    case cleanup
    case aiCommand
}

/// Named, delimited prompt sections. Titles are referenced verbatim by the fixed instructions.
public enum PromptSection: String, Sendable, CaseIterable {
    case outputLanguage
    case spellingReference
    case stylePreferences
    case spokenInstruction
    case targetAvailability
    case targetText
    case transcript
    case precedingText
    case draft
    case usage

    public func title(_ language: PromptLanguage) -> String {
        switch (self, language) {
        case (.outputLanguage, .ja): return "出力言語"
        case (.outputLanguage, .en): return "Output language"
        case (.spellingReference, .ja): return "表記の参考"
        case (.spellingReference, .en): return "Spelling reference"
        case (.stylePreferences, .ja): return "文体の好み"
        case (.stylePreferences, .en): return "Style preferences"
        case (.spokenInstruction, .ja): return "発話指示"
        case (.spokenInstruction, .en): return "Spoken instruction"
        case (.targetAvailability, .ja): return "対象本文の有無"
        case (.targetAvailability, .en): return "Target text available"
        case (.targetText, .ja): return "対象本文"
        case (.targetText, .en): return "Target text"
        case (.precedingText, .ja): return "直前の部分（参考のみ。出力に含めない）"
        case (.precedingText, .en): return "Preceding text (reference only; do not output)"
        case (.transcript, .ja): return "文字起こし"
        case (.transcript, .en): return "Transcript"
        case (.draft, .ja): return "草稿"
        case (.draft, .en): return "Draft"
        case (.usage, .ja): return "用途"
        case (.usage, .en): return "Used for"
        }
    }
}

/// Builds the variable prompt side. All user data (transcript, target text, dictionary, custom instructions,
/// spoken instruction) goes into fenced sections here — never into the fixed instructions.
public enum PromptAssembler {
    // MARK: - Per-pipeline prompts

    public static func cleanupPrompt(
        transcript: String,
        dictionaryHints: [DictionaryHint] = [],
        stylePreferences: String? = nil,
        outputLanguage: OutputLanguage? = nil,
        language: PromptLanguage,
        referenceContext: String? = nil
    ) -> String {
        render([
            optionalSection(.outputLanguage, outputLanguage?.name, language, includeReferenceHeading: referenceContext != nil),
            optionalSection(.spellingReference, dictionaryLines(dictionaryHints, language), language, includeReferenceHeading: referenceContext != nil),
            optionalSection(.stylePreferences, stylePreferences, language, includeReferenceHeading: referenceContext != nil),
            optionalSection(.precedingText, referenceContext, language, includeReferenceHeading: true),
            section(.transcript, transcript, language, includeReferenceHeading: referenceContext != nil),
        ])
    }

    /// Stage A of the two-stage cleanup sees only the transcript (no dictionary, style or output language).
    public static func selfCorrectionPrompt(transcript: String, language: PromptLanguage) -> String {
        render([section(.transcript, transcript, language)])
    }

    /// The classifier sees only the spoken instruction and whether a target exists — never the target text.
    public static func taskClassifierPrompt(
        spokenInstruction: String,
        hasTarget: Bool,
        language: PromptLanguage
    ) -> String {
        render([
            section(.spokenInstruction, spokenInstruction, language),
            plainSection(.targetAvailability, availabilityWord(hasTarget, language), language),
        ])
    }

    /// Body generation for one classified task (and the V-07 unified command, which uses the same layout).
    public static func taskPrompt(
        spokenInstruction: String,
        target: String?,
        dictionaryHints: [DictionaryHint] = [],
        stylePreferences: String? = nil,
        outputLanguage: OutputLanguage? = nil,
        language: PromptLanguage
    ) -> String {
        render([
            optionalSection(.outputLanguage, outputLanguage?.name, language),
            optionalSection(.spellingReference, dictionaryLines(dictionaryHints, language), language),
            optionalSection(.stylePreferences, stylePreferences, language),
            section(.spokenInstruction, spokenInstruction, language),
            target.map { section(.targetText, $0, language) }
                ?? plainSection(.targetAvailability, availabilityWord(false, language), language),
        ])
    }

    /// Optimizer input: the draft and only the dictionary entries explicitly mentioned in it (11.3).
    /// `shortenPreviousResult` adds a fixed section only for the single item-count/length retry.
    public static func instructionOptimizerPrompt(
        draft: String,
        kind: CustomInstructionKind,
        mentionedDictionaryHints: [DictionaryHint] = [],
        shortenPreviousResult: Bool = false,
        language: PromptLanguage
    ) -> String {
        render([
            plainSection(.usage, usageWord(kind, language), language),
            optionalSection(.spellingReference, dictionaryLines(mentionedDictionaryHints, language), language),
            section(.draft, draft, language),
            shortenPreviousResult ? (language == .ja ? PromptTextsJA.optimizerRetry : PromptTextsEN.optimizerRetry) : nil,
        ])
    }

    // MARK: - Formatting

    /// One dictionary line: "表記：X（聞き取り例：Y、Z）（メモ：M）" / "Spelling: X (heard as: Y, Z) (note: M)".
    public static func dictionaryLine(_ hint: DictionaryHint, language: PromptLanguage) -> String {
        let readings = hint.readings.filter { !$0.isEmpty }
        let memo = hint.memo?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let hasMemo = !(memo ?? "").isEmpty
        switch language {
        case .ja:
            var line = "表記：\(hint.preferred)"
            if !readings.isEmpty { line += "（聞き取り例：\(readings.joined(separator: "、"))）" }
            if hasMemo, let memo { line += "（メモ：\(memo)）" }
            return line
        case .en:
            var line = "Spelling: \(hint.preferred)"
            if !readings.isEmpty { line += " (heard as: \(readings.joined(separator: ", ")))" }
            if hasMemo, let memo { line += " (note: \(memo))" }
            return line
        }
    }

    static func dictionaryLines(_ hints: [DictionaryHint], _ language: PromptLanguage) -> String? {
        let lines = hints.filter { !$0.preferred.isEmpty }.map { dictionaryLine($0, language: language) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A fence of quote characters longer than any quote run in `content`, so data can never close its
    /// own section (the content itself is passed through unchanged).
    static func fence(for content: String) -> String {
        var longest = 0
        var current = 0
        for character in content {
            if character == "\"" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return String(repeating: "\"", count: max(3, longest + 1))
    }

    static func section(_ section: PromptSection, _ content: String, _ language: PromptLanguage,
                        includeReferenceHeading: Bool = false) -> String {
        let data = escapingSectionHeadings(content, includeReferenceHeading: includeReferenceHeading)
        let fence = fence(for: data)
        return "### \(section.title(language))\n\(fence)\n\(data)\n\(fence)"
    }

    private static let sectionTitles: Set<String> = Set(PromptSection.allCases.filter { $0 != .precedingText }.flatMap { section in
        PromptLanguage.allCases.map { section.title($0).lowercased() }
    })

    /// A data line that looks like one of our section headings ("### 発話指示") is backslash-escaped
    /// ("\\### 発話指示", the Markdown escape), so data can never imitate a section boundary. Other lines,
    /// including ordinary Markdown headings, pass through unchanged.
    static func escapingSectionHeadings(_ content: String, includeReferenceHeading: Bool = false) -> String {
        guard content.contains("#") else { return content }
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return line }
            let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: CharacterSet.whitespaces
                .union(CharacterSet(charactersIn: ":：")))
            let referenceTitle = includeReferenceHeading && PromptLanguage.allCases.contains {
                PromptSection.precedingText.title($0).lowercased() == title.lowercased()
            }
            return sectionTitles.contains(title.lowercased()) || referenceTitle ? "\\" + line : line
        }.joined(separator: "\n")
    }

    static func optionalSection(_ section: PromptSection, _ content: String?, _ language: PromptLanguage,
                                includeReferenceHeading: Bool = false) -> String? {
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self.section(section, content, language, includeReferenceHeading: includeReferenceHeading)
    }

    /// App-generated single values (yes/no, usage) need no fence.
    static func plainSection(_ section: PromptSection, _ value: String, _ language: PromptLanguage) -> String {
        "### \(section.title(language))\n\(value)"
    }

    private static func availabilityWord(_ hasTarget: Bool, _ language: PromptLanguage) -> String {
        switch language {
        case .ja: return hasTarget ? "あり" : "なし"
        case .en: return hasTarget ? "yes" : "no"
        }
    }

    private static func usageWord(_ kind: CustomInstructionKind, _ language: PromptLanguage) -> String {
        switch (kind, language) {
        case (.cleanup, .ja): return "音声入力の整形"
        case (.cleanup, .en): return "dictation cleanup"
        case (.aiCommand, .ja): return "AIへの指示"
        case (.aiCommand, .en): return "spoken AI requests"
        }
    }

    private static func render(_ sections: [String?]) -> String {
        sections.compactMap { $0 }.joined(separator: "\n\n")
    }
}
