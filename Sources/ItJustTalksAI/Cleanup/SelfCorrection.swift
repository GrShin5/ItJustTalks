import Foundation

/// A spoken self-correction located in the ORIGINAL transcript. Both texts are verbatim substrings of the
/// transcript. Contains user text: never log instances.
public struct SelfCorrectionSpan: Sendable, Hashable {
    /// What the speaker took back ("六脚").
    public var retracted: String
    /// What replaced it ("八脚"), when known.
    public var replacement: String?

    public init(retracted: String, replacement: String?) {
        self.retracted = retracted
        self.replacement = replacement
    }
}

/// Two-stage self-correction handling for cleanup (P1 round 2).
///
/// 1. `hasCue(in:)` decides deterministically whether stage A runs at all.
/// 2. Stage A (a small structured generation, `SelfCorrectionList`) proposes `{retracted, replacement}` pairs.
/// 3. `apply(_:to:)` verifies every pair against the transcript and deletes "retracted span + cue +
///    connecting punctuation", keeping the replacement. Unverifiable or overlapping proposals are dropped;
///    verified independent corrections are kept.
/// 4. Stage B is the normal cleanup of the corrected transcript.
///
/// Pure and deterministic; never logs.
public enum SelfCorrection {
    // MARK: - Cue vocabulary

    /// Japanese cues (longest first). Without a pause, nearby parallel wording is required.
    /// Cues that only ever mark a correction (no apologies).
    static let correctionOnlyCuesJA: Set<String> = ["言い直します", "言い直すと", "じゃなくて", "ではなくて", "訂正します", "やっぱり", "じゃなく", "ではなく", "やっぱ", "もとい", "いや"]
    static let cuesJA: [String] = [
        "言い直します", "言い直すと", "間違えました", "失礼しました", "ごめんなさい", "じゃなくて", "ではなくて",
        "訂正します", "違いました", "間違えた", "すみません", "すいません", "やっぱり", "じゃなく", "ではなく",
        "でなくて", "違った", "やっぱ", "でなく", "ごめん", "もとい", "ちがう", "訂正", "違う", "いや", "いえ",
    ]
    /// English cues, lower case. Strong cues count anywhere (word-bounded); weak ones need a pause.
    static let strongCuesEN: [String] = ["no wait", "wait no", "scratch that", "i mean", "i meant", "make that", "or rather"]
    static let weakCuesEN: [String] = ["actually", "sorry", "correction", "wait"]
    /// Stand-alone fillers that may sit between a retraction and its replacement ("…、あ、違う、…").
    static let fillersJA: [String] = ["えーっと", "えーと", "えっと", "あのー", "あのう", "うーん", "えー", "あー", "あっ", "えと", "あの", "その", "まあ", "あ", "え"]
    static let fillersEN: [String] = ["umm", "uhm", "erm", "hmm", "um", "uh", "er", "ah", "oh", "well"]
    static let delimiters: Set<Character> = [
        "、", "。", "，", "．", ",", ".", "!", "?", "！", "？", ";", "；", ":", "：", "\n", "—", "–", "…", "-",
    ]

    // MARK: - Stage A gate

    /// True when the transcript contains a self-correction cue (いや, やっぱり, じゃなくて/ではなくて, すみません,
    /// 訂正, 違う, "あ、", actually, I mean, no wait, sorry, scratch that, …) in a correction-like position.
    public static func hasCue(in transcript: String) -> Bool {
        let chars = Array(transcript)
        let lower = lowered(chars)
        var index = 0
        while index < chars.count {
            if cueAt(index, chars: chars, lower: lower, requirePause: true) != nil { return true }
            index += 1
        }
        return false
    }

    // MARK: - Application

    public struct Outcome: Sendable, Hashable {
        /// Transcript with independent verified corrections applied; nil when none can safely be applied.
        public var corrected: String?
        /// Retractions verified in the original transcript (for `ValidationInput.selfCorrections`). On a
        /// fallback this holds the proposals whose retracted text was still found right before a cue.
        public var spans: [SelfCorrectionSpan]
        /// Counts only safely applied proposals; duplicates and rejected proposals count as dropped.
        public var verifiedProposals: Int = 0
        public var droppedProposals: Int = 0
    }

