import Foundation
import CoreFoundation

/// Cleanup-only fidelity rules added after the P1 evaluation (§4 of the evaluation report):
///
/// - Self-corrections: a spoken correction ("ビルの三階、いや四階" / "five copies, no wait, three copies") whose
///   retracted segment is still in the output.
/// - Request endings: a dictated request or question ("…を調べてください", "…ますか", "?", "please") whose
///   verb/ending the output dropped.
///
/// Both detectors are deliberately narrow so that faithful cleanups pass: a cue only counts when it follows a
/// pause (punctuation) — "延期ではなく中止" or "I'm sorry" are not corrections — and a retracted segment is
/// only derived when the text before and after the cue have the same shape (noun ↔ noun, shared word).
/// Pure; never logs.
enum CleanupFidelity {
    struct Correction: Equatable {
        /// What the speaker took back ("三階", "five copies").
        var retracted: String
        /// What replaced it, when known ("四階"); removed before searching so "10時" is not found in "10時半".
        var replacement: String?
        var isEnglish: Bool
    }

    // MARK: - Self-corrections

    /// Comparison-only normalization: never used as delivered text. Keep sentence boundaries and
    /// meaningful hedges; a repeated span must equal its immediately adjacent retained copy.
    static func removingDisfluencies(_ source: String) -> String {
        let text = removingEnglishFillers(source)
        let chars = Array(text)
        var removed = Set<Int>()
        for filler in fillers(in: text) {
            let pattern = Array(filler)
            guard !pattern.isEmpty, pattern.count <= chars.count else { continue }
            for i in 0...(chars.count - pattern.count) where chars[i..<(i + pattern.count)].elementsEqual(pattern) {
                let end = i + pattern.count
                if fillers(in: String(chars[max(0, i - 1)..<min(chars.count, end + 1)])).contains(filler) {
                    removed.formUnion(i..<end)
                }
            }
        }
        var units: [(text: String, start: Int, end: Int)] = []
        var i = 0
        while i < chars.count {
            if removed.contains(i) || (chars[i].isWhitespace && !chars[i].isNewline) || ",、，".contains(chars[i]) { i += 1; continue }
            let start = i
            if chars[i].isASCII && chars[i].isLetter {
                while i < chars.count, chars[i].isASCII, chars[i].isLetter { i += 1 }
            } else { i += 1 }
            units.append((String(chars[start..<i]).lowercased(), start, i))
        }
        var start = 0
        while start < units.count {
            var restart: Int?
            // Fixed windows avoid all-pairs searches in long dictations.
            for second in (start + 1)..<min(units.count, start + 49) where units[start].text == units[second].text {
                let distance = second - start
                for gap in 0...min(2, distance - 1) {
                    let length = distance - gap
                    guard second + length <= units.count else { continue }
                    let phrase = units[start..<(start + length)]
                    guard phrase.allSatisfy({ $0.text.allSatisfy(\.isLetter) }),
                          phrase.map(\.text).elementsEqual(units[second..<(second + length)].map(\.text)) else { continue }
                    let japanese = phrase.contains { !$0.text.allSatisfy(\.isASCII) }
                    if japanese && length < 3 { continue }
                    let tail = units[(start + length)..<second].map(\.text).joined()
                    if !tail.isEmpty {
                        // An ambiguous filler is safe only between identical copies. A kana stutter
                        // must repeat the start of the following word's pronunciation.
                        let following = String(chars[units[second].start..<min(chars.count, units[second].start + 12)])
                        let word = ContentWords.readingTokens(following).first?.surface ?? ""
                        let stutter = tail.count <= 2 && tail.allSatisfy(isHiragana)
                            && PhoneticReading.key(of: tail).map { key in
                                PhoneticReading.key(of: word)?.key.hasPrefix(key.key) == true
                            } == true
                        guard tail == "あの" || stutter else { continue }
                    }
                    removed.formUnion(units[start].start..<units[second].start)
                    restart = second
                    break
                }
                if restart != nil { break }
            }
            start = restart ?? (start + 1)
        }
        return String(chars.enumerated().filter { !removed.contains($0.offset) }.map(\.element))
    }

    /// Whole English hesitation words; discourse cues need pauses (an unpunctuated final "you know" may be content:
    /// "Tell me what you know"). Never treat "like" or qualifications such as "to be honest" as fillers.
    static func removingEnglishFillers(_ source: String, includeDiscourseCues: Bool = true) -> String {
        let hesitations = #"[,\t ]*\b(?:um+|uh+|uhm|erm?|hmm)\b[,\t ]*"#
        let discourse = #"(?:^[\t ]*|(?<=[,、.!?])[\t ]*)\b(?:you know|i mean)\b(?=[\t ]*(?:[,、.!?]|$))[\t ]*"#
        // Remove discourse cues first so an adjacent hesitation cannot consume their opening pause.
        let text = includeDiscourseCues
            ? source.replacingOccurrences(of: "(?i)" + discourse, with: " ", options: .regularExpression)
            : source
        return text.replacingOccurrences(of: "(?i)" + hesitations, with: " ", options: .regularExpression)
    }

    /// Cues that announce a correction. Strong cues are almost always corrections; weak cues ("すみません",
    /// "ではなく", "sorry", "actually") are also used for apologies and contrasts, so they need a noun ↔ noun
    /// shape (JA) or a shared word (EN).
    private static let strongJA = [
        "言い直します", "言い直すと", "訂正します", "訂正", "間違えました", "間違えた", "違いました", "違った", "違う", "ちがう",
        "やっぱり", "やっぱ", "もとい", "いや", "いえ",
    ]
    private static let weakJA = [
        "じゃなくて", "じゃなく", "ではなくて", "ではなく", "でなくて", "でなく", "すみません", "すいません",
        "ごめんなさい", "ごめん", "失礼しました",
    ]
    private static let strongEN = [
        "no wait", "wait no", "scratch that", "i mean", "i meant", "make that", "or rather", "correction", "never mind",
        "forget that", "actually no",
    ]
    /// English cues that take back the whole statement before them ("…at the cafe. Scratch that, …").
    private static let statementRetractionEN: Set<String> = ["scratch that", "never mind", "forget that", "actually no"]
    private static let weakEN = ["actually", "sorry", "rather"]
    /// Cues that take back what was just said, so they may also retract a whole clause ("…行きます、いや、…").
    /// "やっぱり" is not one of them ("やっぱり傘を持ってきてよかった" means "as expected").
    private static let retractionJA: Set<String> = [
        "言い直します", "言い直すと", "訂正します", "訂正", "間違えました", "間違えた", "違いました", "違った", "違う", "ちがう",
        "もとい", "いや", "いえ",
    ]
    /// The stand-alone interjection "あ、" announces a correction only between parallel nouns ("A社宛、あ、B社宛").
    private static let interjectionCue = "あ"

    private static let fillersJA = ["えーと", "えっと", "えー", "あのー", "あの", "あー", "あっ", "あ", "うーん", "えと", "え"]
    private static let fillersEN: Set<String> = ["um", "uh", "oh", "er", "erm", "hmm", "uhm", "ah", "well"]
    private static let delimiters: Set<Character> = ["、", "。", "，", "．", ",", ".", "!", "?", "！", "？", ";", "；", ":", "：", "\n", "—", "–"]
    private static let particles: Set<Character> = ["の", "に", "で", "が", "を", "は", "と", "へ", "も"]
    private static let longParticles = ["から", "まで", "より"]
    private static let honorifics = ["さん", "さま", "様", "くん", "ちゃん", "氏", "殿"]
    /// What may follow a corrected noun ("四階の", "田中さんに", "来月5日です").
    private static let strictFollowers: Set<Character> = ["の", "に", "で", "が", "を", "は", "と", "へ", "も", "か", "ま", "よ", "や", "だ"]
    /// Strong cues also accept a suru-verb ("3部印刷して").
    private static let suruFollowers: Set<Character> = ["し", "す", "さ"]
    private static let englishStopWords: Set<String> = [
        "the", "a", "an", "to", "of", "in", "on", "at", "for", "and", "or", "it", "is", "be", "i", "we", "you", "that", "this", "please",
    ]

    /// Corrections spoken in `source`, in order.
    static func corrections(in source: String) -> [Correction] {
        scan(source).map(\.correction)
    }

    /// Content words that only belong to retracted segments and their cue words ("Mark", "mean" in "to Mark,
    /// I mean, Julia"). A faithful cleanup drops them, so they do not count against content retention.
    static func retentionExclusions(source: String, spans: [SelfCorrectionSpan] = []) -> Set<String> {
        var excluded = Set<String>()
        for found in scan(source) {
            let dropped = ContentWords.extract(from: found.correction.retracted).union(ContentWords.extract(from: found.cue))
            excluded.formUnion(dropped.subtracting(ContentWords.extract(from: found.following)))
        }
        // Stage-A spans: their words, unless the replacement says them again.
        for span in spans {
            excluded.formUnion(ContentWords.extract(from: span.retracted).subtracting(ContentWords.extract(from: span.replacement ?? "")))
        }
        return excluded
    }

