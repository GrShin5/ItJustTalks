import Foundation

/// Projects a proposal onto its source without trusting model-authored content.
struct EditProjector: Sendable {
    struct Input: Sendable {
        var source: String
        var output: String
        var language: String
        var dictionary: [(surface: String, readings: [String])] = []
        /// Each entry must include the retracted text AND its verified cue.
        var verifiedRetractions: [String] = []
        /// False keeps every spoken word: only punctuation, whitespace, fillers and dictionary spellings
        /// are taken from the proposal (the safe text used instead of a review window).
        var allowsContentDeletions = true
    }

    struct Result: Sendable {
        var text: String
        var fellBack: Bool
        var alignment: Double
        var accepted: [EditKind: Int]
        var rejected: [EditKind: Int]
    }

    enum EditKind: Sendable, Hashable {
        case punctuation, whitespace, fillerDeletion, repetitionDeletion, retractionDeletion
        case caseChange, dictionarySurface, wordChange, insertion, deletion, terminalCompletion, restartDeletion
    }

    private struct Hunk {
        var source: Range<Int>
        var output: Range<Int>
    }

    private static func decoration(_ c: Character) -> Bool { c.isPunctuation || c.isWhitespace }
    private static func asciiAlphanumeric(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { ($0.value < 0x80 && CharacterSet.alphanumerics.contains($0)) || (0xFF10...0xFF19).contains($0.value) }
    }
    private static func terminal(_ c: Character) -> Bool { "。．.!?！？".contains(c) }