    /// Verifies and applies stage-A proposals. A proposal is applied only when its retracted text occurs
    /// verbatim in the transcript, is followed (optionally after a short tail that the replacement repeats,
    /// "営業部|です、すみません、総務部です") by a run of cues, fillers and punctuation containing at least one
    /// cue, and its replacement starts within a few characters after that run (a proposal whose two fields are
    /// swapped is accepted in the transcript's order). The deleted range is
    /// retracted + tail + cue run; everything from the end of the run on is kept.
    public static func apply(_ proposals: [(retracted: String, replacement: String)], to transcript: String) -> Outcome {
        let chars = Array(transcript)
        let lower = lowered(chars)
        var ranges: [Range<Int>] = []
        var spans: [SelfCorrectionSpan] = []
        var uncertain: [Range<Int>] = []
        var fallbackSpans: [(range: Range<Int>, span: SelfCorrectionSpan)] = []
        // An unverifiable proposal must not license an overlapping deletion in either direction.
        func markUncertain(_ texts: [String]) {
            for text in texts where !text.isEmpty {
                let needle = lowered(Array(text))
                guard needle.count <= lower.count else { continue }
                for start in 0...(lower.count - needle.count) {
                    if lower[start..<(start + needle.count)].elementsEqual(needle) {
                        uncertain.append(start..<(start + needle.count))
                    }
                }
            }
        }
        var seen = Set<String>()

        for proposal in proposals {
            let retracted = trimmedRetracted(proposal.retracted)
            let replacement = trimmedReplacement(proposal.replacement)
            guard !retracted.isEmpty else { markUncertain([replacement]); continue }
            guard seen.insert(retracted + "\u{1F}" + replacement).inserted else { continue }
            guard !replacement.isEmpty, retracted != replacement else {
                markUncertain([retracted, replacement])
                if let range = locate(retracted, replacement: nil, chars: chars, lower: lower) {
                    fallbackSpans.append((range.deletion, SelfCorrectionSpan(retracted: String(chars[range.retracted]), replacement: nil)))
                }
                continue
            }
            // The transcript decides the direction: the text before the cue is the retraction even when the
            // model swapped the two fields. A whole statement is only retracted for another whole statement.
            let narrowed = narrowedStatement(retracted, replacement: replacement)
                ?? narrowedEnglish(retracted, replacement: replacement)
            if let found = narrowed.flatMap({ locate($0, replacement: replacement, chars: chars, lower: lower) })
                ?? locate(retracted, replacement: replacement, chars: chars, lower: lower) {
                ranges.append(found.deletion)
                spans.append(SelfCorrectionSpan(retracted: String(chars[found.retracted]), replacement: replacement))
            } else if let swapped = trimmedRetracted(proposal.replacement) as String?, !swapped.isEmpty,
                      let found = locate(swapped, replacement: trimmedReplacement(proposal.retracted), chars: chars, lower: lower) {
                ranges.append(found.deletion)
                spans.append(SelfCorrectionSpan(retracted: String(chars[found.retracted]), replacement: trimmedReplacement(proposal.retracted)))
            } else {
                markUncertain([retracted, replacement])
                // A replacement the transcript does not contain makes the whole proposal unreliable.
                let replacementKey = ResultValidator.normalizeForMatch(NumberExtractor.replacingNumerals(in: replacement))
                if !replacementKey.isEmpty,
                   ResultValidator.normalizeForMatch(NumberExtractor.replacingNumerals(in: transcript)).contains(replacementKey),
                   let partial = locate(retracted, replacement: replacement, requireReplacement: false, chars: chars, lower: lower) {
                    fallbackSpans.append((partial.deletion, SelfCorrectionSpan(retracted: String(chars[partial.retracted]), replacement: nil)))
                }
            }
        }
        // Reject both sides of a conflict, independent of proposal order.
        let accepted = ranges.indices.filter { i in
            !uncertain.contains(where: { $0.overlaps(ranges[i]) })
                && !ranges.indices.contains(where: { $0 != i && ranges[$0].overlaps(ranges[i]) })
        }
        let keptSpans = accepted.map { spans[$0] }
        let independentFallbackSpans = fallbackSpans.filter { fallback in
            !ranges.contains(where: { $0.overlaps(fallback.range) })
        }.map(\.span)
        func outcome(_ corrected: String?, applied: Int) -> Outcome {
            Outcome(corrected: corrected, spans: keptSpans + independentFallbackSpans,
                    verifiedProposals: applied, droppedProposals: proposals.count - applied)
        }
        guard !accepted.isEmpty else {
            return outcome(proposals.isEmpty ? transcript : nil, applied: 0)
        }

        // Deletions must leave most of the transcript (a correction is local).
        let sorted = accepted.map { ranges[$0] }.sorted { $0.lowerBound < $1.lowerBound }
        let deleted = sorted.reduce(0) { $0 + $1.count }
        guard Double(deleted) <= Double(chars.count) * maximumDeletedShare else {
            return outcome(nil, applied: 0)
        }
        var result = chars
        for range in sorted.reversed() { result.removeSubrange(range) }
        var corrected = String(result).trimmingCharacters(in: .whitespacesAndNewlines)
        // An English transcript that started with a capital keeps one after its first sentence is retracted.
        if transcript.unicodeScalars.allSatisfy({ !$0.properties.isAlphabetic || $0.isASCII }),
           transcript.first?.isUppercase == true, sorted.first?.lowerBound == 0, let first = corrected.first,
           corrected.prefix(while: { !$0.isWhitespace }).allSatisfy({ !$0.isUppercase }) {
            corrected.replaceSubrange(corrected.startIndex...corrected.startIndex, with: String(first).uppercased())
        }
        guard !corrected.isEmpty else { return outcome(nil, applied: 0) }
        return outcome(corrected, applied: accepted.count)
    }

