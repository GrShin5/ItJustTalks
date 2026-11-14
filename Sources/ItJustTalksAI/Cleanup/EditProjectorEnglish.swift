import Foundation

extension EditProjector {
    private struct EnglishToken {
        var text: String
        var word: Bool
        var key: String { text.lowercased() }
    }

    private static func englishTokens(_ text: String) -> [EnglishToken] {
        let chars = Array(text)
        var tokens: [EnglishToken] = []
        var i = 0
        while i < chars.count {
            let start = i
            let word = chars[i].isLetter || chars[i].isNumber
                || ((chars[i] == "'" || chars[i] == "’") && i + 1 < chars.count && chars[i + 1].isLetter)
            i += 1
            if word {
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber
                    || ((chars[i] == "'" || chars[i] == "’") && i + 1 < chars.count && chars[i + 1].isLetter)) { i += 1 }
            } else if chars[start].isWhitespace {
                while i < chars.count && chars[i].isWhitespace { i += 1 }
            }
            tokens.append(EnglishToken(text: String(chars[start..<i]), word: word))
        }
        return tokens
    }

    private static let englishFillers: Set<String> = ["um", "uh", "er", "ah", "hmm", "mm"]
    private static let englishOpenWords: Set<String> = [
        "and", "but", "because", "so", "if", "then", "that", "to", "of", "the", "a", "an",
        "or", "with", "for", "which", "who", "as", "at", "by", "from", "in", "on", "into",
        "although", "while", "when", "where", "whose", "whom", "without", "until", "unless"
    ]

    static func stripEnglishHesitations(_ text: String) -> String {
        let tokens = englishTokens(text)
        var result = ""
        var i = 0
        var quoted = false
        while i < tokens.count {
            let token = tokens[i]
            if ["\"", "“", "”"].contains(token.text) { quoted.toggle() }
            // "35 mm" is a unit, not a hesitation.
            let afterNumber = tokens[..<i].last(where: { !$0.text.allSatisfy(\.isWhitespace) })?.text.allSatisfy(\.isNumber) == true
            // Only "um" / "Um" style spellings: "ER", "UM" are acronyms. "Uh-huh" is a word.
            let hyphenated = (i > 0 && tokens[i - 1].text == "-") || (i + 1 < tokens.count && tokens[i + 1].text == "-")
            let spelledAsFiller = token.text == token.key || token.text == token.key.prefix(1).uppercased() + token.key.dropFirst()
            if !quoted && token.word && englishFillers.contains(token.key) && !afterNumber && !hyphenated && spelledAsFiller {
                i += 1
                while i < tokens.count && (tokens[i].text == "," || tokens[i].text.allSatisfy(\.isWhitespace)) { i += 1 }
                continue
            }
            result += token.text
            i += 1
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : result
    }

    private static func adjacentEnglishRepeat(_ tokens: [EnglishToken], from start: Int, to end: Int) -> Bool {
        let deleted = tokens[start..<end]
        let words = deleted.filter(\.word)
        guard (2...4).contains(words.count),
              deleted.allSatisfy({ $0.word || $0.text.allSatisfy(\.isWhitespace) }) else { return false }
        func safe(_ index: Int) -> Bool {
            let t = tokens[index]
            let sentenceStart = !tokens[..<index].contains(where: \.word)
                || tokens[..<index].last(where: { !$0.text.allSatisfy(\.isWhitespace) }).map { ".!?".contains($0.text) } == true
            return !t.text.contains(where: \.isNumber)
                && (t.text.first?.isUppercase != true || t.key == "i" || sentenceStart)
        }
        guard (start..<end).filter({ tokens[$0].word }).allSatisfy(safe) else { return false }
        // Spelled numbers, coordinated phrases ("again and again") and a relative/question word before the
        // first copy ("what we have we have to") make a doubled phrase grammatical, not a stumble.
        if words.contains(where: { isEnglishNumberWord($0.key) || ["and", "or"].contains($0.key) }) { return false }
        let headWords: Set<String> = ["what", "whatever", "whoever", "who", "where", "how", "when", "why", "which", "wherever"]
        for forward in [true, false] {
            var cursor = forward ? end : start - 1
            var adjacent: [String] = []
            while cursor >= 0 && cursor < tokens.count && adjacent.count < words.count {
                let t = tokens[cursor]
                if t.word {
                    guard safe(cursor) else { break }
                    adjacent.append(t.key)
                } else if !t.text.allSatisfy(\.isWhitespace) { break }
                cursor += forward ? 1 : -1
            }
            if !forward { adjacent.reverse() }
            if adjacent == words.map(\.key) {
                // The first copy starts at the deletion (forward) or right after the backward cursor.
                let firstCopy = forward ? start : cursor + 1
                if let before = tokens[..<firstCopy].last(where: \.word), headWords.contains(before.key) { return false }
                return true
            }
        }
        return false
    }

    /// Common words that stay lower case inside a sentence (discourse markers and function words).
    private static let englishCommonLowercase: Set<String> = [
        "actually", "honestly", "basically", "anyway", "well", "so", "then", "and", "but", "or", "also", "now",
        "okay", "ok", "right", "yes", "no", "oh", "just", "really", "maybe", "please", "like", "still", "though",
        "the", "a", "an", "to", "of", "in", "on", "at", "for", "with", "from", "by", "it", "this", "that", "these",
        "those", "we", "you", "they", "he", "she", "is", "are", "was", "were", "be", "let", "let's", "what", "when",
    ]
    private static let englishClauseWords: Set<String> = [
        "i", "we", "you", "he", "she", "it", "they", "is", "are", "was", "were", "am", "be", "can", "could",
        "should", "would", "will", "must", "may", "might", "if", "when", "possible", "do", "does", "did", "have", "has",
    ]
    private static func isEnglishNumberWord(_ word: String) -> Bool {
        ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
         "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "million", "first", "second", "third"].contains(word)
    }
    private static let englishFillerPhrases: Set<[String]> = [["you", "know"], ["i", "mean"], ["like"], ["um"], ["uh"], ["so"], ["well"]]

    private static func enumerationCommas(_ tokens: [EnglishToken]) -> Set<Int> {
        var protected = Set<Int>()
        var start = 0
        for end in 0...tokens.count where end == tokens.count || ".!?;".contains(tokens[end].text) {
            let commas = (start..<end).filter { tokens[$0].text == "," }
            if commas.count >= 2 {
                // Require nonempty, short item spans; conjunction clauses are not lists.
                let bounds = [start - 1] + commas + [end]
                let items = zip(bounds, bounds.dropFirst()).map { left, right in
                    tokens[(left + 1)..<right].filter(\.word).map(\.key)
                }
                // Inner items are short; a filler phrase between commas ("the, you know, the") is no list.
                if items.allSatisfy({ !$0.isEmpty && $0.count <= 5 }),
                   items.dropFirst().dropLast().allSatisfy({ $0.count <= 3 }),
                   !items.contains(where: { englishFillerPhrases.contains($0) }),
                   !items.dropFirst().contains(where: { $0.contains("but") || $0.contains("because") }),
                   // Clauses ("I think, we should, go now") carry pronouns or verbs; list items do not.
                   !items.dropFirst().contains(where: { item in item.contains { Self.englishClauseWords.contains($0) } }) {
                    // "We compared, A, B, and C": a short subject+verb lead-in is not the first item.
                    let leadIn = items[0].count <= 2 && items[0].contains { Self.englishClauseWords.contains($0) }
                    protected.formUnion(leadIn ? Array(commas.dropFirst()) : commas)
                }
            }
            start = end + 1
        }
        return protected
    }

    static func projectEnglish(_ input: Input) -> Result {
        let source = stripEnglishHesitations(input.source)
        let s = englishTokens(source), o = englishTokens(input.output)
        // Token LCS never exposes a partial word as an editable hunk.
        var rows = Array(repeating: Array(repeating: 0, count: o.count + 1), count: s.count + 1)
        if !s.isEmpty && !o.isEmpty {
            for i in stride(from: s.count - 1, through: 0, by: -1) {
                for j in stride(from: o.count - 1, through: 0, by: -1) {
                    rows[i][j] = s[i].key == o[j].key ? rows[i + 1][j + 1] + 1 : max(rows[i + 1][j], rows[i][j + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < s.count && j < o.count {
            if s[i].key == o[j].key { pairs.append((i, j)); i += 1; j += 1 }
            else if rows[i + 1][j] >= rows[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        let listCommas = enumerationCommas(s)
        let words = s.filter(\.word).count
        let alignment = words == 0 ? 1 : Double(pairs.filter { s[$0.0].word }.count) / Double(words)
        var result = Result(text: "", fellBack: false, alignment: alignment,
                            accepted: source == input.source ? [:] : [.fillerDeletion: 1], rejected: [:])
        if input.output.isEmpty || alignment < 0.4 {
            result.text = source; result.fellBack = true; return result
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let open = trimmed.last.map { !".!?".contains($0) } == true
            && s.last(where: \.word).map { englishOpenWords.contains($0.key) } == true
        var si = 0, oi = 0
        for (a, b) in pairs + [(s.count, o.count)] {
            if si != a || oi != b {
                let removed = s[si..<a].map(\.text).joined()
                let inserted = o[oi..<b].map(\.text).joined()
                let sw = s[si..<a].filter(\.word).map(\.key)
                let ow = o[oi..<b].filter(\.word).map(\.key)
                var kind: EditKind = sw.isEmpty ? .insertion : (ow.isEmpty ? .deletion : .wordChange)
                var accept = false
                if sw.isEmpty && ow.isEmpty {
                    kind = (removed + inserted).allSatisfy(\.isWhitespace) ? .whitespace : .punctuation
                    accept = true
                    if (si..<a).contains(where: { listCommas.contains($0) }),
                       removed.filter({ $0 == "," }).count > inserted.filter({ $0 == "," }).count { accept = false }
                    // Whitespace between words is lexical, and cannot be removed.
                    if inserted.isEmpty && removed.contains(where: \.isWhitespace), si > 0, a < s.count,
                       s[si - 1].word && s[a].word { accept = false }
                    // "3 5" → "3.5" / "3-5" joins tokens; "report.pdf" → "report. pdf" splits one.
                    if si > 0, a < s.count, s[si - 1].word, s[a].word {
                        let joins = removed.contains(where: \.isWhitespace) && !inserted.contains(where: \.isWhitespace)
                        let splits = !removed.contains(where: \.isWhitespace) && inserted.contains(where: \.isWhitespace)
                        if joins || splits { accept = false }
                    }
                    // No space is put inside a written token ("report.pdf", "3.5", "a@b"): the source had none.
                    if removed.isEmpty, inserted.contains(where: \.isWhitespace), si > 0, a < s.count,
                       !s[si - 1].text.allSatisfy(\.isWhitespace), !s[a].text.allSatisfy(\.isWhitespace),
                       s[si - 1].word || s[a].word { accept = false }
                    if a == s.count && inserted.contains(".") && open { kind = .terminalCompletion; accept = false }
                } else if ow.isEmpty {
                    let phrase = sw.joined(separator: " ")
                    let left = s[..<si].last { !$0.text.allSatisfy(\.isWhitespace) }
                    let right = s[a...].first { !$0.text.allSatisfy(\.isWhitespace) }
                    let pausedLeft = si == 0 || left?.text == "," || removed.hasPrefix(",")
                    let pausedRight = a == s.count || right?.text == "," || removed.trimmingCharacters(in: .whitespaces).hasSuffix(",")
                    // A word repeated around a weak filler goes with it ("on the, you know, the invoice").
                    var core = sw
                    let leftWord = s[..<si].last(where: \.word)?.key, rightWord = s[a...].first(where: \.word)?.key
                    if input.allowsContentDeletions, core.count > 1, removed.contains(",") {
                        if core.first == leftWord || core.first == rightWord { core.removeFirst() }
                        if core.count > 1, core.last == rightWord || core.last == leftWord { core.removeLast() }
                    }
                    let corePhrase = core.joined(separator: " ")
                    let questionBefore: Set<String> = ["do", "did", "don't", "didn't", "would", "if", "what", "who",
                                                       "how", "let", "as", "where", "when", "why", "whether", "so",
                                                       "everything", "all", "anything", "something", "nothing", "than",
                                                       "that", "because", "people", "things", "everyone", "someone"]
                    // A trailing "you know" ends the utterance as a filler unless it is part of a question.
                    let trailingYouKnow = phrase == "you know" && a == s.count && !questionBefore.contains(leftWord ?? "")
                    if sw.allSatisfy({ englishFillers.contains($0) })
                        || (["like", "you know", "i mean"].contains(phrase) && pausedLeft && pausedRight)
                        || (core != sw && ["like", "you know", "i mean"].contains(corePhrase))
                        || trailingYouKnow {
                        kind = .fillerDeletion; accept = true
                    } else if input.allowsContentDeletions && sw.count == 1, !["that", "had", "is", "so"].contains(sw[0]),
                              !sw[0].contains(where: \.isNumber), s[si..<a].first(where: \.word)?.text.first?.isUppercase != true,
                              (s[..<si].last(where: \.word)?.key == sw[0] || s[a...].first(where: \.word)?.key == sw[0]) {
                        kind = .repetitionDeletion; accept = true
                    } else if input.allowsContentDeletions && adjacentEnglishRepeat(s, from: si, to: a) {
                        kind = .repetitionDeletion; accept = true
                    } else if input.allowsContentDeletions && input.verifiedRetractions.contains(removed) {
                        kind = .retractionDeletion; accept = true
                    }
                } else if input.dictionary.contains(where: { entry in
                    inserted.trimmingCharacters(in: .whitespacesAndNewlines) == entry.surface
                        && entry.readings.contains { $0.lowercased() == removed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                }) { kind = .dictionarySurface; accept = true }
                if accept { result.text += inserted; result.accepted[kind, default: 0] += 1 }
                else {
                    result.text += removed
                    result.rejected[kind, default: 0] += 1
                }
            }
            if a < s.count {
                // A case change inside a written token ("report.pdf" → "report.Pdf") is not taken.
                let attached = a > 0 && !s[a - 1].word && !s[a - 1].text.allSatisfy(\.isWhitespace)
                    && a - 1 > 0 && s[a - 2].word
                // An opening quote or a colon also starts a sentence (he said, "Well, ...").
                let sentenceStart = !s[..<a].contains(where: \.word)
                    || s[..<a].last(where: { !$0.text.allSatisfy(\.isWhitespace) }).map { ".!?:\"“".contains($0.text) } == true
                // Mid-sentence capitals are taken for names, not for common words ("Oh, Actually").
                let dictionaryWord = input.dictionary.contains { englishTokens($0.surface).contains { $0.word && $0.key == s[a].key } }
                // Only a Title-case raise of a common word is refused ("Actually"); "IT", "OK", "A" are kept.
                let titled = o[b].text.count >= 2 && o[b].text.first?.isUppercase == true
                    && o[b].text.dropFirst().allSatisfy { !$0.isUppercase }
                let raisesCase = titled && zip(s[a].text, o[b].text).contains { $0.isLowercase && $1.isUppercase }
                let commonWord = Self.englishCommonLowercase.contains(s[a].key)
                if s[a].text != o[b].text && !attached && (!raisesCase || sentenceStart || !commonWord || dictionaryWord) {
                    result.text += o[b].text
                    result.accepted[.caseChange, default: 0] += 1
                } else {
                    result.text += s[a].text
                }
            }
            si = a + 1; oi = b + 1
        }
        return result
    }
}