    /// `source` (NFKC) with every retracted segment replaced by a pause, so retracted speech cannot license
    /// output words. Conservative: besides the cue rules and stage-A spans, the whole clause before any
    /// correction cue is dropped. Retracted text is located by a folded key (NFKC, lower case, katakana →
    /// hiragana), so "テンプレート" also removes "てんぷれーと". A replacement that repeats the retracted words
    /// keeps them.
    static func removingRetractions(from source: String, spans: [SelfCorrectionSpan] = []) -> String {
        let normalizedSource = source.precomposedStringWithCompatibilityMapping
        var pairs = scan(normalizedSource).map { ($0.correction.retracted, $0.correction.replacement) }
        pairs += spans.map { ($0.retracted, $0.replacement) }
        let chars = Array(normalizedSource)
        let lower = chars.map { c -> Character in
            let folded = String(c).lowercased()
            return folded.count == 1 ? Character(folded) : c
        }
        var masked = [Bool](repeating: false, count: chars.count)
        var index = 0
        while index < chars.count {
            guard let (cue, _, _) = cue(at: index, chars: chars, lower: lower) else {
                index += 1
                continue
            }
            var end = index
            while end > 0, delimiters.contains(chars[end - 1]) || chars[end - 1].isWhitespace { end -= 1 }
            var start = end
            while start > 0, !delimiters.contains(chars[start - 1]) { start -= 1 }
            for position in start..<end { masked[position] = true }
            index += cue.count
        }
        let folded = chars.map(foldedCharacter)
        func key(_ text: String?) -> [String] {
            Array((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping)
                .map(foldedCharacter)
        }
        func occurrences(of needle: [String]) -> [Range<Int>] {
            guard !needle.isEmpty, needle.count <= folded.count else { return [] }
            return (0...(folded.count - needle.count))
                .filter { folded[$0..<($0 + needle.count)].elementsEqual(needle) }
                .map { $0..<($0 + needle.count) }
        }
        for (retracted, replacement) in pairs {
            let retractedKey = key(retracted)
            let replacementKey = key(replacement)
            // A replacement that repeats the retracted words ("てんぷれーと" → "てんぷれーとふぁいる") keeps them.
            let protected = replacementKey.count > retractedKey.count
                && replacementKey.joined().contains(retractedKey.joined())
                ? occurrences(of: replacementKey) : []
            for range in occurrences(of: retractedKey) where !protected.contains(where: { $0.overlaps(range) }) {
                for position in range { masked[position] = true }
            }
        }
        var text = ""
        for (position, character) in chars.enumerated() {
            if masked[position] {
                if position == 0 || !masked[position - 1] { text.append("、") }
            } else {
                text.append(character)
            }
        }
        return text
    }

    /// One character folded for locating retracted text: lower case, katakana → hiragana.
    private static func foldedCharacter(_ character: Character) -> String {
        var result = ""
        for scalar in String(character).lowercased().unicodeScalars {
            if (0x30A1...0x30F6).contains(scalar.value), let hiragana = Unicode.Scalar(scalar.value - 0x60) {
                result.unicodeScalars.append(hiragana)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Stage-A spans (located in the original transcript): the output still contains a retracted span at
    /// least as often as the transcript does, after masking the replacement ("9時" inside "9時半").
    static func keepsRetractedSpan(_ spans: [SelfCorrectionSpan], source: String, output: String) -> Bool {
        for span in spans {
            let retracted = span.retracted.trimmingCharacters(in: .whitespacesAndNewlines)
            if retracted.allSatisfy({ $0.isASCII }) {
                let key = wordKey(retracted)
                guard key.count >= 5 else { continue }  // " ab " — at least two letters
                let replacement = span.replacement.map(wordKey)
                let inOutput = count(key, in: masking(replacement, in: wordKey(output)))
                let inSource = count(key, in: masking(replacement, in: wordKey(source)))
                if inOutput > 0, inOutput >= inSource { return true }
            } else {
                let key = retractionKey(retracted)
                guard key.count >= 2 else { continue }
                let replacement = span.replacement.map(retractionKey)
                let inOutput = countJapanese(key, in: masking(replacement, in: retractionKey(output)))
                let inSource = countJapanese(key, in: masking(replacement, in: retractionKey(source)))
                if inOutput > 0, inOutput >= inSource { return true }
            }
        }
        return false
    }

    /// Locate only certified retractions before their cue. English comparisons use whole normalized
    /// words so punctuation/contractions do not prevent a match, and replacement occurrences stay intact.
    static func retentionSource(_ source: String, spans: [SelfCorrectionSpan] = []) -> String {
        let chars = Array(source.precomposedStringWithCompatibilityMapping)
        let folded = chars.map(foldedCharacter)
        let lower = chars.map { character -> Character in
            let value = String(character).lowercased()
            return value.count == 1 ? Character(value) : character
        }
        var removed = Set<Int>()
        // Corrections retract what was said just before the cue; `window` bounds that search so long
        // transcripts with many cues stay linear.
        func locate(_ text: String, before limit: Int, english: Bool, window: Int? = nil) -> Range<Int>? {
            let floor = window.map { max(0, limit - $0) } ?? 0
            if english {
                let expected = words(text)
                guard !expected.isEmpty else { return nil }
                var tokens: [(key: String, range: Range<Int>)] = []
                var i = floor
                while i > 0, i < limit, chars[i - 1].isLetter || chars[i - 1].isNumber { i += 1 }
                while i < limit {
                    guard chars[i].isLetter || chars[i].isNumber else { i += 1; continue }
                    let start = i
                    while i < limit, chars[i].isLetter || chars[i].isNumber || "'’".contains(chars[i]) { i += 1 }
                    if let key = words(String(chars[start..<i])).first { tokens.append((key, start..<i)) }
                }
                guard tokens.count >= expected.count else { return nil }
                for start in (0...(tokens.count - expected.count)).reversed() {
                    if tokens[start..<(start + expected.count)].map(\.key) == expected {
                        return tokens[start].range.lowerBound..<tokens[start + expected.count - 1].range.upperBound
                    }
                }
                return nil
            }
            let key = Array(text.precomposedStringWithCompatibilityMapping).map(foldedCharacter)
            guard !key.isEmpty, key.count <= limit - floor else { return nil }
            return (floor...(limit - key.count)).reversed().first {
                folded[$0..<($0 + key.count)].elementsEqual(key)
            }.map { $0..<($0 + key.count) }
        }
        for found in scan(String(chars)) {
            if let range = locate(found.correction.retracted, before: found.cueIndex, english: found.correction.isEnglish,
                                  window: 400) {
                removed.formUnion(range)
                removed.formUnion(found.cueIndex..<(found.cueIndex + found.cue.count))
            }
        }
        for span in spans {
            let replacement = span.replacement.flatMap { locate($0, before: chars.count, english: false) }
            let limit = replacement?.lowerBound ?? chars.count
            if let range = locate(span.retracted, before: limit, english: false) {
                removed.formUnion(range)
                for i in range.upperBound..<limit {
                    if let (cue, _, _) = cue(at: i, chars: chars, lower: lower), i + cue.count <= limit {
                        removed.formUnion(i..<(i + cue.count))
                    }
                }
            }
        }
        return String(chars.enumerated().map { removed.contains($0.offset) ? Character(" ") : $0.element })
    }

    /// Detect a substantial deletion between otherwise aligned words; replacements remain governed by
    /// overlap/number/polarity checks. Keep kana particles and conditions in this ordered comparison.
    /// `source` is the transcript with certified retractions already blanked (defaults to `retentionSource`).
    /// The alignment is greedy and anchored (bigram-confirmed resync, bounded probes), so it stays near-linear
    /// on long dictations instead of the quadratic worst case of a full edit-distance diff.
    static func dropsContiguousSpan(input: ValidationInput, source preparedSource: String? = nil) -> Bool {
        func tokens(_ text: String) -> [(surface: String, reading: String)] {
            let text = normalizingQualifierSpellings(removingDisfluencies(text))
                .precomposedStringWithCompatibilityMapping.lowercased()
            return ContentWords.readingTokens(text).filter { $0.surface.contains(where: { $0.isLetter || $0.isNumber }) }
        }
        var source = preparedSource ?? retentionSource(input.source, spans: input.selfCorrections ?? [])
        for hint in input.selectedDictionary {
            for reading in hint.readings.sorted(by: { $0.count > $1.count }) where !reading.isEmpty {
                source = source.replacingOccurrences(of: reading, with: hint.preferred, options: [.caseInsensitive, .widthInsensitive])
            }
        }
        let original = tokens(source), result = tokens(input.output)
        var ids: [String: Int] = [:]
        func intern(_ reading: String) -> Int {
            if let id = ids[reading] { return id }
            ids[reading] = ids.count
            return ids.count - 1
        }
        let a = original.map { intern($0.reading) }, b = result.map { intern($0.reading) }
        var positionsA: [Int: [Int]] = [:], positionsB: [Int: [Int]] = [:]
        for (k, id) in a.enumerated() { positionsA[id, default: []].append(k) }
        for (k, id) in b.enumerated() { positionsB[id, default: []].append(k) }
        /// A resync point: equal tokens whose successors are also equal (or one side ends).
        func anchored(_ i: Int, _ j: Int) -> Bool {
            a[i] == b[j] && (i + 1 == a.count || j + 1 == b.count || a[i + 1] == b[j + 1])
        }
        /// First anchored occurrence after `from` in a sorted position list (bounded number of probes).
        func nextAnchor(_ positions: [Int]?, after from: Int, _ check: (Int) -> Bool) -> Int? {
            guard let positions else { return nil }
            var low = 0, high = positions.count
            while low < high {
                let mid = (low + high) / 2
                if positions[mid] <= from { low = mid + 1 } else { high = mid }
            }
            for k in low..<min(positions.count, low + 16) where check(positions[k]) { return positions[k] }
            return nil
        }
        // A local rewrite is not a deletion-only cleanup; avoid treating spelling/grammar edits as drops.
        // Deleted source tokens, and source positions where output tokens were inserted.
        var deleted = [Bool](repeating: false, count: a.count)
        var inserted = Set<Int>()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            let deletion = nextAnchor(positionsA[b[j]], after: i) { anchored($0, j) }.map { $0 - i }
            let insertion = nextAnchor(positionsB[a[i]], after: j) { anchored(i, $0) }.map { $0 - j }
            var rewrite: (Int, Int)?
            search: for total in 2...16 {
                for di in max(1, total - 8)...min(8, total - 1) where i + di < a.count && j + total - di < b.count {
                    if anchored(i + di, j + total - di) { rewrite = (di, total - di); break search }
                }
            }
            // Prefer the resync whose agreement lasts longest relative to its cost (bounded look-ahead),
            // so a repeated tail ("…にします。…来週中にします") resyncs where the edit is smallest.
            func score(_ di: Int, _ dj: Int) -> Int {
                var run = 0
                while run < 32, i + di + run < a.count, j + dj + run < b.count, a[i + di + run] == b[j + dj + run] { run += 1 }
                return run - di - dj
            }
            let options: [(kind: Int, score: Int, cost: Int)] = [
                deletion.map { (0, score($0, 0), $0) },
                insertion.map { (1, score(0, $0), $0) },
                rewrite.map { (2, score($0.0, $0.1), $0.0 + $0.1) },
            ].compactMap { $0 }
            let best = options.max { ($0.score, -$0.cost) < ($1.score, -$1.cost) }
            if best == nil {
                // No resync nearby: a one-for-one rewrite.
                deleted[i] = true
                inserted.insert(i)
                i += 1; j += 1
            } else if best?.kind == 0, let deletion {
                for k in i..<(i + deletion) { deleted[k] = true }
                i += deletion
            } else if best?.kind == 1, let insertion {
                inserted.insert(i)
                j += insertion
            } else if let (di, dj) = rewrite {
                for k in i..<(i + di) { deleted[k] = true }
                inserted.insert(i)
                i += di; j += dj
            }
        }
        while i < a.count { deleted[i] = true; i += 1 }
        if j < b.count { inserted.insert(a.count) }
        var index = 0
        while index < original.count {
            guard deleted[index] else { index += 1; continue }
            let start = index
            var count = 0
            while index < original.count, deleted[index] {
                count += original[index].surface.count
                index += 1
            }
            if count >= 6, !(max(0, start - 1)...index).contains(where: { inserted.contains($0) }) { return true }
        }
        return false
    }

    /// Short qualifications carry meaning even below the contiguous-deletion threshold. Match English
    /// whole words and a small explicit Japanese list; spelling/politeness variants share one key.
    private static let qualifierVariants: [[String]] = [
        ["たぶん", "多分"], ["おそらく", "恐らく"], ["かもしれない", "かもしれません"],
        ["もし"], ["なら"], ["できれば"], ["なるべく", "成るべく"], ["だけ"], ["のみ"], ["しか"],
        ["少なくとも"], ["最低"], ["必ず"], ["絶対"], ["ぜひ", "是非"], ["念のため"],
        ["一応"], ["特に"], ["ほぼ"], ["約", "およそ"], ["以上"], ["以下"], ["未満"],
        ["以内"], ["まで"], ["までに"],
    ]

    private static let qualifierAliases = ["多分": "たぶん", "恐らく": "おそらく", "かもしれません": "かもしれない",
                                           "成るべく": "なるべく", "是非": "ぜひ", "およそ": "約"]
    private static let qualifierAliasRegex = try? NSRegularExpression(pattern:
        qualifierAliases.keys.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|"))

    /// Comparison-only aliases, restricted to whole contextual word spans.
    static func normalizingQualifierSpellings(_ text: String) -> String {
        guard let regex = qualifierAliasRegex else { return text }
        let string = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: string.length))
        guard !matches.isEmpty,
              let tokenizer = CFStringTokenizerCreate(nil, text as CFString,
                  CFRangeMake(0, string.length), kCFStringTokenizerUnitWord,
                  Locale(identifier: "ja") as CFLocale) else { return text }
        var starts = Set<Int>(), ends = Set<Int>()
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            starts.insert(range.location)
            ends.insert(range.location + range.length)
        }
        var result = ""
        var cursor = 0
        for match in matches where starts.contains(match.range.location) && ends.contains(NSMaxRange(match.range)) {
            if let canonical = qualifierAliases[string.substring(with: match.range)] {
                result += string.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result += canonical
                cursor = NSMaxRange(match.range)
            }
        }
        result += string.substring(from: cursor)
        return result
    }

    static func dropsQualifier(source: String, output: String) -> Bool {
        func counts(_ text: String) -> [String: Int] {
            var text = removingDisfluencies(text).precomposedStringWithCompatibilityMapping.lowercased()
            // These are obligations, farewells or conjunctions, not a conditional なら.
            for nonCondition in ["ならなかった", "ならない", "ならぬ", "ならず", "さようなら", "さよなら", "ならびに"] {
                text = text.replacingOccurrences(of: nonCondition, with: " ")
            }
            var result: [String: Int] = [:]
            let tokens = ContentWords.readingTokens(text).map(\.surface)
            for (key, group) in qualifierVariants.enumerated() {
                // Multi-kanji qualifiers (一応, 絶対 …) merge with a following kanji word in the reading tokens
                // (一応明日), so count them as substrings; they do not occur inside unrelated words.
                if group.allSatisfy({ $0.count >= 2 && $0.unicodeScalars.allSatisfy { $0.properties.isIdeographic } }) {
                    result[String(key)] = group.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
                    continue
                }
                // Context can split a particle differently from its standalone spelling (の + み).
                // Join whole tokens up to the longest variant; never match inside a longer word.
                let maximumLength = group.map(\.count).max() ?? 0
                result[String(key)] = tokens.indices.filter { start in
                    var phrase = ""
                    for token in tokens[start...] {
                        phrase += token
                        if group.contains(phrase) { return true }
                        if phrase.count >= maximumLength { break }
                    }
                    return false
                }.count
            }
            // Unpunctuated discourse phrases can be relative clauses or ordinary predicates.
            for phrase in ["you know", "i mean"] {
                result[phrase] = (try? NSRegularExpression(pattern: "\\b" + phrase + "\\b"))?
                    .numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
            }
            let english: Set<String> = ["maybe", "probably", "perhaps", "might", "if", "unless", "only"]
            for word in text.components(separatedBy: CharacterSet.letters.inverted) where english.contains(word) {
                result[word, default: 0] += 1
            }
            return result
        }
        let required = counts(source), available = counts(output)
        return required.contains { $0.value > available[$0.key, default: 0] }
    }

    // MARK: - Residual fillers (hands-free)

    /// Japanese fillers that are fillers wherever they appear (hiragana only: "エージェント" is not "えー").
    private static let strongFillersJA = ["えーっと", "えーと", "えっと", "あのー", "あのう"]
    /// Short Japanese fillers that need a pause (or the start) on at least one side ("えー、"). Expressive
    /// interjections ("うーん", "あー") are content and are not listed.
    private static let shortFillersJA = ["えー"]
    /// Japanese words that are fillers only when a pause follows ("あの、" but not "あの人", "あの件").
    private static let pausedFillersJA = ["あの", "その", "まあ", "なんか"]
    private static let residualFillersEN: Set<String> = ["um", "umm", "uh", "uhm", "erm", "er", "hmm"]

    /// The output keeps a filler that the transcript used as a filler. Legitimate words that merely
    /// contain a filler ("あの人", "その件", "umbrella") do not count.
    static func keepsFiller(source: String, output: String) -> Bool {
        let sourceFillers = fillers(in: source)
        guard !sourceFillers.isEmpty else { return false }
        return !sourceFillers.isDisjoint(with: fillers(in: output))
    }

    /// Fillers used as fillers in `text` (Japanese folded to hiragana, English lower case).
    static func fillers(in text: String) -> Set<String> {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let chars = Array(folded)
        var found = Set<String>()
        var index = 0
        while index < chars.count {
            var advanced = false
            for filler in strongFillersJA where matchesAt(filler, index, chars) {
                found.insert(filler)
                index += filler.count
                advanced = true
                break
            }
            if advanced { continue }
            for filler in shortFillersJA where matchesAt(filler, index, chars) {
                let end = index + filler.count
                let pauseBefore = index == 0 || delimiters.contains(chars[index - 1]) || chars[index - 1].isWhitespace
                let pauseAfter = end == chars.count || delimiters.contains(chars[end]) || chars[end].isWhitespace
                let insideWord = end < chars.count && (isHiragana(chars[end]) || chars[end] == "ー") && !pauseBefore
                if (pauseBefore || pauseAfter), !insideWord {
                    found.insert(filler)
                    index = end
                    advanced = true
                    break
                }
            }
            if advanced { continue }
            for filler in pausedFillersJA where matchesAt(filler, index, chars) {
                let end = index + filler.count
                let before = index == 0 ? nil : chars[index - 1]
                let startsClause = before.map { delimiters.contains($0) || $0.isWhitespace || !isHiragana($0) && !isNounCharacter($0) } ?? true
                let pauseAfter = end < chars.count && (delimiters.contains(chars[end]) || chars[end] == " ")
                if startsClause, pauseAfter {
                    found.insert(filler)
                    index = end
                    advanced = true
                    break
                }
            }
            if !advanced { index += 1 }
        }
        for word in folded.components(separatedBy: CharacterSet.letters.inverted) where residualFillersEN.contains(word) {
            found.insert(word)
        }
        return found
    }

    private static func matchesAt(_ word: String, _ index: Int, _ chars: [Character]) -> Bool {
        let w = Array(word)
        guard index + w.count <= chars.count else { return false }
        return Array(chars[index..<(index + w.count)]) == w
    }

    private struct Found {
        var correction: Correction
        var cue: String
        /// The clause after the cue.
        var following: String
        /// Position of the cue in the scanned text.
        var cueIndex: Int
    }

    private static func scan(_ source: String) -> [Found] {
        let chars = Array(source)
        let lower = chars.map { c -> Character in
            let folded = String(c).lowercased()
            return folded.count == 1 ? Character(folded) : c
        }
        var result: [Found] = []
        var index = 0
        while index < chars.count {
            if let (cue, strong, english) = cue(at: index, chars: chars, lower: lower) {
                // Corrections are local: bounded context keeps scanning long transcripts with many cues linear.
                let before = Array(chars[max(0, index - 400)..<index])
                let after = Array(chars[(index + cue.count)..<min(chars.count, index + cue.count + 400)])
                let found = english
                    ? englishCorrection(before: before, after: after, strong: strong, cue: cue)
                    : japaneseCorrection(before: before, after: after, strong: strong, cue: cue)
                if let found, !result.contains(where: { $0.correction == found }) {
                    result.append(Found(correction: found, cue: cue, following: String(clauseAfter(after)), cueIndex: index))
                }
                index += cue.count
            } else {
                index += 1
            }
        }
        return result
    }

    /// The output still contains a segment the speaker retracted.
    static func keepsRetractedSegment(source: String, output: String) -> Bool {
        for correction in corrections(in: source) {
            if correction.isEnglish {
                let retracted = wordKey(correction.retracted)
                guard retracted.count >= 3 else { continue }
                let replacement = correction.replacement.map(wordKey)
                let inOutput = count(retracted, in: masking(replacement, in: wordKey(output)))
                let inSource = count(retracted, in: masking(replacement, in: wordKey(source)))
                if inOutput > 0, inOutput >= inSource { return true }
            } else {
                let retracted = retractionKey(correction.retracted)
                guard retracted.count >= 2 else { continue }
                let replacement = correction.replacement.map(retractionKey)
                let inOutput = countJapanese(retracted, in: masking(replacement, in: retractionKey(output)))
                let inSource = countJapanese(retracted, in: masking(replacement, in: retractionKey(source)))
                if inOutput > 0, inOutput >= inSource { return true }
            }
        }
        return false
    }

    // MARK: Cue detection

    private static func cue(at index: Int, chars: [Character], lower: [Character]) -> (String, Bool, Bool)? {
        // Japanese: preceded by a pause (punctuation, optionally followed by a filler) and not continuing as a
        // hiragana word ("いやです", "間違いない").
        if chars[index] == Character(interjectionCue), index + 1 < chars.count, chars[index + 1] == "、" || chars[index + 1] == ",",
           pauseBefore(Array(chars[..<index])) {
            return (interjectionCue, false, false)
        }
        for (list, strong) in [(strongJA, true), (weakJA, false)] {
            for cue in list where matches(cue, at: index, in: chars) {
                let end = index + cue.count
                if end < chars.count, isHiragana(chars[end]) { continue }
                guard pauseBefore(Array(chars[..<index])) else { continue }
                return (cue, strong, false)
            }
        }
        // English: word-bounded; weak cues need punctuation before them ("I'm sorry" is not a correction).
        if index == 0 || !lower[index - 1].isLetter {
            for (list, strong) in [(strongEN, true), (weakEN, false)] {
                for cue in list where matches(cue, at: index, in: lower) {
                    let end = index + cue.count
                    if end < lower.count, lower[end].isLetter || lower[end] == "'" { continue }
                    if !strong, !pauseBefore(Array(chars[..<index])) { continue }
                    // "forget that the deadline…", "never mind a house": a statement cue stands between pauses.
                    if statementRetractionEN.contains(cue) {
                        guard index == 0 || pauseBefore(Array(chars[..<index])),
                              end == chars.count || delimiters.contains(chars[end]) else { continue }
                    }
                    return (cue, strong, true)
                }
            }
        }
        return nil
    }

    private static func matches(_ cue: String, at index: Int, in chars: [Character]) -> Bool {
        let cueChars = Array(cue)
        guard index + cueChars.count <= chars.count else { return false }
        return Array(chars[index..<(index + cueChars.count)]) == cueChars
    }

    /// The text before a cue ends with punctuation (stand-alone fillers in between are skipped).
    private static func pauseBefore(_ before: [Character]) -> Bool {
        var text = before
        while true {
            while let last = text.last, last.isWhitespace { text.removeLast() }
            guard let last = text.last else { return false }
            if delimiters.contains(last) { return true }
            guard let rest = droppingTrailingFiller(text) else { return false }
            text = rest
        }
    }

    /// `text` without a trailing stand-alone filler ("…、あ", "…, um"), or nil when it does not end with one.
    private static func droppingTrailingFiller(_ text: [Character]) -> [Character]? {
        let lower = String(text).lowercased()
        for filler in fillersJA + fillersEN.sorted() where lower.hasSuffix(filler) {
            let rest = Array(text.dropLast(filler.count))
            guard let previous = rest.last else { return rest }
            if delimiters.contains(previous) || previous.isWhitespace { return rest }
        }
        return nil
    }

    // MARK: Japanese

    private static func japaneseCorrection(before: [Character], after: [Character], strong: Bool, cue: String) -> Correction? {
        let pre = clauseBefore(before)
        let post = clauseAfter(after)
        guard !pre.isEmpty, !post.isEmpty else { return nil }

        // R1: noun ↔ noun ("三階" → "四階の", "山田さん" → "田中さんに", "月末" → "来月5日です"). After "あ、" the
        // two nouns must also look parallel (shared first or last character: "A社宛" → "B社宛", "2番" → "5番").
        // A noun added with も/とか ("田中さん、あ、鈴木さんも") is not a replacement.
        // Two people with honorifics followed by a case particle ("田中さん、あ、鈴木さんに") are a replacement too.
        if let tail = nounTail(pre), let head = nounHead(post, strong: strong), charKey(tail) != charKey(head) {
            let rest = String(post).hasPrefix(head) ? String(post.dropFirst(head.count)) : ""
            // A sentence-initial vocative ("田中さん、あ、鈴木さんが…") is not a replaced person.
            let honorificPair = pre.count > tail.count
                && honorifics.contains(where: { tail.hasSuffix($0) }) && honorifics.contains(where: { head.hasSuffix($0) })
                && ["に", "へ", "を", "が", "は", "で"].contains(where: { rest.hasPrefix($0) })
            if cue != interjectionCue || sharesEdge(tail, head) || honorificPair, !isAddition(rest) {
                return Correction(retracted: tail, replacement: head, isEnglish: false)
            }
        }
        guard strong else { return nil }
        // R2 (strong cues): the corrected phrase shares a content word ("残業なし" → "一時間だけ残業します"), or the
        // same verb comes back with the opposite polarity ("送らないで" → "送ってください", "共有して" → "共有しないで").
        let tail = phraseTail(pre)
        if !tail.isEmpty, tail.count <= 15, !charKey(String(post)).contains(charKey(tail)) {
            let sharesWord = !ContentWords.extract(from: tail).intersection(ContentWords.extract(from: String(post))).isEmpty
            let tailNegations = negationCount(tail), postNegations = negationCount(String(post))
            let flipsVerb = (tail.first.map { isNounCharacter($0) && !$0.isASCII && post.contains($0) } ?? false)
                && (tailNegations > 0) != (postNegations > 0)
                && Set(post.filter { isNounCharacter($0) && $0 != " " }).isSubset(of: Set(pre))
            if sharesWord || flipsVerb { return Correction(retracted: tail, replacement: nil, isEnglish: false) }
        }
        // R3 (strong cues): both clauses end with the same predicate after a noun ("今週中にします。やっぱり
        // 来週中にします" → "今週中" / "来週中"). After "やっぱり" etc. a bare copula is not enough ("優秀です。
        // やっぱり東大卒です" means "as expected").
        if let parallel = parallelPredicate(pre, post, allowCopula: retractionJA.contains(cue)) { return parallel }
        // R4 (retraction cues): a whole statement taken back by another one ("午後は会議に出ます、いや、会議は延期
        // されました"): about the same thing, or cancelling the event.
        // Emphasis or escalation of the same predicate ("高い、いや、高すぎる") is not a retraction.
        if retractionJA.contains(cue), pre.count >= 4, post.count >= 4,
           let a = pre.last, let b = post.last, isHiragana(a), isHiragana(b),
           !charKey(String(post)).contains(charKey(tail.isEmpty ? String(pre) : tail)),
           !escalates(predicate: tail.isEmpty ? String(pre) : tail, post: String(post)) {
            let sharesWord = !ContentWords.extract(from: String(clauseBefore(before, cuttingAt: sentenceDelimiters)))
                .intersection(ContentWords.extract(from: String(post))).isEmpty
            // A request after the cue ("他言はやめてください") is new content, not a cancelled statement.
            let request = String(post).contains("てください") || String(post).contains("でください")
            let cancels = !request && cancelPredicatesJA.contains { String(post).contains($0) }
            if sharesWord || cancels {
                return Correction(retracted: String(pre), replacement: nil, isEnglish: false)
            }
        }
        return nil
    }

    /// "Bも", "Bにも", "Bや", "Bとか": the noun after the cue is added, not substituted.
    private static func isAddition(_ rest: String) -> Bool {
        var text = Substring(rest)
        if let particle = ["から", "まで", "に", "と", "で", "へ"].first(where: { text.hasPrefix($0) }) { text = text.dropFirst(particle.count) }
        return text.hasPrefix("も") || rest.hasPrefix("や") || rest.hasPrefix("とか")
    }

    private static let cancelPredicatesJA = [
        "なくなり", "なくなっ", "中止", "延期", "取りやめ", "取り止め", "キャンセル", "やめにし", "やめます", "やめました", "やめる",
    ]
    private static let degreeWordsJA = ["最高", "一番", "本当に", "ほんとに", "かなり", "とても", "もっと", "さらに", "すごく"]
    private static let copulaEndings: Set<String> = ["です", "だ", "でした", "だった", "である", "でしょう", "だろう"]

    /// The clause after the cue repeats the predicate's stem as a verb/adjective ("高い" → "高すぎる", not "行きます"
    /// → "旅行は") or only intensifies it.
    private static func escalates(predicate: String, post: String) -> Bool {
        guard let stem = predicate.first, isNounCharacter(stem), !stem.isASCII else { return false }
        let p = Array(post)
        let reused = zip(p, p.dropFirst()).contains { $0 == stem && isHiragana($1) && !particles.contains($1) }
        return reused || (post.contains(stem) && degreeWordsJA.contains(where: { post.contains($0) }))
    }

    /// The noun before the first topic/subject particle ("今日は無理" → "今日").
    private static func topicNoun(_ clause: [Character]) -> String? {
        guard let index = clause.indices.dropFirst().first(where: {
            (clause[$0] == "は" || clause[$0] == "が") && isNounCharacter(clause[$0 - 1]) && clause[$0 - 1] != " "
        }) else { return nil }
        return nounTail(Array(clause[..<index]))
    }

    private static func negationCount(_ text: String) -> Int {
        negations(in: maskingNonNegations(Array(foldedForNegation(text)))).count
    }

    private static let sentenceDelimiters: Set<Character> = ["。", "．", "!", "?", "！", "？", "\n"]

    /// The two nouns start or end with the same character, ignoring honorifics and the お/ご prefix.
    private static func sharesEdge(_ a: String, _ b: String) -> Bool {
        func core(_ noun: String) -> String {
            var text = noun
            if let suffix = honorifics.first(where: { text.hasSuffix($0) }) { text.removeLast(suffix.count) }
            if let first = text.first, "おご御".contains(first), text.count >= 2 { text.removeFirst() }
            return charKey(text)
        }
        let x = core(a), y = core(b)
        guard let a0 = x.first, let b0 = y.first, let a1 = x.last, let b1 = y.last else { return false }
        return a0 == b0 || a1 == b1
    }

    /// R3: the longest common ending of both clauses that starts with a particle, preceded by a noun on both sides.
    private static func parallelPredicate(_ pre: [Character], _ post: [Character], allowCopula: Bool) -> Correction? {
        var n = 0
        while n < pre.count, n < post.count, pre[pre.count - 1 - n] == post[post.count - 1 - n] { n += 1 }
        while n > 0, !isHiragana(pre[pre.count - n]) { n -= 1 }
        // The shared ending starts with a particle or copula ("にします", "です"), not inside a verb ("配|ります").
        guard n >= 2, n < pre.count, n < post.count,
              particles.contains(pre[pre.count - n]) || pre[pre.count - n] == "だ",
              allowCopula || !copulaEndings.contains(String(pre.suffix(n))) else { return nil }
        let preStem = Array(pre.dropLast(n))
        let postStem = Array(post.dropLast(n))
        // Different topics ("今日は無理です、いや、明日は大丈夫です") are two statements, not a replaced noun.
        if let a = topicNoun(preStem), let b = topicNoun(postStem), charKey(a) != charKey(b) { return nil }
        guard let a = preStem.last, let b = postStem.last, isNounCharacter(a), a != " ", isNounCharacter(b), b != " ",
              let retracted = nounTail(preStem), let replacement = nounTail(postStem),
              charKey(retracted) != charKey(replacement) else { return nil }
        return Correction(retracted: retracted, replacement: replacement, isEnglish: false)
    }

    /// The clause right before the cue, without trailing punctuation or fillers.
    private static func clauseBefore(_ before: [Character], cuttingAt cuts: Set<Character> = delimiters) -> [Character] {
        var text = before
        while true {
            while let last = text.last, last.isWhitespace || delimiters.contains(last) { text.removeLast() }
            guard let rest = droppingTrailingFiller(text), !rest.isEmpty else { break }
            text = rest
        }
        if let cut = text.lastIndex(where: { cuts.contains($0) }) { text = Array(text[(cut + 1)...]) }
        return Array(String(text).trimmingCharacters(in: .whitespaces))
    }

    /// The clause right after the cue, without leading punctuation, fillers or a repeated cue.
    private static func clauseAfter(_ after: [Character]) -> [Character] {
        var text = after
        var changed = true
        while changed {
            changed = false
            while let first = text.first, first.isWhitespace || delimiters.contains(first) {
                text.removeFirst()
                changed = true
            }
            let string = String(text).lowercased()
            for word in fillersJA + strongJA + fillersEN.sorted() + strongEN where string.hasPrefix(word) {
                let rest = Array(text.dropFirst(word.count))
                if rest.isEmpty || delimiters.contains(rest[0]) || rest[0].isWhitespace {
                    text = rest
                    changed = true
                    break
                }
            }
        }
        if let cut = text.firstIndex(where: { delimiters.contains($0) }) { text = Array(text[..<cut]) }
        return text
    }

    /// Trailing noun of a clause: "ビルの三階" → "三階", "この件は山田さん" → "山田さん", "ミーティングはZoomで" → "Zoom".
    private static func nounTail(_ clause: [Character]) -> String? {
        var text = clause
        if let last = text.last, particles.contains(last), text.count >= 2, !isHiragana(text[text.count - 2]) {
            text.removeLast()
        }
        var honorific = ""
        if let suffix = honorifics.first(where: { String(text).hasSuffix($0) }) {
            honorific = suffix
            text.removeLast(suffix.count)
        }
        var start = text.count
        while start > 0, isNounCharacter(text[start - 1]) { start -= 1 }
        let noun = String(text[start...]).trimmingCharacters(in: .whitespaces)
        guard !noun.isEmpty, noun.count <= 20, noun.contains(where: { !$0.isWhitespace }) else { return nil }
        return noun + honorific
    }

    /// Leading noun of the corrected clause, accepted only when followed by a particle/copula (or the end):
    /// "四階の受付" → "四階", "田中さんに" → "田中さん". "明日行けない" is not a noun head.
    private static func nounHead(_ clause: [Character], strong: Bool) -> String? {
        var end = 0
        while end < clause.count, isNounCharacter(clause[end]) { end += 1 }
        var head = String(clause[..<end]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, head.count <= 20 else { return nil }
        let rest = String(clause[end...])
        var next = clause.indices.contains(end) ? clause[end] : nil
        if let suffix = honorifics.first(where: { rest.hasPrefix($0) }) {
            head += suffix
            let after = end + suffix.count
            next = clause.indices.contains(after) ? clause[after] : nil
        }
        guard let next else { return head }
        if strictFollowers.contains(next) || (strong && suruFollowers.contains(next)) { return head }
        return nil
    }

    /// The part of a clause after its last particle ("今日は残業なし" → "残業なし"); the whole clause if short.
    private static func phraseTail(_ clause: [Character]) -> String {
        var index = clause.count - 1
        while index > 0 {
            if particles.contains(clause[index]), !isHiragana(clause[index - 1]) {
                return String(clause[(index + 1)...])
            }
            for particle in longParticles {
                let p = Array(particle)
                if index - p.count + 1 > 0, Array(clause[(index - p.count + 1)...index]) == p,
                   !isHiragana(clause[index - p.count]) {
                    return String(clause[(index + 1)...])
                }
            }
            index -= 1
        }
        return clause.count <= 12 ? String(clause) : ""
    }

    private static func isHiragana(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    /// Kanji, katakana, Latin letters, digits and number punctuation (a noun or quantity, never a particle).
    private static func isNounCharacter(_ c: Character) -> Bool {
        if c == " " { return true }
        if isHiragana(c) || delimiters.contains(c) || c.isWhitespace { return false }
        return c.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005, 0x3007: return true  // kanji, 々, 〇
            case 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true  // katakana, ー
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A: return true
            case 0x25, 0xFF05, 0x2E, 0x2F: return true  // % . /
            default: return false
            }
        }
    }

    // MARK: English

    private static func englishCorrection(before: [Character], after: [Character], strong: Bool, cue: String) -> Correction? {
        var pre = words(String(clauseBefore(before)))
        while let tail = pre.last, fillersEN.contains(tail) { pre.removeLast() }
        let post = Array(words(String(clauseAfter(after))).drop(while: { fillersEN.contains($0) }))
        guard let last = pre.last, !post.isEmpty else { return nil }

        // E1: shared last word ("five copies" → "three copies").
        if let j = post.prefix(3).firstIndex(of: last), j >= 1, pre.count >= j + 1 {
            let retracted = Array(pre.suffix(j + 1))
            let replacement = Array(post[0...j])
            if retracted != replacement {
                return Correction(retracted: retracted.joined(separator: " "), replacement: replacement.joined(separator: " "), isEnglish: true)
            }
        }
        // E2: shared first word ("March third" → "March fifth", "the report" → "the slides").
        let window = pre.suffix(3)
        if let i = window.lastIndex(of: post[0]), pre.count - i >= 2 {
            let retracted = Array(pre[i...])
            let replacement = Array(post.prefix(retracted.count))
            if retracted != replacement {
                return Correction(retracted: retracted.joined(separator: " "), replacement: replacement.joined(separator: " "), isEnglish: true)
            }
        }
        // E3 (strong cues): a short replacement for the last word ("to Ken, I mean, Lisa").
        if strong, post.count <= 3, last.count >= 3 || last.allSatisfy(\.isNumber), !englishStopWords.contains(last),
           !post.contains(last) {
            return Correction(retracted: last, replacement: post.joined(separator: " "), isEnglish: true)
        }
        // Not a replacement: an addition ("today, actually tomorrow too") or a new clause ("first I need to…").
        let additive = post.contains(where: { additiveWordsEN.contains($0) })
            || zip(post, post.dropFirst()).contains { $0 == "as" && $1 == "well" }
        let newClause = post.count >= 2 && clauseStartersEN.contains(post[1])
        // E4 (any cue): the word right after the cue is of the same closed class as the last word before it
        // ("on Friday, actually Monday at noon", "at 5, sorry, 6 tomorrow"). "a second" is not an ordinal.
        if let kind = wordClass(last), kind == wordClass(post[0]), last != post[0], !additive, !newClause,
           !(last == "second" && pre.dropLast().last == "a") {
            return Correction(retracted: last, replacement: post[0], isEnglish: true)
        }
        // E6 (weak cues): a name replaced by a name that ends the clause ("to Ann, actually Ben").
        let originalPre = String(clauseBefore(before)).split(whereSeparator: { !$0.isLetter && $0 != "'" })
        let originalPost = String(clauseAfter(after)).split(whereSeparator: { !$0.isLetter && $0 != "'" })
        if !strong, cue != "sorry", wordClass(last) == nil, pre.count >= 2, (1...2).contains(post.count),
           originalPost.count == post.count, !additive,
           let name = originalPre.last, name != "I", name.first?.isUppercase == true,
           originalPost.allSatisfy({ $0.first?.isUppercase == true && $0 != "I" }), !post.contains(last) {
            return Correction(retracted: last, replacement: post.joined(separator: " "), isEnglish: true)
        }
        // E7 (strong cues): the same verb and object come back with the opposite polarity ("don't send it, no wait,
        // send it", "send it, no wait, don't send it").
        let negationsPre = pre.filter { negationWordsEN.contains($0) }.count
        let negationsPost = post.filter { negationWordsEN.contains($0) }.count
        let preContent = pre.filter { !englishStopWords.contains($0) && !negationWordsEN.contains($0) && $0.count >= 3 }
        if strong, pre.count >= 2, (negationsPre > 0) != (negationsPost > 0), !preContent.isEmpty,
           preContent.allSatisfy({ post.contains($0) }) {
            return Correction(retracted: pre.joined(separator: " "), replacement: nil, isEnglish: true)
        }
        // E5 (statement cues): the whole clause before "scratch that" / "never mind" is taken back.
        if statementRetractionEN.contains(cue) {
            let sentence = words(String(clauseBefore(before, cuttingAt: sentenceDelimiters)))
            if sentence.count >= 3 { return Correction(retracted: sentence.joined(separator: " "), replacement: nil, isEnglish: true) }
        }
        return nil
    }

    private static let additiveWordsEN: Set<String> = ["too", "also", "either"]
    private static let clauseStartersEN: Set<String> = [
        "i", "you", "he", "she", "we", "they", "it", "is", "are", "was", "were", "am", "be", "will", "would", "can",
        "could", "should", "need", "have", "has", "do", "does", "did", "must", "may", "might",
    ]

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "twenty": "20", "thirty": "30",
    ]