    /// A Japanese retraction with its own topic/subject ("昼は駅前のラーメン屋にしようかな") whose replacement has none
    /// ("寿司屋にする") was stretched over the whole statement: it is narrowed to its last noun phrase
    /// ("ラーメン屋にしようかな"), but only when that phrase and the replacement are parallel (a noun followed by
    /// the same particle) and the kept part holds no verb. Nil when in doubt.
    private static func narrowedStatement(_ retracted: String, replacement: String) -> String? {
        let r = Array(retracted)
        let p = Array(replacement)
        guard hasTopic(r), !hasTopic(p) else { return nil }
        let particles: Set<Character> = ["は", "が", "の", "を", "に", "で", "へ", "と", "も", "だ"]
        // Noun run and the character after it ("ラーメン屋|に…").
        func split(_ text: ArraySlice<Character>) -> (noun: String, next: Character)? {
            guard let end = text.firstIndex(where: { !isNounStart($0) }), end > text.startIndex else { return nil }
            return (String(text[text.startIndex..<end]), text[end])
        }
        guard let target = split(p[...]), particles.contains(target.next) else { return nil }
        var index = r.count - 2
        while index > 0 {
            defer { index -= 1 }
            guard particles.contains(r[index]), isNounStart(r[index - 1]),
                  let phrase = split(r[(index + 1)...]), phrase.next == target.next, phrase.noun != target.noun else { continue }
            // The kept part must not contain a verb stem (kanji followed by okurigana).
            let kept = r[...index]
            let hasVerb = zip(kept, kept.dropFirst()).contains { isNounStart($0) && !$0.isASCII && isHiragana($1) && !particles.contains($1) }
            return hasVerb ? nil : String(r[(index + 1)...])
        }
        return nil
    }

