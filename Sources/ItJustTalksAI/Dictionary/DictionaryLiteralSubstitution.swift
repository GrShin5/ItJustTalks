import Foundation

/// Literal registrations followed by guarded whole-word sound matches. Pure; never logs text.
public struct DictionaryLiteralSubstitution: Sendable {
    private struct SoundTerm: Sendable {
        var key: PhoneticReading.Key
        var literalReading: String
        var preferred: String
        var rank: Int
    }

    private struct Term: Sendable {
        var pattern: FoldedText
        var preferred: String
        var rank: Int
        var isLatin: Bool
    }

    /// Katakana readings and the Latin preferred spelling of one entry, for mixed-script fragments
    /// such as ジェmini (katakana head of a reading + Latin tail of the spelling).
    private struct MixedTerm: Sendable {
        var kanaReadings: [[Unicode.Scalar]]
        var latin: [Unicode.Scalar]
        var preferred: String
        var rank: Int
    }

    /// Joins adjacent dictionary words found in one katakana/Latin run (Japanese context).
    static let runSeparator = "、"

    private let terms: [Term]
    private let mixedTerms: [MixedTerm]
    private let soundTerms: [SoundTerm]
    private let protectedPatterns: [FoldedText]
    /// Spellings excluded from output-language detection, never from content validation.
    public let preferredSpellings: [String]

    /// `literalSource` restricts output-side candidates to entries with a literal transcript match.
    public init(selection: DictionarySelection, entries: [DictionaryEntry], literalSource: String? = nil) {
        guard !Task.isCancelled else {
            self.terms = []
            self.mixedTerms = []
            self.soundTerms = []
            self.protectedPatterns = []
            self.preferredSpellings = []
            return
        }
        var cancellation = DictionaryCancellationCheckpoint()
        var terms: [Term] = []
        var mixedTerms: [MixedTerm] = []
        var soundTerms: [SoundTerm] = []
        var seenPreferred = Set<String>()
        var protectedPatterns: [FoldedText] = []
        for entry in entries where entry.isEnabled {
            if cancellation.isCancelled() { break }
            let preferred = entry.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preferred.isEmpty, seenPreferred.insert(preferred).inserted {
                protectedPatterns.append(FoldedText(preferred))
            }
        }
        // Hint caps must not limit literal substitutions. Keep selected-entry tie order,
        // then include every remaining entry in registration order.
        let selectedIndices = selection.selected.map(\.entryIndex)
        let selectedSet = Set(selectedIndices)
        let indices = selectedIndices + entries.indices.filter { !selectedSet.contains($0) }
        for (rank, index) in indices.enumerated() {
            if cancellation.isCancelled() { break }
            guard entries.indices.contains(index) else { continue }
            let entry = entries[index]
            guard entry.isEnabled else { continue }
            let preferred = entry.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !preferred.isEmpty else { continue }
            var seen = Set<String>()
            var kanaReadings: [[Unicode.Scalar]] = []
            for reading in DictionaryEntry.normalizedReadings(entry.readings) {
                if cancellation.isCancelled() { break }
                let normalized = reading.precomposedStringWithCompatibilityMapping
                // Sound matching only for entries the selector found in this text.
                if selectedSet.contains(index), let key = PhoneticReading.key(of: reading), key.morae >= 4 {
                    soundTerms.append(SoundTerm(key: key, literalReading: normalized.lowercased(), preferred: preferred, rank: rank))
                }
                let latin = Self.isLatinReading(normalized)
                guard reading.filter({ !$0.isWhitespace }).count >= 3 else { continue }
                for variant in DictionarySelector.termVariants(reading) {
                    let pattern = FoldedText(variant)
                    let key = String(String.UnicodeScalarView(pattern.scalars)) + ":"
                        + pattern.gaps.sorted().map { String($0) }.joined(separator: ",")
                    guard !pattern.scalars.isEmpty, seen.insert(key).inserted else { continue }
                    terms.append(Term(pattern: pattern, preferred: preferred, rank: rank, isLatin: latin))
                    if variant.contains(where: { !$0.isWhitespace }),
                       variant.allSatisfy({ $0.isWhitespace || Self.script($0) == .katakana }) {
                        kanaReadings.append(pattern.scalars)
                    }
                }
            }
            let latinSpelling = Array(FoldedText(preferred).scalars.filter(Self.isASCIIAlphanumeric))
            if !kanaReadings.isEmpty, Self.isLatinReading(preferred.precomposedStringWithCompatibilityMapping),
               latinSpelling.count >= Self.mixedMinimumLatin {
                mixedTerms.append(MixedTerm(kanaReadings: kanaReadings, latin: latinSpelling, preferred: preferred, rank: rank))
            }
        }
        if let literalSource, !Task.isCancelled {
            let folded = FoldedText(literalSource)
            let protected = protectedPatterns.flatMap {
                folded.occurrences(of: $0, restrictWhitespace: Self.isLatinReading($0.text.precomposedStringWithCompatibilityMapping))
            }
            let matchedRanks = Set(terms.filter { term in
                folded.occurrences(of: term.pattern, restrictWhitespace: term.isLatin).contains { span in
                    guard !protected.contains(where: { cancellation.isCancelled() || $0.overlaps(span) }) else { return false }
                    let range = folded.ranges[span.lowerBound].lowerBound..<folded.ranges[span.upperBound - 1].upperBound
                    return Self.hasBoundary(in: literalSource, at: range.lowerBound, before: true, term: term)
                        && Self.hasBoundary(in: literalSource, at: range.upperBound, before: false, term: term)
                }
            }.map(\.rank)).union(Self.runMatches(
                in: literalSource, folded: folded, terms: terms, mixedTerms: mixedTerms, protected: protected
            ).flatMap(\.ranks))
            terms = terms.filter { matchedRanks.contains($0.rank) }
            mixedTerms = mixedTerms.filter { matchedRanks.contains($0.rank) }
            soundTerms = soundTerms.filter { matchedRanks.contains($0.rank) }
        }
        self.terms = terms
        self.mixedTerms = mixedTerms
        self.soundTerms = soundTerms
        self.protectedPatterns = protectedPatterns
        var seen = Set<String>()
        self.preferredSpellings = terms.map(\.preferred).filter { seen.insert($0).inserted }
    }

