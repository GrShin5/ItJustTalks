import Foundation

/// One user dictionary entry as the selector sees it (§5.3). Registration limits belong to the app's
/// dictionary store; the selector only decides what is passed to inference.
public struct DictionaryEntry: Sendable, Hashable {
    /// Preferred spelling.
    public var preferred: String
    /// Readings / known mis-recognitions.
    public var readings: [String]
    public var memo: String?
    public var isEnabled: Bool

    /// Shared by registration/import and selection, including previously stored combined readings.
    public static func splitReadings(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",、，､"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func normalizedReadings(_ readings: [String]) -> [String] {
        var seen = Set<String>()
        return readings.flatMap(splitReadings).filter { seen.insert($0).inserted }
    }

    public init(preferred: String, readings: [String] = [], memo: String? = nil, isEnabled: Bool = true) {
        self.preferred = preferred
        self.readings = readings
        self.memo = memo
        self.isEnabled = isEnabled
    }
}

public struct DictionarySelectionOptions: Sendable, Hashable {
    /// Upper bound on selected entries (initial proposal: 8).
    public var maxItems: Int
    /// Upper bound on the summed tokens of the rendered lines (initial proposal: about 200).
    public var tokenBudget: Int
    /// Whether the memo is rendered (V-memo comparison; the plan's default is to include it).
    public var includeMemo: Bool
    /// Terms of at most this many characters (after folding) need clear word boundaries.
    public var shortTermMaxLength: Int
    /// Readings passed per entry (matched reading first).
    public var maxReadingsPerEntry: Int
    /// Language of the rendered lines (token counting only; the prompt is rendered by `PromptAssembler`).
    public var promptLanguage: PromptLanguage
    /// Kana/kanji readings of at least this many morae also match by sound (`PhoneticReading`): a run of whole
    /// words of the text whose romanized reading, vowel length included, equals the reading's (斉藤 ↔ さいとう,
    /// アイティージェイ ↔ あいてぃーじぇー). 0 disables matching by sound.
    public var phoneticMinimumMorae: Int

    public init(
        maxItems: Int = 8,
        tokenBudget: Int = 200,
        includeMemo: Bool = true,
        shortTermMaxLength: Int = 2,
        maxReadingsPerEntry: Int = 5,
        promptLanguage: PromptLanguage = .ja,
        phoneticMinimumMorae: Int = 3
    ) {
        self.maxItems = maxItems
        self.tokenBudget = tokenBudget
        self.includeMemo = includeMemo
        self.shortTermMaxLength = shortTermMaxLength
        self.maxReadingsPerEntry = maxReadingsPerEntry
        self.promptLanguage = promptLanguage
        self.phoneticMinimumMorae = phoneticMinimumMorae
    }
}

/// How an entry matched. Declaration order is the ranking order (reading beats preferred, §5.3; every
/// literal match beats a match by sound).
public enum DictionaryMatchKind: Int, Sendable, Hashable, Comparable {
    /// A span of the text sounds like a reading but is spelled differently (斉藤 for the reading さいとう).
    case phonetic = 0
    /// Entry has no readings; its preferred spelling appears (spelling unification, lowest literal priority).
    case preferredWithoutReadings = 1
    /// Entry has readings but only its preferred spelling appears.
    case preferred = 2
    /// A reading (misrecognition) appears.
    case reading = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SelectedDictionaryEntry: Sendable, Hashable {
    /// Index of the entry in the input array.
    public var entryIndex: Int
    public var hint: DictionaryHint
    public var matchKind: DictionaryMatchKind
    /// Length (folded characters) of the best match.
    public var matchLength: Int
    public var tokens: Int
}

public struct DictionarySelection: Sendable, Hashable {
    public var selected: [SelectedDictionaryEntry]
    /// Entries that matched the text, before the caps.
    public var matchedCount: Int
    /// Matched entries not passed because of `maxItems` or `tokenBudget` (diagnostics: count only).
    public var omittedCount: Int
    public var totalTokens: Int