    /// An English retraction stretched over a clause ("move the table closer to the doorway") whose replacement
    /// is one or two words ("fireplace") is narrowed to the same number of final words ("doorway"). Whole
    /// statements of similar length ("I'll call him" / "I'll email him") are not narrowed. Nil when in doubt.
    private static func narrowedEnglish(_ retracted: String, replacement: String) -> String? {
        let isEnglish: (String) -> Bool = { $0.unicodeScalars.allSatisfy { $0.isASCII } }
        guard isEnglish(retracted), isEnglish(replacement) else { return nil }
        let r = retracted.split(whereSeparator: \.isWhitespace)
        let p = replacement.split(whereSeparator: \.isWhitespace)
        let determinerSet: Set<String> = ["the", "a", "an", "to", "at", "on", "in", "by", "for", "from", "with",
                                          "near", "this", "that", "my", "your", "our", "their", "his", "her"]
        // The narrowed words must follow a determiner or preposition ("near the |window|"), and the replacement
        // must not start with one; "with Priya on |Thursday|" / "with Daniel" is not narrowed.
        if (1...2).contains(p.count), r.count >= p.count + 2,
           determinerSet.contains(r[r.count - p.count - 1].lowercased()),
           !determinerSet.contains(p[0].lowercased()) {
            return r.suffix(p.count).joined(separator: " ")
        }
        // A longer replacement that runs on with the rest of the sentence ("fireplace the chairs can ..."):
        // only the noun after a determiner or preposition is retracted, unless the replacement starts a new
        // statement with a pronoun ("let's go to the park, actually we stay home" is a whole statement).
        let determiners: Set<String> = ["the", "a", "an", "to", "at", "on", "in", "by", "for", "from", "with",
                                        "near", "this", "that", "my", "your", "our", "their", "his", "her"]
        let pronouns: Set<String> = ["i", "we", "you", "he", "she", "they", "it", "let's", "lets", "i'll", "we'll",
                                     "i'm", "we're", "there", "then", "so", "and", "but"]
        guard r.count >= 3, p.count >= 1, let first = p.first?.lowercased(),
              determiners.contains(r[r.count - 2].lowercased()), !pronouns.contains(first),
              !determiners.contains(first),
              // Parallel statements repeat the retracted noun ("keep the draft" / "delete the draft").
              !p.contains(where: { $0.lowercased() == r[r.count - 1].lowercased() }) else { return nil }
        return String(r[r.count - 1])
    }

    /// A noun followed by the topic or subject particle ("昼は", "会議が").
    private static func hasTopic(_ chars: [Character]) -> Bool {
        chars.indices.dropFirst().contains { ["は", "が"].contains(chars[$0]) && isNounStart(chars[$0 - 1]) }
    }

    private static func isNounStart(_ c: Character) -> Bool {
        !isHiragana(c) && !c.isWhitespace && !delimiters.contains(c)
    }

    /// Share of the transcript the deletions may remove at most.
    static let maximumDeletedShare = 0.75
    /// Longest tail between the retracted text and the cue that may be dropped with it (it must also occur
    /// in the replacement).
    static let maximumTail = 12
    /// Longest stretch after the cue run before the replacement starts (that stretch is kept).
    static let maximumLeadIn = 8

    private struct Located {
        var retracted: Range<Int>
        var deletion: Range<Int>
    }