    static func project(_ input: Input) -> Result {
        if input.language.hasPrefix("en") { return projectEnglish(input) }
        // Unambiguous hesitations go first, so a chain the model only partly removed (「えーとあのえっと」)
        // is recognised as a chain.
        var input = input
        let original = input.source
        input.source = stripHesitations(original)
        let preStripped = input.source != original
        let s = Array(input.source), o = Array(input.output)
        let enumerationMarks = enumerationCommas(in: s)
        // Alignment is measured after registered readings are spelled as their surfaces, so a
        // proposal that only applies dictionary spellings is not mistaken for a rewrite.
        let lexicalS = Array(spellingDictionary(input.source, input.dictionary)).filter { !decoration($0) }
        let lexicalO = o.filter { !decoration($0) }
        let alignment = lexicalS.isEmpty ? 1 : Double(matches(lexicalS, lexicalO).count) / Double(lexicalS.count)
        let fillerHunks = hunks(s, Array(FillerStripper.strip(input.source)))
        var result = Result(text: "", fellBack: false, alignment: alignment, accepted: preStripped ? [.fillerDeletion: 1] : [:], rejected: [:])
        // Rejected hunks fall back to the source anyway; this only guards against an unrelated reply
        // (an answer instead of the transcript) whose scattered matches would place punctuation oddly.
        if input.output.isEmpty || alignment < 0.4 {
            result.text = stripHesitations(FillerStripper.strip(input.source))
            result.fellBack = true
            result.accepted[.fillerDeletion] = fillerHunks.count + (preStripped ? 1 : 0)
            return result
        }
        let verified = input.verifiedRetractions.flatMap { occurrences(Array($0), in: s) }
        var edits = hunks(s, o)
        // Prefer a verified occurrence over an ambiguous LCS through a repeated restart.
        if let range = verified.first(where: { String(s[..<$0.lowerBound]) + String(s[$0.upperBound...]) == input.output }) {
            edits = [Hunk(source: range, output: range.lowerBound..<range.lowerBound)]
        }
        // A character LCS can split a dictionary replacement around shared letters. Join
        // only the rectangle for a complete, exact registered reading/surface pair.
        for entry in input.dictionary where !entry.surface.isEmpty {
            for reading in entry.readings where !reading.isEmpty {
                let variants = Set([reading, kana(reading), katakana(reading)])
                for variant in variants {
                    for sr in occurrences(Array(variant), in: s) {
                        for or in occurrences(Array(entry.surface), in: o) {
                            let touching = edits.indices.filter {
                                intersects(edits[$0].source, sr) || intersects(edits[$0].output, or)
                            }
                            guard !touching.isEmpty,
                                  touching.allSatisfy({ sr.lowerBound <= edits[$0].source.lowerBound && edits[$0].source.upperBound <= sr.upperBound && or.lowerBound <= edits[$0].output.lowerBound && edits[$0].output.upperBound <= or.upperBound }),
                                  sr.lowerBound - (touching.first.map { edits[$0].source.lowerBound } ?? 0) == or.lowerBound - (touching.first.map { edits[$0].output.lowerBound } ?? 0)
                            else { continue }
                            edits = edits.enumerated().filter { !touching.contains($0.offset) }.map(\.element)
                            edits.append(Hunk(source: sr, output: or))
                            edits.sort { $0.source.lowerBound < $1.source.lowerBound }
                        }
                    }
                }
            }
        }
        // Dictionary spellings the model applied to a sound match 「渡辺」→「渡邉」「ケイエムエス」→「KMS」:
        // the span between the matched neighbours of the spelling in the proposal is replaced, when it is
        // short, has no marks or digits, and every edit touching it lies inside it.
        var anchored = Set<Int>()
        let pairs = matches(s, o)
        var oToS: [Int: Int] = [:]
        for (a, b) in pairs { oToS[b] = a }
        for entry in input.dictionary where !entry.surface.isEmpty {
            for or in occurrences(Array(entry.surface), in: o) where !or.allSatisfy({ oToS[$0] != nil }) {
                let lo = (0..<or.lowerBound).reversed().first(where: { oToS[$0] != nil }).map { oToS[$0]! + 1 } ?? 0
                let hi = (or.upperBound..<o.count).first(where: { oToS[$0] != nil }).map { oToS[$0]! } ?? s.count
                guard lo < hi else { continue }
                let span = Array(s[lo..<hi])
                guard !span.contains(where: { decoration($0) || $0.isNumber }),
                      span.count <= max(entry.surface.count + 2, 2 * entry.surface.count),
                      !String(span).contains(entry.surface),
                      or.allSatisfy({ oToS[$0].map { lo <= $0 && $0 < hi } ?? true }) else { continue }
                let touching = edits.indices.filter { intersects(edits[$0].source, lo..<hi) || intersects(edits[$0].output, or) }
                guard touching.allSatisfy({ lo <= edits[$0].source.lowerBound && edits[$0].source.upperBound <= hi
                    && or.lowerBound <= edits[$0].output.lowerBound && edits[$0].output.upperBound <= or.upperBound }) else { continue }
                edits = edits.enumerated().filter { !touching.contains($0.offset) }.map(\.element)
                edits.append(Hunk(source: lo..<hi, output: or))
                edits.sort { $0.source.lowerBound < $1.source.lowerBound }
                anchored.insert(lo)
            }
        }
        if !input.dictionary.isEmpty, input.source != input.output,
           dictionaryRunAroundDifference(input.source, input.output, dictionary: input.dictionary) {
            edits = [Hunk(source: 0..<s.count, output: 0..<o.count)]
        }
        var cursor = 0
        for edit in edits {
            guard edit.source.lowerBound >= cursor else { continue }
            result.text += String(s[cursor..<edit.source.lowerBound])
            let removed = String(s[edit.source]), inserted = String(o[edit.output])
            let plainRemoved = removed.filter { !decoration($0) }
            let plainInserted = inserted.filter { !decoration($0) }
            var kind: EditKind
            var accept = false
            /// Source text kept when the edit is rejected (defaults to the whole removed span).
            var keep: String? = nil
            if plainRemoved.isEmpty && plainInserted.isEmpty {
                kind = (removed + inserted).allSatisfy(\.isWhitespace) ? .whitespace : .punctuation
                // 「3.5」→「35」, "ice cream" → "icecream", "were" → "we're": a mark or space between letters or
                // digits of the same token is part of the words, not punctuation.
                let before = edit.source.lowerBound > 0 ? s[edit.source.lowerBound - 1] : nil
                let after = edit.source.upperBound < s.count ? s[edit.source.upperBound] : nil
                accept = !(before.map(asciiAlphanumeric) == true && after.map(asciiAlphanumeric) == true)
                if removed.contains("、"), !inserted.contains("、"),
                   edit.source.contains(where: { enumerationMarks.contains($0) }) {
                    accept = false
                }
                if removed == " ", inserted.isEmpty,
                   let before, let after, before.isUppercase, after.isUppercase {
                    var lo = edit.source.lowerBound - 1, hi = edit.source.upperBound + 1
                    while lo > 0 && (s[lo - 1] == " " || s[lo - 1].isUppercase) { lo -= 1 }
                    while hi < s.count && (s[hi] == " " || s[hi].isUppercase) { hi += 1 }
                    let run = String(s[lo..<hi]).trimmingCharacters(in: .whitespaces)
                    let letters = run.split(separator: " ")
                    accept = letters.count >= 2 && letters.allSatisfy { $0.count == 1 && $0.first!.isASCII && $0.first!.isUppercase }
                }
                // A space the deterministic spacing step removes (「この 3つ」) is not put back from the proposal.
                if removed.isEmpty, !inserted.isEmpty, inserted.allSatisfy({ $0 == " " || $0 == "　" }),
                   let before, let after,
                   JapaneseSpacing.normalize(String(before) + inserted + String(after)) == String(before) + String(after) {
                    accept = false
                }
                if removed.isEmpty, inserted.first.map({ "、。,.!?！？".contains($0) }) == true,
                   result.text.last.map({ "、。,.!?！？".contains($0) }) == true {
                    accept = false
                }
                if edit.source.upperBound == s.count, inserted.contains(where: terminal),
                   (endsOpen(input.source, language: input.language)
                    || input.source.trimmingCharacters(in: .whitespacesAndNewlines).last.map({ "、,".contains($0) }) == true) {
                    kind = .terminalCompletion
                    accept = false
                }
            } else if plainInserted.isEmpty && !plainRemoved.isEmpty {
                kind = .deletion
                func classify(_ range: Range<Int>) -> EditKind? {
                    // A pure deletion can sit at several equivalent positions (「来週の月曜、来週の火曜」 may be
                    // aligned as 「月曜、来週の」); all of them leave the same text, so classify on any of them.
                    let positions = slides(range, in: s)
                    if positions.contains(where: { p in fillerHunks.contains(where: { $0.source.lowerBound <= p.lowerBound && p.upperBound <= $0.source.upperBound }) }) { return .fillerDeletion }
                    if positions.contains(where: { p in verified.contains(where: { $0.lowerBound <= p.lowerBound && p.upperBound <= $0.upperBound }) }) { return .retractionDeletion }
                    if positions.contains(where: { repetition($0, in: s, english: input.language.hasPrefix("en")) }) { return .repetitionDeletion }
                    if positions.contains(where: { restart($0, in: s, language: input.language) }) { return .restartDeletion }
                    if englishLike(range, in: s, language: input.language) { return .fillerDeletion }
                    return nil
                }
                func allowed(_ k: EditKind) -> Bool { k == .fillerDeletion || input.allowsContentDeletions }
                if let k = classify(edit.source) {
                    kind = k; accept = allowed(k)
                }
                // 「えーと来週の月曜、」: peel unambiguous fillers off the deletion and judge the rest alone.
                if !accept, let rest = peelingFillers(edit.source, in: s) {
                    result.accepted[.fillerDeletion, default: 0] += 1
                    if rest.isEmpty {
                        kind = .fillerDeletion; accept = true
                    } else if let k = classify(rest), allowed(k) {
                        kind = k; accept = true
                    } else {
                        // Keep the remaining words and the marks around them; only the fillers go.
                        let before = s[edit.source.lowerBound..<rest.lowerBound].filter { decoration($0) && !$0.isWhitespace }
                        let after = s[rest.upperBound..<edit.source.upperBound].filter { decoration($0) && !$0.isWhitespace }
                        keep = String(before) + String(s[rest]) + String(after)
                    }
                }
            } else if anchored.contains(edit.source.lowerBound) || dictionaryRun(removed, inserted, dictionary: input.dictionary) {
                kind = .dictionarySurface; accept = true
            } else {
                kind = removed.isEmpty ? .insertion : .wordChange
            }
            if accept {
                // Newlines may only follow a sentence boundary in either proposal or source.
                var previous = result.text.last
                for c in inserted {
                    if !c.isNewline || previous.map(terminal) == true || (edit.source.lowerBound > 0 && terminal(s[edit.source.lowerBound - 1])) {
                        result.text.append(c)
                    }
                    if !c.isWhitespace { previous = c }
                }
                result.accepted[kind, default: 0] += 1
            } else {
                var kept = keep ?? removed
                // Keep a boundary mark the proposal put after the rejected words (「…ほしいです」+「。」).
                let trailing = String(inserted.reversed().prefix(while: { $0.isPunctuation && !$0.isWhitespace }).reversed())
                if !trailing.isEmpty, !kept.hasSuffix(trailing), !removed.isEmpty,
                   kept.last.map({ !"、。,.!?！？".contains($0) }) != false,
                   !(edit.source.upperBound == s.count && trailing.contains(where: terminal) && endsOpen(input.source, language: input.language)) {
                    kept += trailing
                }
                result.text += kept
                result.rejected[kind, default: 0] += 1
            }
            cursor = edit.source.upperBound
        }
        result.text += String(s[cursor...])
        result.text = normalize(stripHesitations(result.text))
        return result
    }