    public var hints: [DictionaryHint] { selected.map(\.hint) }
}

/// Chooses which dictionary entries are handed to the model for one request (§5.3). Pure; no logging.
///
/// Matching folds both sides with NFKC, katakana → hiragana, width/case fold and whitespace removal.
/// Terms of two characters or fewer match only at clear boundaries (start/end, whitespace, punctuation or a
/// change of script). Longer matches win; a match inside a longer match of another entry is ignored.
/// Kana/kanji readings of at least `phoneticMinimumMorae` morae also match a run of whole words (kana or
/// kanji, never Latin) with the same romanized reading, vowel length included; such matches rank below every
/// literal match. The hint then carries only the entry's own spelling and readings, never the transcript span.
public struct DictionarySelector: Sendable {
    public typealias TokenCounter = @Sendable (String) -> Int

    private let tokenCounter: TokenCounter

    /// - Parameter tokenCounter: tokens of one rendered dictionary line. Inject the model's counter for
    ///   production/evaluation; `estimatedTokens` is a model-free approximation.
    public init(tokenCounter: @escaping TokenCounter = DictionarySelector.estimatedTokens) {
        self.tokenCounter = tokenCounter
    }

    /// Model-free token estimate: about 0.9 token per non-ASCII character and 0.27 per ASCII character.
    public static let estimatedTokens: TokenCounter = { text in
        var total = 0.0
        for scalar in text.unicodeScalars {
            total += scalar.isASCII ? 0.27 : 0.9
        }
        return max(1, Int(total.rounded(.up)))
    }