    /// Finds `retracted` followed by a cue run and `replacement` right after it. With `requireReplacement`
    /// false (validator spans on a fallback) the replacement only licenses a tail.
    private static func locate(
        _ retracted: String, replacement: String?, requireReplacement: Bool = true, chars: [Character], lower: [Character]
    ) -> Located? {
        if requireReplacement, let replacement {
            let text = String(chars)
            if let range = EnglishCuedRestart.sentenceDeletion(in: text, retracted: retracted, replacement: replacement),
               let item = text.range(of: retracted, options: .caseInsensitive, range: range) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let end = text.distance(from: text.startIndex, to: range.upperBound)
                let itemStart = text.distance(from: text.startIndex, to: item.lowerBound)
                let itemEnd = text.distance(from: text.startIndex, to: item.upperBound)
                return Located(retracted: itemStart..<itemEnd, deletion: start..<end)
            }
        }
        let needle = lowered(Array(retracted))
        let replacementChars = replacement.map { lowered(Array($0)) }
        let replacementKey = replacement.map { ResultValidator.normalizeForMatch($0) } ?? ""
        guard !needle.isEmpty, needle.count <= chars.count else { return nil }
        var start = 0
        while start + needle.count <= lower.count {
            defer { start += 1 }
            guard Array(lower[start..<(start + needle.count)]) == needle else { continue }
            let end = start + needle.count
            // English matches must be word-bounded.
            if isWordCharacter(lower[start]), start > 0, isWordCharacter(lower[start - 1]), isASCIIWord(lower[start]) { continue }
            if let last = needle.last, isASCIIWord(last), end < lower.count, isWordCharacter(lower[end]) { continue }
            // Optional tail, then the cue run.
            for runStart in end...min(lower.count, end + maximumTail) {
                guard let runEnd = cueRunEnd(from: runStart, chars: chars, lower: lower) else { continue }
                var replacementAt: Int?
                if let replacementChars, let offset = firstIndex(of: replacementChars, in: lower, from: runEnd),
                   offset - runEnd <= maximumLeadIn {
                    replacementAt = offset
                }
                if requireReplacement, replacement != nil, replacementAt == nil { continue }
                if runStart > end {
                    let tailChars = Array(chars[end..<runStart])
                    let tail = ResultValidator.normalizeForMatch(String(tailChars))
                    if !tail.isEmpty {
                        // The replacement repeats the tail ("営業部|です" → "総務部です"), or both are followed by
                        // the same particle and the tail is only kana ("パスタ屋|にしようかな" → "カレー屋|にする").
                        // A clause the replacement continues with verbatim ("staging|で確認してから、いや
                        // production|で確認してから") is parallel too.
                        let repeated = replacement != nil && replacementKey.contains(tail)
                        var parallel = false
                        if let at = replacementAt, let count = replacementChars?.count {
                            let after = at + count
                            if after + tailChars.count <= chars.count, Array(chars[after..<(after + tailChars.count)]) == tailChars {
                                parallel = true
                            } else if tailChars.count <= 8, tailChars.allSatisfy(isHiragana), after < chars.count,
                                      chars[after] == tailChars[0] {
                                parallel = true
                            }
                        }
                        // Validator spans only flag kept text, so any short tail is acceptable there.
                        guard repeated || parallel || !requireReplacement else { continue }
                    }
                }
                return Located(retracted: start..<end, deletion: start..<runEnd)
            }
        }
        return nil
    }

    /// End of a run of whitespace, punctuation, fillers and cues starting at `index` that contains at least
    /// one cue; nil when there is no such run.
    private static func cueRunEnd(from index: Int, chars: [Character], lower: [Character]) -> Int? {
        var position = index
        var sawCue = false
        while position < chars.count {
            let c = chars[position]
            if c.isWhitespace || delimiters.contains(c) {
                position += 1
                continue
            }
            if let cue = cueAt(position, chars: chars, lower: lower, requirePause: false) {
                sawCue = true
                position += cue
                continue
            }
            if let filler = fillerAt(position, chars: chars, lower: lower) {
                position += filler
                continue
            }
            break
        }
        return sawCue ? position : nil
    }

    /// Length of the cue at `index`, or nil. The gate requires a pause or parallel Japanese wording;
    /// weak English cues still require a pause (a filler may sit in between: "、あ違う").
    private static func cueAt(_ index: Int, chars: [Character], lower: [Character], requirePause: Bool) -> Int? {
        // "あ、" is a cue only after a pause.
        if lower[index] == "あ", index + 1 < chars.count, chars[index + 1] == "、" || chars[index + 1] == "," {
            if !requirePause || pauseBefore(index, chars: chars, lower: lower) { return 2 }
        }
        for cue in cuesJA where matches(cue, at: index, in: lower) {
            let end = index + cue.count
            if !requirePause { return cue.count }
            let after = end < chars.count ? chars[end] : nil
            // A Latin word or digit right after a Japanese cue sits where STT put a space (removed by
            // JapaneseSpacing): 「stagingじゃなくてproduction」.
            let pauseAfter = after.map { delimiters.contains($0) || $0.isWhitespace || ($0.isASCII && ($0.isLetter || $0.isNumber)) } ?? false
            if pauseAfter || pauseBefore(index, chars: chars, lower: lower) {
                // "いやです", "違うよね" continue as a hiragana word.
                if let after, isHiragana(after), !pauseAfter, ["いや", "いえ", "違う", "ちがう"].contains(cue) { continue }
                return cue.count
            }
            // The longest matching contrastive cue owns this position, including its exception.
            let contrastive = ["じゃなくて", "ではなくて", "じゃなく", "ではなく", "でなくて", "でなく"].contains(cue)
            let following = String(chars[end..<min(chars.count, end + 12)])
            if contrastive && ["方が", "ほうが", "のが"].contains(where: following.contains) { return nil }
            if parallelAroundCue(index, end: end, chars: chars) { return cue.count }
            return nil
        }
        guard index == 0 || !isWordCharacter(lower[index - 1]) else { return nil }
        for (list, strong) in [(strongCuesEN, true), (weakCuesEN, false)] {
            for cue in list where matches(cue, at: index, in: lower) {
                let end = index + cue.count
                if end < lower.count, isWordCharacter(lower[end]) || lower[end] == "'" { continue }
                if requirePause, !strong {
                    let after = end < chars.count ? chars[end] : nil
                    let pauseAfter = after.map { delimiters.contains($0) } ?? false
                    guard pauseAfter || pauseBefore(index, chars: chars, lower: lower) else { continue }
                }
                return cue.count
            }
        }
        return nil
    }

    /// Compare adjacent phrases of equal length (at most 15 characters), never across a pause.
    private static func parallelAroundCue(_ start: Int, end: Int, chars: [Character]) -> Bool {
        var left = start
        while left > 0, start - left < 15,
              !chars[left - 1].isWhitespace, !delimiters.contains(chars[left - 1]) { left -= 1 }
        var right = end
        while right < chars.count, right - end < 15,
              !chars[right].isWhitespace, !delimiters.contains(chars[right]) { right += 1 }
        let limit = min(start - left, right - end)
        guard limit > 0 else { return false }
        for length in 1...limit {
            let before = Array(chars[(start - length)..<start])
            let after = Array(chars[end..<(end + length)])
            let prefix = zip(before, after).prefix(while: { $0 == $1 }).count
            let suffix = zip(before.reversed(), after.reversed()).prefix(while: { $0 == $1 }).count
            // Two shared characters at the same positions (「来週の月曜いや来週の火曜」), or a shared unit
            // between numbers (「14枚いや19枚」); one shared character (「夏はやっぱり夏祭り」) is not enough.
            if prefix + suffix >= 2, prefix < length { return true }
            if suffix >= 1, before.contains(where: \.isNumber), after.contains(where: \.isNumber) { return true }
        }
        return false
    }

    private static func fillerAt(_ index: Int, chars: [Character], lower: [Character]) -> Int? {
        for filler in fillersJA + fillersEN where matches(filler, at: index, in: lower) {
            let end = index + filler.count
            if isASCIIWord(lower[index]) {
                if index > 0, isWordCharacter(lower[index - 1]) { continue }
                if end < lower.count, isWordCharacter(lower[end]) { continue }
                return filler.count
            }
            // A Japanese filler only when followed by a pause, the end or a cue ("あ違う").
            if end >= chars.count || delimiters.contains(chars[end]) || chars[end].isWhitespace
                || cueAt(end, chars: chars, lower: lower, requirePause: false) != nil {
                return filler.count
            }
        }
        return nil
    }

    /// Punctuation right before `index`, skipping whitespace and stand-alone fillers.
    private static func pauseBefore(_ index: Int, chars: [Character], lower: [Character]) -> Bool {
        var position = index
        while true {
            while position > 0, chars[position - 1].isWhitespace { position -= 1 }
            guard position > 0 else { return false }
            if delimiters.contains(chars[position - 1]) { return true }
            var stepped = false
            for filler in fillersJA + fillersEN {
                let count = filler.count
                guard position - count >= 0, matches(filler, at: position - count, in: lower) else { continue }
                let before = position - count
                if before == 0 || delimiters.contains(chars[before - 1]) || chars[before - 1].isWhitespace {
                    position = before
                    stepped = true
                    break
                }
            }
            if !stepped { return false }
        }
    }

    // MARK: - Trimming proposals

    /// Retracted text without trailing punctuation, fillers or cues (a model may include "、いや").
    static func trimmedRetracted(_ text: String) -> String {
        var chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var changed = true
        while changed, !chars.isEmpty {
            changed = false
            while let last = chars.last, last.isWhitespace || delimiters.contains(last) {
                chars.removeLast()
                changed = true
            }
            let lower = lowered(chars)
            outer: for word in cuesJA + strongCuesEN + weakCuesEN + fillersJA + fillersEN where word.count < chars.count {
                let start = chars.count - word.count
                guard matches(word, at: start, in: lower) else { continue }
                let boundary = chars[start - 1]
                // Japanese cues need no pause at the end of a retraction either (「午後3時やっぱり」).
                // Correction cues need no pause at the end of a retraction (「午後3時やっぱり」); apologies do
                // (「遅れてすみません」 is not a retraction).
                if boundary.isWhitespace || delimiters.contains(boundary) || correctionOnlyCuesJA.contains(word) {
                    chars.removeLast(word.count)
                    changed = true
                    break
                }
                // A Japanese cue glued to a stand-alone filler ("…、あ違う").
                guard cuesJA.contains(word) else { continue }
                for filler in fillersJA where filler.count < start {
                    let fillerStart = start - filler.count
                    guard matches(filler, at: fillerStart, in: lower) else { continue }
                    let before = chars[fillerStart - 1]
                    if before.isWhitespace || delimiters.contains(before) {
                        chars.removeLast(word.count + filler.count)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return String(chars)
    }

    /// Replacement text without leading punctuation, fillers or cues.
    static func trimmedReplacement(_ text: String) -> String {
        var chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var changed = true
        while changed, !chars.isEmpty {
            changed = false
            while let first = chars.first, first.isWhitespace || delimiters.contains(first) {
                chars.removeFirst()
                changed = true
            }
            let lower = lowered(chars)
            for word in cuesJA + strongCuesEN + weakCuesEN + fillersJA + fillersEN where word.count < chars.count {
                guard matches(word, at: 0, in: lower) else { continue }
                let boundary = chars[word.count]
                // Japanese cues need no pause at the start of a replacement ("いや五番").
                if boundary.isWhitespace || delimiters.contains(boundary) || cuesJA.contains(word) {
                    chars.removeFirst(word.count)
                    changed = true
                    break
                }
            }
        }
        // Trailing sentence punctuation is not part of the words ("八脚。").
        while let last = chars.last, last.isWhitespace || delimiters.contains(last) { chars.removeLast() }
        return String(chars)
    }

    // MARK: - Character helpers

    static func lowered(_ chars: [Character]) -> [Character] {
        chars.map { c in
            let folded = String(c).lowercased()
            return folded.count == 1 ? Character(folded) : c
        }
    }

    private static func matches(_ word: String, at index: Int, in chars: [Character]) -> Bool {
        let w = Array(word)
        guard index >= 0, index + w.count <= chars.count else { return false }
        for offset in 0..<w.count where chars[index + offset] != w[offset] { return false }
        return true
    }

    private static func firstIndex(of needle: [Character], in haystack: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, from + needle.count <= haystack.count else { return nil }
        for index in from...(haystack.count - needle.count) where Array(haystack[index..<(index + needle.count)]) == needle {
            return index
        }
        return nil
    }

    private static func isHiragana(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    private static func isASCIIWord(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        isASCIIWord(c) || c == "'"
    }
}