    /// Only short, comma-separated noun-like runs qualify; spaces and other marks end a run.
    private static func enumerationCommas(in source: [Character]) -> Set<Int> {
        // Multi-kana endings mark a predicate anywhere; a single kana only right after a kanji (「行く」「高い」),
        // so kana nouns such as 「みかん」「うどん」「とけい」 still count as items.
        let endings = ["です", "ます", "ました", "でした", "ない", "だった", "から", "ので", "けど", "のに"]
        let kanaEndings: Set<Character> = ["た", "だ", "る", "い", "は", "が", "を", "に", "へ", "と", "で", "も", "の", "て"]
        func isPredicateOrParticle(_ item: String) -> Bool {
            if endings.contains(where: item.hasSuffix) { return true }
            guard let last = item.last, kanaEndings.contains(last) else { return false }
            let previous = item.dropLast().last
            return previous.map { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) } } ?? true
        }
        var protected = Set<Int>()
        var items = 0, marks: [Int] = []
        func finish() {
            if items >= 3 { protected.formUnion(marks) }
            items = 0; marks = []
        }
        var i = 0
        while i < source.count {
            let start = i
            while i < source.count, source[i].isLetter || source[i].isNumber { i += 1 }
            let item = String(source[start..<i])
            if (1...8).contains(item.count), !isPredicateOrParticle(item) {
                if items > 0 { marks.append(start - 1) }
                items += 1
            } else {
                finish()
            }
            // Continue through a comma only when another item follows.
            let continues = i < source.count && source[i] == "、" && items > 0
                && i + 1 < source.count && (source[i + 1].isLetter || source[i + 1].isNumber)
            if !continues {
                finish()
            }
            if i < source.count { i += 1 }
        }
        finish()
        return protected
    }

    private static let hesitation = try! NSRegularExpression(pattern: #"\A(?:え[ーえ]+っ?と|えっと|えー+|あの[ーう]+)"#)
    private static let fillerStarts = ["えーっと", "えーと", "えっと", "えー", "あのー", "あのう", "あの", "その", "まあ", "なんか"]

    /// Unambiguous hesitation words at a pause are removed even when the model kept them
    /// (「えーとあの確認」); あの/その/まあ/なんか only when a pause mark follows them (「あの、」),
    /// since 「あの件」 is content. Quoted speech is kept.
    static func stripHesitations(_ text: String, language: String = "ja") -> String {
        if language.hasPrefix("en") { return stripEnglishHesitations(text) }
        let chars = Array(text)
        var out: [Character] = []
        var i = 0, quoteDepth = 0
        func atPause() -> Bool {
            guard let last = out.last(where: { !$0.isWhitespace || $0.isNewline }) else { return true }
            return last.isNewline || "。、，．,.!?！？「『（(".contains(last)
        }
        func skipSeparators() { while i < chars.count && "、,， 　".contains(chars[i]) { i += 1 } }
        while i < chars.count {
            let c = chars[i]
            if "「『“".contains(c) { quoteDepth += 1 } else if "」』”".contains(c) { quoteDepth = max(0, quoteDepth - 1) }
            if quoteDepth == 0, atPause() {
                let rest = String(chars[i...])
                if let m = hesitation.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                   let r = Range(m.range, in: rest) {
                    var n = rest[r].count
                    // A trailing 「ー」「お」 (「えーとお」) belongs to the filler only before a pause.
                    var tail = n
                    while i + tail < chars.count, "ーお".contains(chars[i + tail]) { tail += 1 }
                    if tail > n, i + tail >= chars.count || "、,， 　。".contains(chars[i + tail]) { n = tail }
                    // Only before a pause, the end, a non-hiragana word (「えーと会議」) or another filler —
                    // never in front of hiragana that may continue a word (「あのうどん」「えっとお願い」).
                    let after = String(chars[min(i + n, chars.count)...])
                    let next = i + n < chars.count ? chars[i + n] : nil
                    let hiragana = next.map { $0.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) } } ?? false
                    if next == nil || "、,， 　".contains(next!) || !hiragana || fillerStarts.contains(where: after.hasPrefix) {
                        i += n; skipSeparators(); continue
                    }
                }
                if let weak = ["あの", "その", "まあ", "なんか"].first(where: { w in
                    guard rest.hasPrefix(w), rest.count > w.count else { return false }
                    // 「あの、」 or a filler chain 「あのえっと」.
                    return "、,， 　".contains(chars[i + w.count])
                        || ["えーっと", "えーと", "えっと", "あのー", "あのう"].contains(where: String(chars[(i + w.count)...]).hasPrefix)
                }) {
                    i += weak.count; skipSeparators(); continue
                }
            }
            out.append(c); i += 1
        }
        let stripped = String(out)
        return stripped.allSatisfy(\.isWhitespace) ? text : stripped
    }

    /// dictionaryRun on the differing middle only (common head and tail trimmed at a non-letter boundary),
    /// so the recursion depth stays small; very long differences are not tried.
    private static func dictionaryRunAroundDifference(_ source: String, _ output: String,
                                                      dictionary: [(surface: String, readings: [String])]) -> Bool {
        let s = Array(source), o = Array(output)
        var head = 0
        while head < s.count, head < o.count, s[head] == o[head] { head += 1 }
        while head > 0, s[head - 1].isLetter || s[head - 1].isNumber { head -= 1 }
        var tail = 0
        while tail < s.count - head, tail < o.count - head, s[s.count - 1 - tail] == o[o.count - 1 - tail] { tail += 1 }
        while tail > 0, s[s.count - tail].isLetter || s[s.count - tail].isNumber { tail -= 1 }
        guard s.count - head - tail <= 400, o.count - head - tail <= 400 else { return false }
        return dictionaryRun(String(s[head..<(s.count - tail)]), String(o[head..<(o.count - tail)]), dictionary: dictionary)
    }

    /// Covers adjacent registered terms without manufacturing separators between them.
    private static func dictionaryRun(_ source: String, _ output: String,
                                      dictionary: [(surface: String, readings: [String])]) -> Bool {
        let s = Array(source), o = Array(output)
        var failed: Set<String> = []
        func consume(_ i: Int, _ j: Int) -> Bool {
            if i == s.count && j == o.count { return true }
            let key = "\(i):\(j)"
            if failed.contains(key) { return false }
            if i < s.count, j < o.count, s[i] == o[j], consume(i + 1, j + 1) { return true }
            for entry in dictionary where !entry.surface.isEmpty {
                let surface = Array(entry.surface)
                guard j + surface.count <= o.count,
                      o[j..<(j + surface.count)].elementsEqual(surface) else { continue }
                for reading in entry.readings + [entry.surface] where !reading.isEmpty {
                    let length = reading.count
                    guard i + length <= s.count,
                          kana(String(s[i..<(i + length)])).lowercased() == kana(reading).lowercased() else { continue }
                    // A Latin spelling matched case-insensitively must be a whole word ("GitHub" is not "Git").
                    if reading == entry.surface {
                        let asciiLetter: (Character?) -> Bool = { $0.map { $0.isASCII && $0.isLetter } ?? false }
                        if asciiLetter(i > 0 ? s[i - 1] : nil) || asciiLetter(i + length < s.count ? s[i + length] : nil)
                            || asciiLetter(j + surface.count < o.count ? o[j + surface.count] : nil) { continue }
                    }
                    var next = j + surface.count
                    // A separator is licensed only when it actually occurs in O.
                    while next < o.count && decoration(o[next]) && !o[next].isNewline && !terminal(o[next]) { next += 1 }
                    if consume(i + length, next) { return true }
                }
            }
            failed.insert(key)
            return false
        }
        return !source.isEmpty && consume(0, 0)
    }

    private static func endsOpen(_ text: String, language: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "、,"))
        guard let last = t.last, !terminal(last) else { return false }
        if language.hasPrefix("en") { return true }
        // A short phrase without inner punctuation is a word or label, not a sentence (no final mark).
        let closed = ["です", "ます", "ました", "でした", "ません", "ください", "ましょう", "た", "だ", "ない", "か", "よ", "ね"]
        if t.count <= 8, !t.contains(where: { $0.isPunctuation }), !closed.contains(where: t.hasSuffix) { return true }
        // Particles and connective forms that leave the sentence unfinished. Anything else (predicates,
        // requests, nouns) may take the final mark the proposal adds.
        return ["て", "で", "けど", "けれど", "が", "ので", "から", "し", "とか", "を", "に", "は", "と", "や", "も",
                "たら", "れば", "のに", "ても", "でも", "って", "ながら", "より", "など", "の"].contains(where: t.hasSuffix)
    }

    private static func spellingDictionary(_ text: String, _ dictionary: [(surface: String, readings: [String])]) -> String {
        var result = text
        let pairs = dictionary.flatMap { entry in
            entry.readings.filter { !$0.isEmpty }.flatMap { [($0, entry.surface), (katakana($0), entry.surface), (kana($0), entry.surface)] }
        }.filter { !$0.1.isEmpty }.sorted { $0.0.count > $1.0.count }
        for (reading, surface) in pairs { result = result.replacingOccurrences(of: reading, with: surface) }
        return result
    }

    private static func kana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            (0x30A1...0x30F6).contains($0.value) ? Unicode.Scalar($0.value - 0x60)! : $0
        }))
    }
    private static func katakana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            (0x3041...0x3096).contains($0.value) ? Unicode.Scalar($0.value + 0x60)! : $0
        }))
    }
    private static func intersects(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.isEmpty ? b.contains(a.lowerBound) : a.overlaps(b)
    }
    private static func occurrences(_ needle: [Character], in text: [Character]) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= text.count else { return [] }
        return (0...(text.count - needle.count)).compactMap { i in
            text[i..<(i + needle.count)].elementsEqual(needle) ? i..<(i + needle.count) : nil
        }
    }
    private static func repetition(_ range: Range<Int>, in s: [Character], english: Bool) -> Bool {
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi && decoration(s[lo]) { lo += 1 }
        while hi > lo && decoration(s[hi - 1]) { hi -= 1 }
        let word = Array(s[lo..<hi])
        guard !word.isEmpty else { return false }
        // Reduplication is content: 「一つ一つ」「1個1個」「一人一人」.
        if !english, word.count <= 3, word.allSatisfy({ $0.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) } }) { return false }
        if word.count <= 3, word.contains(where: { $0.isNumber || "一二三四五六七八九十百千".contains($0) }) { return false }
        if english {
            guard word.contains(where: \.isLetter), (lo == 0 || !s[lo - 1].isLetter), (hi == s.count || !s[hi].isLetter) else { return false }
        } else {
            guard word.count >= 2, word.contains(where: { $0.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) } }) else { return false }
        }
        var before = lo, after = hi
        while before > 0 && s[before - 1].isWhitespace { before -= 1 }
        while after < s.count && s[after].isWhitespace { after += 1 }
        let left = before >= word.count && s[(before - word.count)..<before].elementsEqual(word)
            && (!english || before == word.count || !s[before - word.count - 1].isLetter)
        let right = after + word.count <= s.count && s[after..<(after + word.count)].elementsEqual(word)
            && (!english || after + word.count == s.count || !s[after + word.count].isLetter)
        return left || right
    }
    /// Fillers that are never content words (unlike あの/その/まあ).
    private static let strongFillersJA = ["えーっと", "えーと", "えっと", "あのー", "あのう", "えー", "あー", "うーん"]

    /// The deletion without its leading/trailing unambiguous fillers, or nil when it has none.
    private static func peelingFillers(_ range: Range<Int>, in s: [Character]) -> Range<Int>? {
        var lo = range.lowerBound, hi = range.upperBound
        var peeled = false
        // Quoted speech keeps its fillers (「えっと、」と言った).
        if lo > 0, "「『\"“'‘".contains(s[lo - 1]) { return nil }
        func skipDecoration() {
            while lo < hi && decoration(s[lo]) { lo += 1 }
            while hi > lo && decoration(s[hi - 1]) { hi -= 1 }
        }
        skipDecoration()
        var changed = true
        while changed {
            changed = false
            for f in strongFillersJA {
                let n = f.count
                if hi - lo >= n, s[lo..<(lo + n)].elementsEqual(f) { lo += n; peeled = true; changed = true; skipDecoration() }
                if hi - lo >= n, s[(hi - n)..<hi].elementsEqual(f) { hi -= n; peeled = true; changed = true; skipDecoration() }
            }
        }
        return peeled ? lo..<hi : nil
    }


    /// Equivalent positions of a deleted span within the same run of text.
    private static func slides(_ range: Range<Int>, in s: [Character]) -> [Range<Int>] {
        var result = [range]
        var a = range.lowerBound, b = range.upperBound
        while a > 0 && s[a - 1] == s[b - 1] { a -= 1; b -= 1; result.append(a..<b) }
        a = range.lowerBound; b = range.upperBound
        while b < s.count && s[a] == s[b] { a += 1; b += 1; result.append(a..<b) }
        return result
    }

    /// A restart the model removed: a short span (optionally ending in a correction cue) followed by
    /// its replacement, e.g. 「来週の月曜、来週の火曜に」 or 「14枚、いや19枚」. A contrast such as
    /// 「朝じゃなくて夜の方が好き」 shares nothing with what follows and is kept.
    private static func restart(_ range: Range<Int>, in s: [Character], language: String) -> Bool {
        guard !language.hasPrefix("en") else { return false }
        let deleted = Array(s[range])
        guard !deleted.contains(where: { terminal($0) || $0.isNewline }) else { return false }
        var core = deleted.filter { !decoration($0) }
        var cued = false
        for cue in SelfCorrection.cuesJA where core.count > cue.count && core.suffix(cue.count).elementsEqual(cue) {
            core.removeLast(cue.count); cued = true; break
        }
        guard (1...15).contains(core.count) else { return false }
        // An apology is not a correction (「今日は無理ですすみません明日は行けます」).
        if cued, ["すみません", "すいません", "ごめん", "ごめんなさい", "失礼しました", "間違えました"].contains(where: { String(deleted).contains($0) }) { return false }
        // The replacement: the next characters after the deletion (punctuation, fillers skipped).
        var next: [Character] = []
        var j = range.upperBound
        while j < s.count && next.count < core.count {
            if !decoration(s[j]) { next.append(s[j]) }
            j += 1
        }
        guard next.count == core.count, next != core else { return false }
        let prefix = zip(core, next).prefix(while: { $0 == $1 }).count
        let suffix = zip(core.reversed(), next.reversed()).prefix(while: { $0 == $1 }).count
        if cued { return prefix >= 1 || suffix >= 1 }
        // Without a cue only a restart of the same phrase head (「来週の月曜、来週の火曜」), not an
        // enumeration (「A社の見積もり、A社の請求書」).
        return core.count >= 2 && prefix >= 2 && prefix * 5 >= core.count * 3
    }

    private static func englishLike(_ range: Range<Int>, in s: [Character], language: String) -> Bool {
        guard language.hasPrefix("en"), String(s[range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() == "like" else { return false }
        let left = s[..<range.lowerBound].last(where: { !$0.isWhitespace })
        let right = s[range.upperBound...].first(where: { !$0.isWhitespace })
        return left == "," && right == ","
    }
    private static func normalize(_ text: String) -> String {
        var result: [Character] = []
        var lineStart = true
        for c in text {
            if c.isNewline { result.append(c); lineStart = true; continue }
            if lineStart && "、。，．,".contains(c) { continue }
            if "、。，．！？".contains(c) {
                while result.last == " " || result.last == "　" || result.last == "\t" { result.removeLast() }
            }
            if c == "。", result.last == "、" { result.removeLast() }
            if (c == "、" || c == "。"), result.last == c { continue }
            result.append(c)
            if !c.isWhitespace { lineStart = false }
        }
        return String(result)
    }

    private static func hunks(_ s: [Character], _ o: [Character]) -> [Hunk] {
        var edits: [Hunk] = [], si = 0, oi = 0
        for (a, b) in matches(s, o) + [(s.count, o.count)] {
            if si != a || oi != b { edits.append(Hunk(source: si..<a, output: oi..<b)) }
            si = a + 1; oi = b + 1
        }
        return edits
    }

    /// Hirschberg LCS: quadratic time, linear scratch memory; indices are Characters.
    private static func matches(_ ac: [Character], _ bc: [Character]) -> [(Int, Int)] {
        // Compare integer ids: Character equality (grapheme normalization) dominates the quadratic loop.
        var ids: [Character: Int] = [:]
        func id(_ c: Character) -> Int {
            if let v = ids[c] { return v }
            let v = ids.count; ids[c] = v; return v
        }
        let a = ac.map(id), b = bc.map(id)
        func row(_ ar: Range<Int>, _ br: Range<Int>, reverse: Bool) -> [Int] {
            var previous = [Int](repeating: 0, count: br.count + 1)
            for i in (reverse ? Array(ar.reversed()) : Array(ar)) {
                var current = [Int](repeating: 0, count: br.count + 1)
                for j in 0..<br.count {
                    let k = reverse ? br.upperBound - j - 1 : br.lowerBound + j
                    current[j + 1] = a[i] == b[k] ? previous[j] + 1 : max(previous[j + 1], current[j])
                }
                previous = current
            }
            return previous
        }
        func split(_ ar: Range<Int>, _ br: Range<Int>) -> [(Int, Int)] {
            guard !ar.isEmpty, !br.isEmpty else { return [] }
            if ar.count == 1 {
                return br.first(where: { b[$0] == a[ar.lowerBound] }).map { [(ar.lowerBound, $0)] } ?? []
            }
            let mid = ar.lowerBound + ar.count / 2
            let cut: Int = {
                let left = row(ar.lowerBound..<mid, br, reverse: false)
                let right = row(mid..<ar.upperBound, br, reverse: true)
                return (0...br.count).max(by: { left[$0] + right[br.count - $0] < left[$1] + right[br.count - $1] })!
            }()
            return split(ar.lowerBound..<mid, br.lowerBound..<(br.lowerBound + cut))
                + split(mid..<ar.upperBound, (br.lowerBound + cut)..<br.upperBound)
        }
        // Common prefix and suffix are matched directly; only the differing middle needs the LCS.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let head = (0..<prefix).map { ($0, $0) }
        let tail = (0..<suffix).reversed().map { (a.count - 1 - $0, b.count - 1 - $0) }
        return head + split(prefix..<(a.count - suffix), prefix..<(b.count - suffix)) + tail
    }
}