    public func select(
        entries: [DictionaryEntry],
        text: String,
        options: DictionarySelectionOptions = DictionarySelectionOptions()
    ) -> DictionarySelection {
        let cancelled = DictionarySelection(selected: [], matchedCount: 0, omittedCount: 0, totalTokens: 0)
        guard !Task.isCancelled else { return cancelled }
        var cancellation = DictionaryCancellationCheckpoint()
        var normalizedEntries: [DictionaryEntry] = []
        for entry in entries {
            guard !cancellation.isCancelled() else { return cancelled }
            var normalized = entry
            normalized.readings = DictionaryEntry.normalizedReadings(entry.readings)
            normalizedEntries.append(normalized)
        }
        let entries = normalizedEntries
        guard !Task.isCancelled else { return cancelled }
        let haystack = FoldedHaystack(text)
        guard haystack.scalars.count > 0, options.maxItems > 0, options.tokenBudget > 0 else {
            return DictionarySelection(selected: [], matchedCount: 0, omittedCount: 0, totalTokens: 0)
        }

        // 1. All term occurrences of all enabled entries.
        var occurrences: [Occurrence] = []
        for (index, entry) in entries.enumerated() where entry.isEnabled {
            guard !cancellation.isCancelled() else { return cancelled }
            let preferredFolded = Self.foldTerm(entry.preferred)
            guard !preferredFolded.isEmpty else { continue }
            let readings = entry.readings.filter { !Self.foldTerm($0).isEmpty }
            for (readingIndex, reading) in readings.enumerated() {
                guard !cancellation.isCancelled() else { return cancelled }
                for term in Self.termVariants(reading).map(Self.foldTerm) where !term.isEmpty {
                    guard !cancellation.isCancelled() else { return cancelled }
                    for start in haystack.find(term, shortTermMaxLength: options.shortTermMaxLength) {
                        guard !cancellation.isCancelled() else { return cancelled }
                        occurrences.append(Occurrence(
                            entryIndex: index, kind: .reading, readingIndex: readingIndex,
                            start: start, length: term.count
                        ))
                    }
                }
            }
            let preferredKind: DictionaryMatchKind = readings.isEmpty ? .preferredWithoutReadings : .preferred
            for term in Self.termVariants(entry.preferred).map(Self.foldTerm) where !term.isEmpty {
                guard !cancellation.isCancelled() else { return cancelled }
                for start in haystack.find(term, shortTermMaxLength: options.shortTermMaxLength) {
                    guard !cancellation.isCancelled() else { return cancelled }
                    occurrences.append(Occurrence(
                        entryIndex: index, kind: preferredKind, readingIndex: nil,
                        start: start, length: term.count
                    ))
                }
            }
        }

        // 1b. Matches by sound: a span whose romanized reading equals a (long enough) reading's.
        occurrences += phoneticOccurrences(entries: entries, haystack: haystack, options: options)

        guard !Task.isCancelled else { return cancelled }
        // 2. Longest match first: drop occurrences strictly inside a longer accepted match of another entry.
        //    A match by sound never hides a literal match.
        let byLength = occurrences.sorted {
            if $0.length != $1.length { return $0.length > $1.length }
            if $0.kind != $1.kind { return $0.kind > $1.kind }
            return $0.entryIndex < $1.entryIndex
        }
        var accepted: [Occurrence] = []
        for candidate in byLength {
            guard !cancellation.isCancelled() else { return cancelled }
            let covered = accepted.contains {
                cancellation.isCancelled() || ($0.entryIndex != candidate.entryIndex && $0.length > candidate.length
                    && $0.start <= candidate.start && candidate.end <= $0.end
                    && ($0.kind != .phonetic || candidate.kind == .phonetic))
            }
            if !covered { accepted.append(candidate) }
        }

        // 3. Best surviving occurrence per entry; same preferred spelling is passed once.
        var best: [Int: Occurrence] = [:]
        for occurrence in accepted {
            guard !cancellation.isCancelled() else { return cancelled }
            if let current = best[occurrence.entryIndex], !Self.isBetter(occurrence, current) { continue }
            best[occurrence.entryIndex] = occurrence
        }
        var ranked = best.values.sorted(by: Self.isBetter)
        var seenPreferred = Set<String>()
        ranked = ranked.filter { seenPreferred.insert(entries[$0.entryIndex].preferred).inserted }

        // 4. Caps: item count and token budget (a later, smaller entry may still fit).
        var selected: [SelectedDictionaryEntry] = []
        var usedTokens = 0
        for occurrence in ranked {
            guard !cancellation.isCancelled() else { return cancelled }
            guard selected.count < options.maxItems else { break }
            let entry = entries[occurrence.entryIndex]
            guard let built = build(entry: entry, occurrence: occurrence, options: options, remaining: options.tokenBudget - usedTokens)
            else { continue }
            usedTokens += built.tokens
            selected.append(SelectedDictionaryEntry(
                entryIndex: occurrence.entryIndex, hint: built.hint, matchKind: occurrence.kind,
                matchLength: occurrence.length, tokens: built.tokens
            ))
        }
        guard !Task.isCancelled else { return cancelled }
        return DictionarySelection(
            selected: selected,
            matchedCount: ranked.count,
            omittedCount: ranked.count - selected.count,
            totalTokens: usedTokens
        )
    }

    // MARK: - Matching by sound