    private struct Match {
        var span: Range<Int>
        var range: Range<String.Index>
        var replacement: String
        var ranks: [Int]
        var count: Int
    }

    /// `includeSound: false` keeps only literal readings, for validation sources: a sound match is a guess
    /// that the validator must still see as new dictionary text (review-only in hands-free).
    public func apply(to text: String, includeSound: Bool = true) -> (text: String, count: Int) {
        let literal = applyLiteral(to: text)
        guard includeSound else { return literal }
        let sound = applySound(to: literal.text)
        guard !Task.isCancelled else { return (text, 0) }
        return (sound.text, literal.count + sound.count)
    }

    private func applyLiteral(to text: String) -> (text: String, count: Int) {
        guard !Task.isCancelled, !terms.isEmpty, !text.isEmpty else { return (text, 0) }
        var cancellation = DictionaryCancellationCheckpoint()
        let folded = FoldedText(text)
        let protected = protectedPatterns.flatMap {
            folded.occurrences(of: $0, restrictWhitespace: Self.isLatinReading($0.text.precomposedStringWithCompatibilityMapping))
        }
        var matches: [Match] = []
        for term in terms {
            guard !cancellation.isCancelled() else { return (text, 0) }
            for span in folded.occurrences(of: term.pattern, restrictWhitespace: term.isLatin) {
                guard !cancellation.isCancelled() else { return (text, 0) }
                guard !protected.contains(where: { cancellation.isCancelled() || $0.overlaps(span) }) else { continue }
                let range = folded.ranges[span.lowerBound].lowerBound..<folded.ranges[span.upperBound - 1].upperBound
                guard Self.hasBoundary(in: text, at: range.lowerBound, before: true, term: term),
                      Self.hasBoundary(in: text, at: range.upperBound, before: false, term: term),
                      String(text[range]) != term.preferred else { continue }
                // A Latin spelling that replaces a katakana reading next to a digit is kept apart from it
                // (「フェーズ2」 → "Phase 2"), so the term and the number stay separate words.
                var replacement = term.preferred
                if !term.isLatin, Self.isLatinReading(term.preferred) {
                    if range.lowerBound > text.startIndex, Self.isDigit(text[text.index(before: range.lowerBound)]) { replacement = " " + replacement }
                    if range.upperBound < text.endIndex, Self.isDigit(text[range.upperBound]) { replacement += " " }
                }
                matches.append(Match(span: span, range: range, replacement: replacement, ranks: [term.rank], count: 1))
            }
        }
        // A tiled run covers every single-term match inside it, so it wins by length below.
        matches += Self.runMatches(in: text, folded: folded, terms: terms, mixedTerms: mixedTerms, protected: protected)
        guard !Task.isCancelled else { return (text, 0) }
        matches.sort {
            if $0.span.count != $1.span.count { return $0.span.count > $1.span.count }
            if $0.ranks.min()! != $1.ranks.min()! { return $0.ranks.min()! < $1.ranks.min()! }
            return $0.span.lowerBound < $1.span.lowerBound
        }
        var accepted: [Match] = []
        for match in matches {
            guard !cancellation.isCancelled() else { return (text, 0) }
            guard !accepted.contains(where: { cancellation.isCancelled() || $0.span.overlaps(match.span) }) else { continue }
            accepted.append(match)
        }
        var result = text
        for match in accepted.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard !cancellation.isCancelled() else { return (text, 0) }
            result.replaceSubrange(match.range, with: match.replacement)
        }
        guard !Task.isCancelled else { return (text, 0) }
        return (result, accepted.reduce(0) { $0 + $1.count })
    }

    private func applySound(to text: String) -> (text: String, count: Int) {
        guard !Task.isCancelled, !soundTerms.isEmpty, !text.isEmpty else { return (text, 0) }
        var cancellation = DictionaryCancellationCheckpoint()
        let folded = FoldedText(text)
        let protected = protectedPatterns.flatMap { pattern in
            folded.occurrences(of: pattern, restrictWhitespace: Self.isLatinReading(pattern.text))
                .map { folded.ranges[$0.lowerBound].lowerBound..<folded.ranges[$0.upperBound - 1].upperBound }
        }
        let units = PhoneticReading.units(text)
        let scalarIndices = Array(text.unicodeScalars.indices) + [text.endIndex]
        let byKey = Dictionary(grouping: soundTerms, by: { $0.key.key })
        var matches: [Match] = []
        PhoneticReading.forEachSpan(units, keyLengths: Set(byKey.keys.map { $0.utf8.count })) { key, first, last in
            guard !cancellation.isCancelled(), let terms = byKey[key] else { return }
            let spanUnits = units[first...last]
            guard spanUnits.contains(where: { $0.script == .han || $0.script == .hiragana || $0.script == .mixedKana }),
                  !spanUnits.contains(where: { $0.hasNumeral }) else { return }
            let span = units[first].start..<units[last].end
            let range = scalarIndices[span.lowerBound]..<scalarIndices[span.upperBound]
            guard !text[range].unicodeScalars.contains(where: { PhoneticReading.isNumeral($0) || $0.properties.numericType != nil }),
                  !protected.contains(where: { $0.overlaps(range) }) else { return }
            let wordCount = spanUnits.filter(\.startsWord).count
            let literalSpan = String(text[range]).precomposedStringWithCompatibilityMapping.lowercased()
            var seen = Set<String>()
            for term in terms {
                guard !cancellation.isCancelled() else { return }
                // Identically written readings retain the literal pass's boundary guards.
                // A different script or sound-equivalent spelling can use whole-word evidence.
                guard literalSpan != term.literalReading else { continue }
                guard term.key.morae >= 5 || (wordCount >= 2 && term.key.morae >= 4),
                      text[range] != term.preferred, seen.insert(term.preferred).inserted else { continue }
                matches.append(Match(span: span, range: range, replacement: term.preferred, ranks: [], count: 1))
            }
        }
        // Resolve length groups together: equal-length overlaps reserve their original text,
        // so a shorter candidate cannot replace part of an ambiguous longest match.
        var occupied: [Range<Int>] = []
        var accepted: [Match] = []
        let byLength = Dictionary(grouping: matches, by: { $0.span.count })
        for length in byLength.keys.sorted(by: >) {
            guard !cancellation.isCancelled() else { return (text, 0) }
            let candidates = byLength[length]!.filter { match in
                !occupied.contains(where: { $0.overlaps(match.span) })
            }
            for (index, match) in candidates.enumerated() {
                guard !cancellation.isCancelled() else { return (text, 0) }
                let tied = candidates.enumerated().contains { other in
                    other.offset != index && other.element.span.overlaps(match.span)
                }
                if !tied { accepted.append(match) }
                occupied.append(match.span)
            }
        }
        var result = text
        for match in accepted.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard !cancellation.isCancelled() else { return (text, 0) }
            result.replaceSubrange(match.range, with: match.replacement)
        }
        guard !Task.isCancelled else { return (text, 0) }
        return (result, accepted.count)
    }

    // MARK: - Run tiling

    /// Graphemes a reading needs, not counting 「ー」, to be one tile of a run.
    static let minimumTileGraphemes = 3
    static let mixedMinimumKana = 2
    static let mixedMinimumLatin = 3
    /// Coverage guard: (katakana share of the reading) + (Latin share of the spelling).
    /// Each part must be partial; together they must cover about one word, allowing a little overlap.
    static let mixedCoverage: ClosedRange<Double> = 0.8...1.6

    /// Maximal runs of katakana/Latin characters (no hiragana, kanji, punctuation or whitespace) that
    /// contain katakana. A run is replaced when it is fully tiled by ≥2 readings (each ≥3
    /// graphemes not counting the long-vowel mark, so コード / メール cannot be tiles) or by one
    /// mixed-script fragment. A whole Latin segment spelled like a one-word entry (gemini → Gemini)
    /// is also a tile. When the run is not fully tiled, a contiguous core of ≥2 tiles at its head or
    /// tail (or in the middle) is replaced and the untiled rest is kept (LLMリスト + クロードコードコーデックス);
    /// a single tile next to untiled text replaces nothing.
    private static func runMatches(
        in text: String, folded: FoldedText, terms: [Term], mixedTerms: [MixedTerm], protected: [Range<Int>]
    ) -> [Match] {
        let count = folded.scalars.count
        guard !Task.isCancelled, count > 0 else { return [] }
        var cancellation = DictionaryCancellationCheckpoint()
        var scripts: [Script] = []
        for range in folded.ranges {
            guard !cancellation.isCancelled() else { return [] }
            scripts.append(script(text[range.lowerBound]))
        }
        var runs: [Range<Int>] = []
        var start: Int?
        for index in 0..<count {
            guard !cancellation.isCancelled() else { return [] }
            let runnable = scripts[index] == .katakana || scripts[index] == .latin
            if let runStart = start, !runnable || folded.gaps.contains(index) {
                runs.append(runStart..<index)
                start = nil
            }
            if runnable, start == nil { start = index }
        }
        if let runStart = start { runs.append(runStart..<count) }
        runs = runs.filter { run in run.contains { scripts[$0] == .katakana } }
        guard !runs.isEmpty else { return [] }

        struct Tile { var end: Int; var preferred: String; var rank: Int; var mixed: Bool }
        var tilesByStart: [Int: [Tile]] = [:]
        for term in terms {
            guard !cancellation.isCancelled() else { return [] }
            for span in folded.occurrences(of: term.pattern, restrictWhitespace: term.isLatin)
            where !protected.contains(where: { cancellation.isCancelled() || $0.overlaps(span) }) {
                guard !cancellation.isCancelled() else { return [] }
                let reading = text[folded.ranges[span.lowerBound].lowerBound..<folded.ranges[span.upperBound - 1].upperBound]
                guard reading.filter({ !$0.isWhitespace && $0 != "ー" && $0 != "ｰ" }).count >= minimumTileGraphemes else { continue }
                tilesByStart[span.lowerBound, default: []].append(Tile(end: span.upperBound, preferred: term.preferred, rank: term.rank, mixed: false))
            }
        }

        var matches: [Match] = []
        for run in runs {
            guard !cancellation.isCancelled() else { return [] }
            var tiles = tilesByStart.filter { run.contains($0.key) }.mapValues { $0.filter { $0.end <= run.upperBound } }
            for (span, term) in mixedFragments(in: run, folded: folded, scripts: scripts, mixedTerms: mixedTerms)
            where !protected.contains(where: { cancellation.isCancelled() || $0.overlaps(span) }) {
                guard !cancellation.isCancelled() else { return [] }
                tiles[span.lowerBound, default: []].append(Tile(end: span.upperBound, preferred: term.preferred, rank: term.rank, mixed: true))
            }
            // A maximal Latin segment equal to a one-word Latin spelling is the word itself (case aside).
            var segmentStart = run.lowerBound
            while segmentStart < run.upperBound {
                guard !cancellation.isCancelled() else { return [] }
                guard scripts[segmentStart] == .latin else { segmentStart += 1; continue }
                var segmentEnd = segmentStart
                while segmentEnd < run.upperBound, scripts[segmentEnd] == .latin { segmentEnd += 1 }
                let segment = Array(folded.scalars[segmentStart..<segmentEnd])
                for term in mixedTerms where term.latin.elementsEqual(segment)
                    && term.preferred.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }) {
                    tiles[segmentStart, default: []].append(Tile(end: segmentEnd, preferred: term.preferred, rank: term.rank, mixed: false))
                }
                segmentStart = segmentEnd
            }
            // Fewest tiles first, then the lowest rank sum; deterministic for equal keys.
            func tilings(from start: Int) -> [Int: (tiles: Int, rankSum: Int, path: [Tile])]? {
                var best: [Int: (tiles: Int, rankSum: Int, path: [Tile])] = [start: (0, 0, [])]
                for position in start..<run.upperBound {
                    guard !cancellation.isCancelled() else { return nil }
                    guard let current = best[position] else { continue }
                    for tile in tiles[position] ?? [] {
                        guard !cancellation.isCancelled() else { return nil }
                        let candidate = (tiles: current.tiles + 1, rankSum: current.rankSum + tile.rank, path: current.path + [tile])
                        if let existing = best[tile.end],
                           (existing.tiles, existing.rankSum) <= (candidate.tiles, candidate.rankSum) { continue }
                        best[tile.end] = candidate
                    }
                }
                return best
            }
            guard let full = tilings(from: run.lowerBound) else { return [] }
            var core: (span: Range<Int>, tiles: Int, rankSum: Int, path: [Tile])?
            if let tiling = full[run.upperBound], tiling.tiles >= 2 || tiling.path.first?.mixed == true {
                core = (run, tiling.tiles, tiling.rankSum, tiling.path)
            } else {
                // Partial: the longest core of ≥2 tiles; ties go to fewer tiles, lower ranks, earlier start.
                for start in run where !(tiles[start] ?? []).isEmpty {
                    guard let best = start == run.lowerBound ? full : tilings(from: start) else { return [] }
                    for (end, tiling) in best where end > start && tiling.tiles >= 2 {
                        let candidate = (span: start..<end, tiles: tiling.tiles, rankSum: tiling.rankSum, path: tiling.path)
                        if let current = core {
                            let lhs = (-candidate.span.count, candidate.tiles, candidate.rankSum, candidate.span.lowerBound)
                            let rhs = (-current.span.count, current.tiles, current.rankSum, current.span.lowerBound)
                            guard lhs < rhs else { continue }
                        }
                        core = candidate
                    }
                }
            }
            guard let core else { continue }
            let range = folded.ranges[core.span.lowerBound].lowerBound..<folded.ranges[core.span.upperBound - 1].upperBound
            let surrounding = String(text[..<range.lowerBound].suffix(32)) + String(text[range.upperBound...].prefix(32))
            let japanese = surrounding.unicodeScalars.contains { PhoneticReading.isKana($0) || PhoneticReading.isHan($0) || "、。".unicodeScalars.contains($0) }
            let latin = surrounding.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
            let separator = !japanese && latin ? ", " : runSeparator
            let replacement = core.path.map(\.preferred).joined(separator: separator)
            guard String(text[range]) != replacement else { continue }
            matches.append(Match(span: core.span, range: range, replacement: replacement, ranks: core.path.map(\.rank), count: core.tiles))
        }
        return matches
    }

    /// Katakana head + Latin tail inside `run`. The Latin tail runs to the end of the Latin letters;
    /// the katakana head ends where the Latin tail starts (earlier katakana may belong to other tiles).
    private static func mixedFragments(
        in run: Range<Int>, folded: FoldedText, scripts: [Script], mixedTerms: [MixedTerm]
    ) -> [(Range<Int>, MixedTerm)] {
        guard !Task.isCancelled, !mixedTerms.isEmpty else { return [] }
        var cancellation = DictionaryCancellationCheckpoint()
        var found: [(Range<Int>, MixedTerm)] = []
        var latinStart = run.lowerBound
        while latinStart < run.upperBound {
            guard !cancellation.isCancelled() else { return [] }
            guard scripts[latinStart] == .latin, latinStart > run.lowerBound, scripts[latinStart - 1] == .katakana else {
                latinStart += 1
                continue
            }
            var latinEnd = latinStart
            while latinEnd < run.upperBound, scripts[latinEnd] == .latin, isASCIIAlphanumeric(folded.scalars[latinEnd]) {
                guard !cancellation.isCancelled() else { return [] }
                latinEnd += 1
            }
            defer { latinStart = max(latinEnd, latinStart + 1) }
            let latinPart = Array(folded.scalars[latinStart..<latinEnd])
            guard latinPart.count >= mixedMinimumLatin, latinPart.allSatisfy({ $0.properties.isAlphabetic }) else { continue }
            var kanaStart = latinStart
            while kanaStart > run.lowerBound, scripts[kanaStart - 1] == .katakana {
                guard !cancellation.isCancelled() else { return [] }
                kanaStart -= 1
            }
            for headStart in stride(from: kanaStart, through: latinStart - mixedMinimumKana, by: 1) {
                guard !cancellation.isCancelled() else { return [] }
                guard headStart == run.lowerBound || folded.ranges[headStart - 1] != folded.ranges[headStart] else { continue }
                let kanaPart = Array(folded.scalars[headStart..<latinStart])
                for term in mixedTerms where term.latin.count > latinPart.count && term.latin.suffix(latinPart.count).elementsEqual(latinPart) {
                    guard !cancellation.isCancelled() else { return [] }
                    let latinShare = Double(latinPart.count) / Double(term.latin.count)
                    let plausible = term.kanaReadings.contains { reading in
                        guard reading.count > kanaPart.count, reading.prefix(kanaPart.count).elementsEqual(kanaPart) else { return false }
                        return mixedCoverage.contains(Double(kanaPart.count) / Double(reading.count) + latinShare)
                    }
                    if plausible { found.append((headStart..<latinEnd, term)) }
                }
            }
        }
        return found
    }

    /// Span edges can permit a replacement that was blocked inside the original transcript.
    func validationSpans(_ spans: [SelfCorrectionSpan]?) -> [SelfCorrectionSpan]? {
        spans.map { spans in
            var seen = Set<SelfCorrectionSpan>()
            return spans.flatMap { span in
                [span, SelfCorrectionSpan(
                    retracted: apply(to: span.retracted).text,
                    replacement: span.replacement.map { apply(to: $0).text }
                )]
            }.filter { seen.insert($0).inserted }
        }
    }

    /// One folding pass with original grapheme ranges and an index by first scalar.
    private struct FoldedText: Sendable {
        let text: String
        var scalars: [Unicode.Scalar] = []
        var ranges: [Range<String.Index>] = []
        var gaps = Set<Int>()
        var positions: [Unicode.Scalar: [Int]] = [:]

        init(_ text: String) {
            self.text = text
            guard !Task.isCancelled else { return }
            var cancellation = DictionaryCancellationCheckpoint()
            var cache: [Character: [Unicode.Scalar]] = [:]
            var index = text.startIndex
            while index < text.endIndex {
                guard !cancellation.isCancelled() else { return }
                let end = text.index(after: index)
                let character = text[index]
                let folded: [Unicode.Scalar]
                if let cached = cache[character] {
                    folded = cached
                } else {
                    folded = Self.fold(character)
                    cache[character] = folded
                }
                for scalar in folded {
                    if scalar.properties.isWhitespace {
                        gaps.insert(scalars.count)
                    } else {
                        positions[scalar, default: []].append(scalars.count)
                        scalars.append(scalar)
                        ranges.append(index..<end)
                    }
                }
                index = end
            }
        }

        func occurrences(of term: FoldedText, restrictWhitespace: Bool) -> [Range<Int>] {
            guard !Task.isCancelled, let first = term.scalars.first, term.scalars.count <= scalars.count else { return [] }
            var cancellation = DictionaryCancellationCheckpoint()
            var found: [Range<Int>] = []
            for start in positions[first] ?? [] {
                guard !cancellation.isCancelled() else { return [] }
                let end = start + term.scalars.count
                guard end <= scalars.count, scalars[start..<end].elementsEqual(term.scalars),
                      (start == 0 || ranges[start - 1] != ranges[start]),
                      (end == scalars.count || ranges[end - 1] != ranges[end]) else { continue }
                if restrictWhitespace && (1..<term.scalars.count).contains(where: { gaps.contains(start + $0) && !term.gaps.contains($0) }) {
                    continue
                }
                found.append(start..<end)
            }
            return found
        }

        private static func fold(_ character: Character) -> [Unicode.Scalar] {
            let scalars = character.unicodeScalars
            if scalars.count == 1, let scalar = scalars.first {
                if scalar.isASCII {
                    return [Unicode.Scalar((65...90).contains(scalar.value) ? scalar.value + 32 : scalar.value)!]
                }
                if (0x30A1...0x30F6).contains(scalar.value) { return [Unicode.Scalar(scalar.value - 0x60)!] }
                if scalar == "ー" { return [scalar] }
            }
            return Array(TextFolding.fold(String(character)).unicodeScalars)
        }
    }

    private static func hasBoundary(in text: String, at index: String.Index, before: Bool, term: Term) -> Bool {
        guard index > text.startIndex, index < text.endIndex else { return true }
        let left = text[text.index(before: index)]
        let right = text[index]
        let adjacent = before ? left : right
        let preferredEdge = before ? term.preferred.unicodeScalars.first : term.preferred.unicodeScalars.last
        let adjacentScalars = adjacent.unicodeScalars
        let adjacentIsAlphanumeric = adjacentScalars.allSatisfy(\.isASCII)
            ? adjacentScalars.contains(where: isASCIIAlphanumeric)
            : TextFolding.fold(String(adjacent)).unicodeScalars.contains(where: isASCIIAlphanumeric)
        // A katakana reading may touch a digit ("フェーズ2"); Latin letters still block it ("コーデックスapp").
        // The preferred spelling must end in a letter on that side: "Claude 3" next to 「3」 stays blocked.
        let digitNextToKana = !term.isLatin && isLatinReading(term.preferred)
            && script(before ? right : left) == .katakana && isDigit(adjacent)
            && preferredEdge.map { $0.properties.isAlphabetic } == true
        if preferredEdge.map(isASCIIAlphanumeric) == true, adjacentIsAlphanumeric, !digitNextToKana { return false }
        if term.isLatin, adjacentIsAlphanumeric { return false }
        let lhs = script(left), rhs = script(right)
        return lhs == .other || rhs == .other || lhs != rhs
    }

    private static func isDigit(_ character: Character) -> Bool {
        let scalars = TextFolding.fold(String(character)).unicodeScalars
        return !scalars.isEmpty && scalars.allSatisfy { $0.isASCII && $0.properties.numericType != nil }
    }

    private static func isLatinReading(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            isASCIIAlphanumeric($0) || $0.properties.isWhitespace || "&'-_".unicodeScalars.contains($0)
        }
    }

    private enum Script { case hiragana, katakana, han, latin, other }

    private static func baseScalar(_ character: Character) -> Unicode.Scalar? {
        character.unicodeScalars.first {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return false
            default: return true
            }
        }
    }

    private static func script(_ character: Character) -> Script {
        guard let scalar = baseScalar(character), !TextFolding.isSeparator(scalar) else { return .other }
        switch scalar.value {
        case 0x3040...0x309F: return .hiragana
        case 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .katakana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x3005: return .han
        default:
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil ? .latin : .other
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
    }
}