    private static let wordClasses: [String: String] = {
        var classes: [String: String] = [:]
        for day in ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"] { classes[day] = "weekday" }
        for month in ["january", "february", "march", "april", "june", "july", "august", "september", "october",
                      "november", "december"] { classes[month] = "month" }
        for day in ["today", "tomorrow", "tonight", "yesterday"] { classes[day] = "day" }
        for time in ["morning", "afternoon", "evening", "noon", "midnight"] { classes[time] = "time" }
        for ordinal in ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"] {
            classes[ordinal] = "ordinal"
        }
        return classes
    }()

    /// Closed word classes whose members replace each other in a correction; numbers form one class.
    private static func wordClass(_ word: String) -> String? {
        if let first = word.first, first.isNumber { return "number" }
        return wordClasses[word]
    }

    private static func words(_ text: String) -> [String] {
        ResultValidator.wordNormalize(text).split(separator: " ").map { numberWords[String($0)] ?? String($0) }
    }

    // MARK: Matching keys

    /// " w1 w2 … " with number words folded to digits.
    private static func wordKey(_ text: String) -> String {
        " " + words(text).joined(separator: " ") + " "
    }

    /// Alphanumerics only, numerals canonical ("三階" → "3階").
    private static func charKey(_ text: String) -> String {
        ResultValidator.normalizeForMatch(NumberExtractor.replacingNumerals(in: text))
    }

    /// `charKey` with katakana folded to hiragana: a retracted "てんぷれーと" is still found as "テンプレート".
    private static func retractionKey(_ text: String) -> String {
        let key = charKey(text)
        return key.applyingTransform(.hiraganaToKatakana, reverse: true) ?? key
    }

    private static func masking(_ replacement: String?, in text: String) -> String {
        guard let replacement, !replacement.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
        let isWords = replacement.hasPrefix(" ")
        return text.replacingOccurrences(of: replacement, with: isWords ? " | " : "|")
    }

    private static func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Occurrences not glued to a longer number ("10時" inside "110時" or followed by "30分"/"半").
    private static func countJapanese(_ needle: String, in haystack: String) -> Int {
        let h = Array(haystack)
        let n = Array(needle)
        guard !n.isEmpty, h.count >= n.count else { return 0 }
        let hasDigit = n.contains(where: \.isNumber)
        var total = 0
        var i = 0
        while i + n.count <= h.count {
            if Array(h[i..<(i + n.count)]) == n {
                let previous = i > 0 ? h[i - 1] : nil
                let next = i + n.count < h.count ? h[i + n.count] : nil
                let glued = (n.first?.isNumber == true && previous?.isNumber == true)
                    || (hasDigit && (next?.isNumber == true || next == "半"))
                if !glued { total += 1 }
                i += n.count
            } else {
                i += 1
            }
        }
        return total
    }

    // MARK: - Negations

    /// The output drops or adds a negation ("振り込まないでください" → "振り込んでください", "don't forward" →
    /// "forward"). Negations are counted, so a neutral paraphrase ("行けない" ↔ "行けません", "do not" ↔ "don't",
    /// "せずに" ↔ "しないで") passes; obligations ("しなきゃ" ↔ "しなければなりません") and words that only look
    /// negative ("かもしれない", "申し訳ありません", "必ず", "少ない") are not counted. A negation may disappear when
    /// the speaker took it back: in a retracted span or detected correction right before its cue, in the clause
    /// before a cue where a correction was detected, in a contrastive cue ("じゃなくて", "no wait", ", no,",
    /// "三時じゃない、"), or in a clause or word the speaker repeated.
    static func changesNegation(source: String, output: String, spans: [SelfCorrectionSpan] = []) -> Bool {
        let folded = Array(foldedForNegation(removingEnglishFillers(source, includeDiscourseCues: false)))
        let masked = maskingNonNegations(folded)
        let found = negations(in: masked)
        let comparisonOutput = removingEnglishFillers(output, includeDiscourseCues: false)
        let produced = negationCount(comparisonOutput)
        guard !found.isEmpty || produced > 0 else { return false }
        let optional = optionalNegationMask(folded, masked: masked, found: found, spans: spans, output: foldedForNegation(output))
        let required = found.filter { range in !range.contains(where: { optional[$0] }) }.count
        if produced < required || produced > found.count { return true }
        guard produced == found.count, produced > 0 else { return false }
        struct Anchor: Hashable {
            var predicate: String
            var subject: String
        }
        func anchors(_ chars: [Character], ranges: [Range<Int>]) -> [Anchor: Int] {
            let found: [Anchor] = ranges.compactMap { range in
                // Bounded windows keep clause-local subject/predicate evidence linear in long dictations.
                let prefix = String(chars[max(0, range.lowerBound - 40)..<range.lowerBound])
                // A pause-delimited cue between subject and negation ("I, you know, don't") is skipped.
                let clause = prefix.components(separatedBy: CharacterSet(charactersIn: "。、,.!?！？\n")).reversed()
                    .first { !["", "you know", "i mean"].contains($0.trimmingCharacters(in: .whitespaces)) } ?? ""
                if chars[range.lowerBound].isASCII {
                    let suffix = String(chars[range.upperBound..<min(chars.count, range.upperBound + 40)])
                    // Skip pause-delimited discourse cues ("don't, you know, send") to reach the real predicate.
                    let following = suffix.trimmingCharacters(in: CharacterSet(charactersIn: " ,、，\t"))
                        .components(separatedBy: CharacterSet(charactersIn: "。、,.!?！？\n"))
                        .first { !["", "you know", "i mean"].contains($0.trimmingCharacters(in: .whitespaces)) } ?? ""
                    guard let predicate = ContentWords.extractInOrder(from: following).first else { return nil }
                    let auxiliaries: Set<String> = ["must", "will", "would", "shall", "should", "can", "could", "may",
                        "might", "do", "does", "did", "am", "is", "are", "was", "were", "be", "have", "has", "had", "please"]
                    let subject = expandingEnglishContractions(clause, beforeNegation: ["not", "never"].contains(String(chars[range])))
                        .components(separatedBy: CharacterSet.letters.inverted)
                        .last { !$0.isEmpty && !auxiliaries.contains($0) } ?? ""
                    return Anchor(predicate: predicate, subject: subject)
                }
                return ContentWords.extractInOrder(from: clause).last.map { Anchor(predicate: $0, subject: "") }
            }
            return found.reduce(into: [Anchor: Int]()) { $0[$1, default: 0] += 1 }
        }
        let outputChars = Array(foldedForNegation(comparisonOutput))
        let outputFound = negations(in: maskingNonNegations(outputChars))
        let requiredRanges = found.filter { range in !range.contains(where: { optional[$0] }) }
        let sourceAnchors = anchors(folded, ranges: requiredRanges)
        // An optional (repeated) negation may legitimately survive, so the reverse direction counts every source negation.
        let sourceAllAnchors = optional.contains(true) ? anchors(folded, ranges: found) : sourceAnchors
        let outputAnchors = anchors(outputChars, ranges: outputFound)
        let outputWords = ContentWords.extract(from: output)
        let sourceWords = ContentWords.extract(from: source)
        return sourceAnchors.contains { outputWords.contains($0.key.predicate) && $0.value > outputAnchors[$0.key, default: 0] }
            || outputAnchors.contains { sourceWords.contains($0.key.predicate) && $0.value > sourceAllAnchors[$0.key, default: 0] }
    }

    /// Anchor-only expansion keeps the original negation/span offsets intact.
    private static func expandingEnglishContractions(_ text: String, beforeNegation: Bool = false) -> String {
        let expansions = ["she's": "she is", "he's": "he is", "it's": "it is", "that's": "that is",
                          "there's": "there is", "i'm": "i am", "you're": "you are", "we're": "we are",
                          "they're": "they are", "i've": "i have", "you've": "you have", "we've": "we have",
                          "they've": "they have", "i'll": "i will", "you'll": "you will", "she'll": "she will",
                          "he'll": "he will", "we'll": "we will", "they'll": "they will", "won't": "will not", "can't": "can not", "shan't": "shall not"]
        var text = text
        if beforeNegation {
            // Only the subject immediately before not/never; possessive noun phrases stay intact.
            text = text.replacingOccurrences(of: #"\b([a-z]+)'s\s*$"#, with: "$1 is ", options: .regularExpression)
        }
        return text.components(separatedBy: .whitespaces).map { word in
            if let expanded = expansions[word] { return expanded }
            if word.hasSuffix("n't") { return String(word.dropLast(3)) + " not" }
            return word
        }.joined(separator: " ")
    }

    /// NFKC, lower case, one apostrophe. Cue detection runs on this text, so it keeps every character.
    private static func foldedForNegation(_ text: String) -> String {
        var unified = text
        for apostrophe in ["’", "ʼ", "´", "‘", "`"] { unified = unified.replacingOccurrences(of: apostrophe, with: "'") }
        return unified.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// Japanese obligations (a double negation) and words that only contain a negative form. Longest first.
    private static let nonNegationsJA: [String] = {
        var words: [String] = []
        for stem in ["なければ", "なくては", "なくちゃ", "なきゃ", "ないと"] {
            for ending in ["ならない", "ならなかった", "なりません", "なりませんでした", "いけない", "いけなかった", "いけません",
                           "いけませんでした", "だめ", "ダメ", "駄目"] {
                words.append(stem + ending)
            }
        }
        words += [
            "なくちゃ", "なきゃ", "ないと", "なければ", "かもしれない", "かもしれません", "かもしれなかった", "かも知れない", "かも知れません",
            "申し訳ありません", "申し訳ございません", "申し訳ない", "申し訳なく", "すみません", "すいません", "済みません",
            "必ず", "かならず", "とりあえず", "取り敢えず", "相変わらず", "あいかわらず", "思わず", "おもわず", "少ない", "少なく",
            "少なかっ", "すくない", "すくなく", "間もなく", "まもなく", "ほどなく",
        ]
        return words.sorted { $0.count > $1.count }
    }()

    private static let clauseFinalNonNegations: Set<String> = ["ないと", "なければ", "なきゃ", "なくちゃ"]

    /// Replaces obligations and look-alike words with a neutral character, keeping every position.
    private static func maskingNonNegations(_ chars: [Character]) -> [Character] {
        var result = chars
        var index = 0
        while index < chars.count {
            var length = 0
            for word in nonNegationsJA where matches(word, at: index, in: chars) {
                let end = index + word.count
                // A bare "ないと" / "なければ" / "なきゃ" / "なくちゃ" is an obligation only at the end of a sentence ("行かないと。"),
                // not a condition ("急がないと、遅れます", "行かないと間に合わない").
                if clauseFinalNonNegations.contains(word) {
                    // A sentence-final particle may follow ("行かないとね。").
                    var next = end
                    for particle in ["よね", "ね", "な", "よ"] where matches(particle, at: next, in: chars) {
                        next += particle.count
                        break
                    }
                    if next < chars.count, !sentenceDelimiters.contains(chars[next]) { continue }
                }
                length = word.count
                break
            }
            if length > 0 {
                for i in index..<(index + length) { result[i] = "◇" }
                index += length
            } else {
                index += 1
            }
        }
        return result
    }

    private static let negationWordsEN: Set<String> = [
        "not", "no", "never", "none", "nobody", "nothing", "neither", "nor", "nowhere", "cannot", "dont", "doesnt", "didnt",
        "cant", "wont", "wouldnt", "shouldnt", "couldnt", "isnt", "arent", "wasnt", "werent", "hasnt", "havent", "hadnt",
        "mustnt", "neednt", "aint", "shant", "mightnt",
    ]
    /// Longest first. Kana forms are checked with their context in `negationLength`.
    private static let negationFormsJA = ["なかっ", "なけれ", "なきゃ", "ません", "ない", "なく", "なし", "無かっ", "無い", "無く", "無し", "禁止", "厳禁", "不可"]
    /// Kana before a negative ず/ぬ (verb stems: 行かず, 忘れず, 起きず, 知らぬ).
    private static let negativeStemKana: Set<Character> = [
        "か", "が", "さ", "た", "な", "ば", "ま", "ら", "わ", "せ", "け", "げ", "べ", "め", "れ", "え", "て", "で", "ね", "へ", "ぜ",
        "き", "ぎ", "じ", "ち", "び", "り", "い",
    ]
    private static let negativeNuStemKana: Set<Character> = ["か", "が", "さ", "た", "な", "ば", "ま", "ら", "わ", "せ"]

    /// Ranges of negations in masked text.
    private static func negations(in chars: [Character]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var index = 0
        while index < chars.count {
            if let length = negationLength(at: index, chars) {
                result.append(index..<(index + length))
                index += length
            } else {
                index += 1
            }
        }
        return result
    }

    private static func isEnglishWordCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c == "'")
    }

    private static func negationLength(at index: Int, _ chars: [Character]) -> Int? {
        let c = chars[index]
        // English: a whole word ("don't", "never"); "no" before a number is an abbreviation ("No. 5").
        if c.isASCII, c.isLetter {
            guard index == 0 || !isEnglishWordCharacter(chars[index - 1]) else { return nil }
            var end = index
            while end < chars.count, isEnglishWordCharacter(chars[end]) { end += 1 }
            let word = String(chars[index..<end]).replacingOccurrences(of: "'", with: "")
            guard negationWordsEN.contains(word) else { return nil }
            if word == "no" {
                var next = end
                while next < chars.count, chars[next] == "." || chars[next].isWhitespace { next += 1 }
                if next < chars.count, chars[next].isNumber { return nil }
            }
            return end - index
        }
        let previous = index > 0 ? chars[index - 1] : nil
        let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
        for form in negationFormsJA where matches(form, at: index, in: chars) {
            if form == "なし", let previous, isHiragana(previous) { continue }  // "問題なし", not "はなし"
            return form.count
        }
        // ず / ぬ after a verb stem, not inside a word ("まず", "わずか", "ずっと", "いぬ").
        if c == "ず" || c == "ぬ" {
            guard let previous, (c == "ず" ? negativeStemKana : negativeNuStemKana).contains(previous), index >= 2 else { return nil }
            let beforeStem = chars[index - 2]
            if delimiters.contains(beforeStem) || beforeStem.isWhitespace { return nil }
            if previous == "ま", c == "ず" { return nil }  // "まず" (first) is far more common than "読まず"
            if let next, isHiragana(next), !(c == "ず" && ["に", "も", "と"].contains(next)) { return nil }
            return 1
        }
        return nil
    }

    /// Contrastive cues that contain a negation ("AじゃなくてB" → "B").
    private static let contrastiveNegationCues = [
        "じゃなくて", "ではなくて", "でなくて", "じゃなく", "ではなく", "でなく", "no wait", "wait no", "never mind", "actually no", "no actually",
    ]
    /// English contrastive cues that only count between pauses ("has actually no budget" is a statement).
    private static let pausedContrastiveCues: Set<String> = ["never mind", "actually no", "no actually"]

    private static let cueWordsEN: Set<String> = Set((strongEN + weakEN).flatMap { $0.split(separator: " ").map(String.init) })

    /// A retracted clause is gone from the output only when every content word of it (Japanese: of its predicate
    /// phrase; English: without stop, negation and cue words) occurs less often in the output than in the source.
    /// A clause still there with its negation flipped ("Do not share…" → "Share…") keeps its negation required.
    private static func isRemoved(_ region: String, source: String, output: String) -> Bool {
        let text = region.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if !text.contains(where: { $0.isLetter && !$0.isASCII }) {
            let keys = words(text).filter {
                !englishStopWords.contains($0) && !negationWordsEN.contains($0) && !cueWordsEN.contains($0)
                    && ($0.count >= 3 || $0.allSatisfy(\.isNumber))
            }
            guard !keys.isEmpty else { return false }
            let inSource = wordKey(source), inOutput = wordKey(output)
            return keys.allSatisfy { count(" \($0) ", in: inOutput) < count(" \($0) ", in: inSource) }
        }
        let tail = phraseTail(Array(text))
        let phrase = tail.isEmpty ? text : tail
        let words = ContentWords.extract(from: phrase)
        if words.isEmpty {
            let key = ResultValidator.normalizeForMatch(phrase)
            guard !key.isEmpty else { return false }
            return count(key, in: ResultValidator.normalizeForMatch(output)) < count(key, in: ResultValidator.normalizeForMatch(source))
        }
        let inSource = ContentWords.normalize(NumberExtractor.replacingNumerals(in: source))
        let inOutput = ContentWords.normalize(NumberExtractor.replacingNumerals(in: output))
        return words.allSatisfy { count($0, in: inOutput) < count($0, in: inSource) }
    }

    /// Source positions whose negation the speaker may have taken back (see `changesNegation`).
    private static func optionalNegationMask(
        _ folded: [Character], masked: [Character], found: [Range<Int>], spans: [SelfCorrectionSpan], output: String
    ) -> [Bool] {
        let chars = folded
        let source = String(folded)
        var mask = Array(repeating: false, count: chars.count)
        func mark(_ range: Range<Int>) {
            for i in range where i >= 0 && i < mask.count { mask[i] = true }
        }
        func occurrences(_ needle: [Character]) -> [Int] {
            guard !needle.isEmpty, needle.count <= chars.count else { return [] }
            return (0...(chars.count - needle.count)).filter { start in
                guard Array(chars[start..<(start + needle.count)]) == needle else { return false }
                // English text matches whole words only ("Ann" is not in "announce").
                if let first = needle.first, isEnglishWordCharacter(first), start > 0, isEnglishWordCharacter(chars[start - 1]) { return false }
                let end = start + needle.count
                if let last = needle.last, isEnglishWordCharacter(last), end < chars.count, isEnglishWordCharacter(chars[end]) { return false }
                return true
            }
        }
        func skippingPause(from index: Int) -> Int {
            var position = index
            while position < chars.count {
                if chars[position].isWhitespace || delimiters.contains(chars[position]) { position += 1; continue }
                if let filler = (fillersJA + fillersEN.sorted()).first(where: { word in
                    let end = position + word.count
                    return matches(word, at: position, in: chars) && (end == chars.count || delimiters.contains(chars[end]) || chars[end].isWhitespace)
                }) {
                    position += filler.count
                    continue
                }
                break
            }
            return position
        }
        // Contrastive cues, unless they continue as "なる" ("無料ではなくなりました" is a statement).
        for cue in contrastiveNegationCues {
            for start in occurrences(Array(cue)) {
                let end = start + cue.count
                if end < chars.count, chars[end] == "な" { continue }
                if pausedContrastiveCues.contains(cue) {
                    var before = start
                    while before > 0, chars[before - 1].isWhitespace { before -= 1 }
                    guard before == 0 || delimiters.contains(chars[before - 1]),
                          end == chars.count || delimiters.contains(chars[end]) else { continue }
                }
                mark(start..<end)
            }
        }
        for range in found {
            let surface = String(chars[range])
            // A delimiter-isolated "no" (", no, three copies", "no, wait") and a clause-final "じゃない、".
            if surface == "no" {
                var before = range.lowerBound
                while before > 0, chars[before - 1].isWhitespace { before -= 1 }
                let after = skippingPause(from: range.upperBound)
                let pausedBefore = before == 0 || delimiters.contains(chars[before - 1])
                let pausedAfter = range.upperBound < chars.count
                    && (delimiters.contains(chars[range.upperBound]) || matches("wait", at: after, in: chars))
                if pausedBefore, pausedAfter { mark(range) }
            }
            if surface == "ない", range.upperBound < chars.count, delimiters.contains(chars[range.upperBound]),
               range.upperBound + 1 < chars.count, range.lowerBound >= 2,
               ["じゃ", "では"].contains(String(chars[(range.lowerBound - 2)..<range.lowerBound])) {
                mark(range)
            }
        }
        // Retracted text right before its cue, up to the pause (a kana tail goes with it: "パスタにしない、いや…").
        let scanned = scan(String(chars))
        let retracted = spans.map(\.retracted) + scanned.filter { !$0.correction.isEnglish }.map(\.correction.retracted)
        for text in retracted {
            let needle = Array(foldedForNegation(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            for start in occurrences(needle) {
                var end = start + needle.count
                while end < chars.count, end - start < needle.count + 12, !delimiters.contains(chars[end]) { end += 1 }
                let next = skippingPause(from: end)
                if next < chars.count, cue(at: next, chars: chars, lower: chars) != nil,
                   isRemoved(String(chars[start..<end]), source: source, output: output) {
                    mark(start..<end)
                }
            }
        }
        // The clause before a cue where a correction was detected.
        for item in scanned {
            var text = Array(chars[..<item.cueIndex])
            while true {
                while let last = text.last, last.isWhitespace || delimiters.contains(last) { text.removeLast() }
                guard let rest = droppingTrailingFiller(text), !rest.isEmpty else { break }
                text = rest
            }
            let start = (text.lastIndex(where: { delimiters.contains($0) }) ?? -1) + 1
            if start < text.count, isRemoved(String(text[start...]), source: source, output: output) { mark(start..<text.count) }
        }
        // A clause said again (verbatim, or restarted inside the next clause) may be merged by the cleanup
        // ("行かない、行かないです", "no, no").
        var clauses: [(range: Range<Int>, key: String)] = []
        var clauseStart = 0
        for position in 0...chars.count where position == chars.count || delimiters.contains(chars[position]) {
            let key = ResultValidator.normalizeForMatch(String(chars[clauseStart..<position]))
            if !key.isEmpty { clauses.append((clauseStart..<position, key)) }
            clauseStart = position + 1
        }
        for (i, clause) in clauses.enumerated() {
            let repeated = clauses[..<i].contains { $0.key == clause.key }
                || (i + 1 < clauses.count && clauses[i + 1].key.contains(clause.key))
            if repeated { mark(clause.range) }
        }
        // A word repeated right away without a pause ("no no", "行かない行かない").
        for (previous, current) in zip(found, found.dropFirst()) {
            let start = max(0, previous.upperBound - (current.upperBound - previous.upperBound))
            let again = ResultValidator.normalizeForMatch(String(masked[previous.upperBound..<current.upperBound]))
            let first = ResultValidator.normalizeForMatch(String(masked[start..<previous.upperBound]))
            if !again.isEmpty, again == first { mark(current) }
        }
        return mask
    }

    // MARK: - Predicate and auxiliary retention

    private enum SpeechAct: Hashable {
        case request, negation, wish, statement
    }

    private struct Predicate {
        var stem: String
        var ending: String

        var act: SpeechAct? {
            if ["ください", "下さい", "てほしい", "てもらえ", "ましょう"].contains(where: ending.contains) { return .request }
            if ["ない", "ません", "なかった"].contains(where: ending.contains) { return .negation }
            if ending.contains("たい") { return .wish }
            if ending.range(of: #"(?:た|だ|ます|ました|です|いる)(?:よ|ね|か)*$"#, options: .regularExpression) != nil {
                return .statement
            }
            return nil
        }

        var auxiliaries: Set<String> {
            var result = Set<String>()
            for (family, forms) in [
                ("oku", ["ておい", "でおい", "ておく", "でおく", "ておき", "でおき"]),
                ("shimau", ["てしま", "でしま", "ちゃ"]),
                ("ageru", ["てあげ"]), ("kureru", ["てくれ"]), ("morau", ["てもら"]),
            ] where forms.contains(where: ending.contains) { result.insert(family) }
            return result
        }
    }

    /// Deliberately limited to a written kanji stem followed by okurigana. No English tokens,
    /// noun overlap, or restart normalization can certify that a predicate was retained.
    private static func predicates(in text: String) -> [Predicate] {
        // A quantity glued to the stem must compare equally after numeral cleanup (三部印刷 → 3部印刷).
        let normalized = NumberExtractor.replacingNumerals(in: text).precomposedStringWithCompatibilityMapping
        guard let regex = try? NSRegularExpression(pattern: #"([\p{Han}々]+)([ぁ-ゖ]+(?:下さい[ぁ-ゖ]*)?)"#) else { return [] }
        let ns = normalized as NSString
        return regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length)).map {
            Predicate(stem: ns.substring(with: $0.range(at: 1)), ending: ns.substring(with: $0.range(at: 2)))
        }
    }

    /// Unlike overlap checks, this must see the transcript BEFORE RestartCollapser. Only a later
    /// predicate with the same stem and a different speech act establishes a distinct lost predicate.
    static func dropsDistinctPredicate(source: String, output: String, spans: [SelfCorrectionSpan] = []) -> Bool {
        let sourcePredicates = predicates(in: retentionSource(source, spans: spans))
        let outputPredicates = predicates(in: output)
        for (index, predicate) in sourcePredicates.enumerated() {
            guard let act = predicate.act,
                  !outputPredicates.contains(where: { $0.stem == predicate.stem && $0.act == act }) else { continue }
            if sourcePredicates.dropFirst(index + 1).contains(where: { later in
                later.stem == predicate.stem && later.act != nil && later.act != act
                    && outputPredicates.contains(where: { $0.stem == later.stem && $0.act == later.act })
            }) { return true }
        }
        return false
    }

    /// Auxiliary families allow inflection (おいて → おきます), but another stem cannot license loss.
    static func dropsAuxiliary(source: String, output: String, spans: [SelfCorrectionSpan] = []) -> Bool {
        let outputPredicates = predicates(in: output)
        return predicates(in: retentionSource(source, spans: spans)).contains { predicate in
            let retained = outputPredicates.filter { $0.stem == predicate.stem }
                .reduce(into: Set<String>()) { $0.formUnion($1.auxiliaries) }
            return !predicate.auxiliaries.isSubset(of: retained)
        }
    }

    // MARK: - Request endings

    private static let questionEndingsJA = ["ますか", "ですか", "でしょうか", "ませんか", "かな", "かしら", "っけ"]
    private static let requestEndingsJA = ["くださいね", "ください", "下さい"]

    /// The source ends with a request or question form and the output dropped its verb/ending:
    /// "今日の東京の天気を調べてください" → "今日の東京の天気" (or "…を確認してください"), "…ますか" → statement,
    /// "please …" → no "please".
    static func dropsRequestEnding(source: String, output: String) -> Bool {
        let s = source.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。．.、,!！")))
        guard !s.isEmpty else { return false }
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Questions stay questions.
        if s.hasSuffix("?") || s.hasSuffix("？") || questionEndingsJA.contains(where: { s.hasSuffix($0) }) {
            if !endsAsQuestion(out) { return true }
        }
        // English "please".
        if ResultValidator.wordNormalize(s).contains(" please "), !ResultValidator.wordNormalize(out).contains(" please ") {
            return true
        }
        // Japanese requests: the verb's te-form stays, and ください stays with it ("調べてください", "並べ替えて").
        let outKey = ResultValidator.normalizeForMatch(out)
        let ending = requestEndingsJA.first(where: { s.hasSuffix($0) })
        var verb = Array(ending.map { String(s.dropLast($0.count)) } ?? s)
        if ending == nil, verb.last == "ね" { verb.removeLast() }
        guard let last = verb.last, last == "て" || last == "で" else { return false }
        var start = verb.count
        while start > 0, isHiragana(verb[start - 1]) { start -= 1 }
        let kana = Array(verb[start...])
        // Short okurigana keep the stem character ("調べて", "認して"); long kana runs may be converted to kanji
        // by the cleanup ("おくって" → "送って"), so only their last two characters are required.
        var key = kana.count > 3 ? String(kana.suffix(2)) : String(kana)
        if kana.count <= 3, start > 0, !delimiters.contains(verb[start - 1]), !verb[start - 1].isWhitespace {
            key = String(verb[start - 1]) + key
        }
        let normalizedKey = ResultValidator.normalizeForMatch(key)
        guard !normalizedKey.isEmpty else { return false }
        if ending != nil {
            return !(outKey.contains(normalizedKey + "ください") || outKey.contains(normalizedKey + "下さい"))
        }
        return !outKey.contains(normalizedKey)
    }

    private static func endsAsQuestion(_ output: String) -> Bool {
        guard let last = ResultValidator.pieces(of: output).last?.text else { return false }
        return ResultValidator.endsAsQuestion(last) || questionEndingsJA.contains(where: {
            last.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！ ")).hasSuffix($0)
        })
    }
}