    private func phoneticOccurrences(
        entries: [DictionaryEntry], haystack: FoldedHaystack, options: DictionarySelectionOptions
    ) -> [Occurrence] {
        guard !Task.isCancelled, options.phoneticMinimumMorae > 0 else { return [] }
        var cancellation = DictionaryCancellationCheckpoint()
        // Same reading numbering as the literal pass (non-empty folded readings only).
        var targets: [String: [(entryIndex: Int, readingIndex: Int)]] = [:]
        var keyLengths = Set<Int>()
        let eligible = entries.filter { $0.isEnabled && !Self.foldTerm($0.preferred).isEmpty }
            .flatMap(\.readings).filter(Self.isKanaOrKanjiReading)
        let keys = PhoneticReading.cachedKeys(of: eligible)
        for (index, entry) in entries.enumerated() where entry.isEnabled && !Self.foldTerm(entry.preferred).isEmpty {
            guard !cancellation.isCancelled() else { return [] }
            let usable = entry.readings.filter { !Self.foldTerm($0).isEmpty }
            for (readingIndex, reading) in usable.enumerated() where Self.isKanaOrKanjiReading(reading) {
                guard let key = keys[reading], key.morae >= options.phoneticMinimumMorae else { continue }
                targets[key.key, default: []].append((index, readingIndex))
                keyLengths.insert(key.key.utf8.count)
            }
        }
        guard !targets.isEmpty else { return [] }
        guard !Task.isCancelled else { return [] }
        let units = haystack.phoneticUnits().filter { $0.script != .latin && !$0.hasNumeral }
        var occurrences: [Occurrence] = []
        PhoneticReading.forEachSpan(units, keyLengths: keyLengths) { key, first, last in
            guard let matches = targets[key], occurrences.count < 400 else { return }
            let start = units[first].start
            let length = units[last].end - start
            for match in matches {
                occurrences.append(Occurrence(
                    entryIndex: match.entryIndex, kind: .phonetic, readingIndex: match.readingIndex,
                    start: start, length: length
                ))
            }
        }
        return occurrences
    }

    /// Readings written only in kana / kanji (whitespace and punctuation allowed): Latin readings never match
    /// by sound ("boot" must not find "bot").
    static func isKanaOrKanjiReading(_ reading: String) -> Bool {
        var hasJapanese = false
        for scalar in reading.unicodeScalars {
            if PhoneticReading.isKana(scalar) || PhoneticReading.isHan(scalar) {
                hasJapanese = true
            } else if PhoneticReading.isLatinOrDigit(scalar) || scalar.properties.isAlphabetic {
                return false
            }
        }
        return hasJapanese
    }

    // MARK: - Hint construction

    private func build(
        entry: DictionaryEntry,
        occurrence: Occurrence,
        options: DictionarySelectionOptions,
        remaining: Int
    ) -> (hint: DictionaryHint, tokens: Int)? {
        var readings: [String] = []
        var seen = Set<String>()
        func add(_ reading: String) {
            let trimmed = Self.singleLine(reading)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted { readings.append(trimmed) }
        }
        if let index = occurrence.readingIndex {
            // `readingIndex` counts only non-empty folded readings; map back to the original string.
            let usable = entry.readings.filter { !Self.foldTerm($0).isEmpty }
            if index < usable.count { add(usable[index]) }
        }
        entry.readings.forEach(add)
        readings = Array(readings.prefix(max(0, options.maxReadingsPerEntry)))

        // Original casing is kept; line breaks become spaces so one entry stays one prompt line.
        let preferred = Self.singleLine(entry.preferred)
        let memo = options.includeMemo ? entry.memo.map(Self.singleLine) : nil
        var candidates: [DictionaryHint] = []
        if let memo, !memo.isEmpty {
            candidates.append(DictionaryHint(preferred: preferred, readings: readings, memo: memo))
        }
        candidates.append(DictionaryHint(preferred: preferred, readings: readings))
        for hint in candidates {
            // +1 for the newline that joins lines.
            let tokens = tokenCounter(PromptAssembler.dictionaryLine(hint, language: options.promptLanguage)) + 1
            if tokens <= remaining { return (hint, tokens) }
        }
        return nil
    }

    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func isBetter(_ lhs: Occurrence, _ rhs: Occurrence) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind > rhs.kind }
        if lhs.length != rhs.length { return lhs.length > rhs.length }
        if lhs.entryIndex != rhs.entryIndex { return lhs.entryIndex < rhs.entryIndex }
        return lhs.start < rhs.start
    }

    /// Term folded for matching: fold + whitespace removed.
    static func foldTerm(_ text: String) -> [Unicode.Scalar] {
        TextFolding.fold(text).unicodeScalars.filter { !$0.properties.isWhitespace }
    }

    /// Expand terms only; hints and the request text keep their original spelling.
    static func termVariants(_ term: String) -> [String] {
        var variants = [term]
        if term.contains("ヴ") {
            var plain = term
            for (from, to) in [("ヴァ", "バ"), ("ヴィ", "ビ"), ("ヴゥ", "ブ"), ("ヴェ", "ベ"), ("ヴォ", "ボ"), ("ヴ", "ブ")] {
                plain = plain.replacingOccurrences(of: from, with: to)
            }
            variants.append(plain)
        }
        for variant in variants {
            var andRanges: [Range<String.Index>] = []
            var searchStart = variant.startIndex
            while let range = variant.range(of: "アンド", range: searchStart..<variant.endIndex) {
                if range.lowerBound > variant.startIndex, range.upperBound < variant.endIndex,
                   Self.isKatakanaWordCharacter(variant[variant.index(before: range.lowerBound)]),
                   Self.isKatakanaWordCharacter(variant[range.upperBound]) { andRanges.append(range) }
                searchStart = range.upperBound
            }
            var symbolVariant = variant
            for range in andRanges.reversed() { symbolVariant.replaceSubrange(range, with: "&") }
            if !andRanges.isEmpty, Self.foldTerm(symbolVariant).count >= 4 { variants.append(symbolVariant) }
            if variant.contains("&") {
                variants.append(variant.replacingOccurrences(of: "&", with: "アンド"))
                if variant.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) {
                    variants.append(variant.replacingOccurrences(of: "&", with: " and "))
                }
            }
            let andVariant = variant.replacingOccurrences(of: " and ", with: "&", options: .caseInsensitive)
            if andVariant != variant { variants.append(andVariant) }
        }
        var seen = Set<String>()
        return variants.filter { seen.insert($0).inserted }
    }

    private static func isKatakanaWordCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x30A1...0x30FA).contains(scalar.value) || scalar == "ー"
    }

    // MARK: - Types

    private struct Occurrence {
        var entryIndex: Int
        var kind: DictionaryMatchKind
        var readingIndex: Int?
        var start: Int
        var length: Int
        var end: Int { start + length }
    }
}

/// Poll once per 256 loop iterations, including the first. Cancelled partial work is discarded by callers.
struct DictionaryCancellationCheckpoint {
    private var iterations = 0
    private var cancelled = false

    mutating func isCancelled() -> Bool {
        if cancelled { return true }
        defer { iterations &+= 1 }
        if iterations & 255 == 0 { cancelled = Task.isCancelled }
        return cancelled
    }
}

// MARK: - Folded haystack

/// The folded request text with whitespace removed, remembering where whitespace was.
private struct FoldedHaystack {
    var scalars: [Unicode.Scalar] = []
    /// `gapBefore[i]` is true when whitespace (or the text edge) precedes `scalars[i]`; the extra last
    /// element describes the end of the text.
    var gapBefore: [Bool] = []
    private var aligned = false
    private var boundaryScalars: [Unicode.Scalar] = []
    private var positions: [UInt32: [Int]] = [:]
    /// Text analysed for matching by sound: NFKC + lower case (kana kept as written) when it lines up
    /// scalar for scalar with the folded text, otherwise the folded text itself.
    private var readable = ""
    /// Haystack index of each scalar of `readable` (nil for whitespace).
    private var haystackIndex: [Int?] = []

    init(_ text: String) {
        guard !Task.isCancelled else { return }
        var cancellation = DictionaryCancellationCheckpoint()
        var scalars: [Unicode.Scalar] = []
        var gaps: [Bool] = []
        var pendingGap = true
        var haystackIndex: [Int?] = []
        let folded = TextFolding.fold(text)
        for scalar in folded.unicodeScalars {
            guard !cancellation.isCancelled() else { return }
            if scalar.properties.isWhitespace {
                pendingGap = true
                haystackIndex.append(nil)
            } else {
                haystackIndex.append(scalars.count)
                scalars.append(scalar)
                gaps.append(pendingGap)
                pendingGap = false
            }
        }
        guard !Task.isCancelled else { return }
        let written = text.precomposedStringWithCompatibilityMapping.lowercased()
        let writtenScalars = Array(written.unicodeScalars)
        let aligned = writtenScalars.count == haystackIndex.count
            && zip(writtenScalars, folded.unicodeScalars).allSatisfy { $0.properties.isWhitespace == $1.properties.isWhitespace }
        self.aligned = aligned
        self.readable = aligned ? written : folded
        self.boundaryScalars = aligned ? writtenScalars.filter { !$0.properties.isWhitespace } : scalars
        self.haystackIndex = haystackIndex
        gaps.append(true)
        self.scalars = scalars
        self.gapBefore = gaps
        var positions: [UInt32: [Int]] = [:]
        for (index, scalar) in scalars.enumerated() {
            guard !cancellation.isCancelled() else { return }
            positions[scalar.value, default: []].append(index)
        }
        self.positions = positions
    }

    /// Units for matching by sound, with positions mapped to haystack offsets.
    func phoneticUnits() -> [PhoneticReading.Unit] {
        PhoneticReading.units(readable).compactMap { unit in
            guard unit.end > unit.start, let start = haystackIndex[unit.start], let last = haystackIndex[unit.end - 1]
            else { return nil }
            var mapped = unit
            mapped.start = start
            mapped.end = last + 1
            return mapped
        }
    }

    /// Start offsets of `term`. Short terms must sit at clear boundaries.
    func find(_ term: [Unicode.Scalar], shortTermMaxLength: Int) -> [Int] {
        guard !Task.isCancelled, let first = term.first, term.count <= scalars.count,
              let starts = positions[first.value] else { return [] }
        var cancellation = DictionaryCancellationCheckpoint()
        let needsBoundary = term.count <= shortTermMaxLength
        var found: [Int] = []
        for start in starts {
            guard !cancellation.isCancelled() else { return [] }
            let end = start + term.count
            guard end <= scalars.count else { continue }
            var matches = true
            for offset in 1..<max(1, term.count) {
                guard !cancellation.isCancelled() else { return [] }
                if scalars[start + offset] != term[offset] {
                    matches = false
                    break
                }
            }
            guard matches else { continue }
            if needsBoundary && !(hasBoundary(before: start) && hasBoundary(after: end)) { continue }
            found.append(start)
            if found.count >= 200 { break }
        }
        return found
    }

    private func hasBoundary(before index: Int) -> Bool {
        if index == 0 || gapBefore[index] { return true }
        return Self.isBoundary(between: boundaryScalars[index - 1], and: boundaryScalars[index], separateKana: aligned)
    }

    private func hasBoundary(after index: Int) -> Bool {
        if index >= scalars.count || gapBefore[index] { return true }
        return Self.isBoundary(between: boundaryScalars[index - 1], and: boundaryScalars[index], separateKana: aligned)
    }

    private static func isBoundary(between left: Unicode.Scalar, and right: Unicode.Scalar, separateKana: Bool) -> Bool {
        let leftClass = scriptClass(left, separateKana: separateKana)
        let rightClass = scriptClass(right, separateKana: separateKana)
        return leftClass == .other || rightClass == .other || leftClass != rightClass
    }

    private enum Script { case hiragana, katakana, han, alphanumeric, other }

    private static func scriptClass(_ scalar: Unicode.Scalar, separateKana: Bool) -> Script {
        let value = scalar.value
        if separateKana {
            if TextFolding.isSeparator(scalar) { return .other }
        } else if (0x3040...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value) {
            return .hiragana
        }
        switch value {
        case 0x3040...0x309F: return .hiragana
        case 0x30A0...0x30FF, 0x31F0...0x31FF: return .katakana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x3005: return .han
        default:
            if TextFolding.isSeparator(scalar) { return .other }
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil ? .alphanumeric : .other
        }
    }
}
