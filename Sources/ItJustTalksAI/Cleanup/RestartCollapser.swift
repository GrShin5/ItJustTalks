import Foundation

/// Narrow, deterministic removal of adjacent cue-less false starts. Never logs user text.
enum RestartCollapser {
    private struct Unit {
        var text: String
        var range: Range<String.Index>
        var cjk: Bool
        var lexical: Bool
        var pause: Bool
    }

    static func collapse(_ transcript: String) -> String {
        var text = transcript
        // Restart from the left after each removal: a run can contain several abandoned starts.
        while let range = abandonedRange(in: text) {
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let capitalized = text[range.lowerBound].isUppercase && isSentenceStart(text, at: range.lowerBound)
            text.removeSubrange(range)
            // Carry the removed sentence-initial capital to the kept restart ("Please …, please …").
            let kept = text.index(text.startIndex, offsetBy: offset)
            if capitalized, kept < text.endIndex, text[kept].isLowercase {
                text.replaceSubrange(kept...kept, with: String(text[kept]).uppercased())
            }
        }
        return text
    }

    private static func isSentenceStart(_ text: String, at index: String.Index) -> Bool {
        var i = index
        while i > text.startIndex {
            i = text.index(before: i)
            let character = text[i]
            if character.isNewline { return true }
            if character.isWhitespace { continue }
            return ".!?。．！？".contains(character)
        }
        return true
    }

    private static func abandonedRange(in text: String) -> Range<String.Index>? {
        let units = tokenize(text)
        guard units.count >= 6 else { return nil }
        // Link equal units so ordinary non-repeating text does not require an all-pairs scan.
        var next = [Int?](repeating: nil, count: units.count)
        var last: [String: Int] = [:]
        for i in units.indices.reversed() {
            next[i] = last[units[i].text]
            last[units[i].text] = i
        }
        // Sentence boundaries before each unit (prefix counts over the original text, including skipped
        // whitespace), so the boundary check below is O(1) per candidate pair.
        var boundariesBefore = [Int](repeating: 0, count: units.count)
        var boundaryCount = 0
        var cursor = text.startIndex
        for (k, unit) in units.enumerated() {
            for character in text[cursor..<unit.range.lowerBound]
            where character.isNewline || "。．.！？!?".contains(character) { boundaryCount += 1 }
            boundariesBefore[k] = boundaryCount
            cursor = unit.range.lowerBound
        }
        var start = 0
        while start < units.count {
            guard units[start].lexical else { start += 1; continue }
            var candidate = next[start]
            var protectedEnd = start + 1
            while let second = candidate {
                // A restart repeats a nearby phrase; bounding the distance keeps long or highly
                // repetitive transcripts linear (candidates are in increasing order).
                guard second - start <= maxRestartSpan else { break }
                candidate = next[second]
                // A completed sentence is never a cue-less false start. Use original text so skipped
                // whitespace (including newlines) also protects the boundary.
                if boundariesBefore[second] != boundariesBefore[start] { break }
                var length = 0
                while start + length < second, second + length < units.count,
                      units[start + length].lexical, units[second + length].lexical,
                      units[start + length].text == units[second + length].text {
                    length += 1
                }
                // Reject a non-maximal X before applying any exclusions to X or Y. The first
                // abandoned unit belongs to X if it also follows the second X (grapheme/word).
                if start + length < second, second + length < units.count,
                   units[start + length].lexical,
                   units[start + length].text == units[second + length].text {
                    continue
                }
                // Likewise reject an X that could extend to the left: the earlier start already
                // tried the longer phrase, and this shifted one would swallow its first unit into Y.
                if start > 0, units[start - 1].lexical, units[second - 1].lexical,
                   units[start - 1].text == units[second - 1].text {
                    continue
                }
                let phrase = units[start..<(start + length)]
                let cjk = phrase.contains { $0.cjk }
                let graphemes = phrase.reduce(0) { $0 + $1.text.count }
                guard (cjk ? graphemes >= 5 : length >= 3) else { continue }
                // Use the longest common prefix only; shortening it could hide a connector in Y.
                let x = phrase.map(\.text).joined()
                let originalX = String(text[units[start].range.lowerBound..<units[start + length - 1].range.upperBound])
                // Idiomatic numeral words (一度, 一緒, 一人で …) are not amounts; every other numeral is protected.
                if (cjk && graphemes <= 6 && isHiragana(x))
                    || maskingNumeralIdioms(x).unicodeScalars.contains(where: { $0.properties.numericType != nil })
                    || !NumberExtractor.sequence(in: maskingNumeralIdioms(originalX), excludingIdioms: true).isEmpty {
                    // Do not retry a suffix of a protected phrase (e.g. after its numeral).
                    protectedEnd = start + length
                    break
                }
                // Strip pause punctuation and fillers between the abandoned tail Y and the restart.
                var end = second
                var sawFiller = false
                while end > start + length {
                    if units[end - 1].pause {
                        end -= 1
                    } else if let count = fillerLength(units, endingAt: end, lowerBound: start + length, restart: second) {
                        end -= count
                        sawFiller = true
                    } else {
                        break
                    }
                }
                let trailing = units[(start + length)..<end]
                guard trailing.allSatisfy({ $0.lexical }) else { continue }
                let y = trailing.map(\.text).joined()
                if cjk, end == second, !sawFiller,
                   ["た", "だ", "ます", "ました", "です", "ない", "ません"].contains(where: { (x + y).hasSuffix($0) }),
                   differentSpeechAct(fragment: x + y, restarted: text[units[second].range.lowerBound...]) {
                    continue
                }
                // A soft pause alone does not retract a completed clause, even if the
                // second clause extends its entire prefix (確認します→確認しますので).
                if cjk {
                    let fragment = x + y
                    if ["った", "します", "ません"].contains(where: { fragment.hasSuffix($0) }) { continue }
                    if !sawFiller, ["ます", "です", "でした", "ました", "ない"]
                        .contains(where: { fragment.hasSuffix($0) }) { continue }
                }
                guard !connectors.contains(y),
                      !trailing.contains(where: { ["not", "never", "no"].contains($0.text) }) else { continue }
                // A conjunction belongs to the completed first clause, never to a false start.
                if cjk, ["が", "けど", "けれど", "けれども", "ので", "から", "のに", "し", "たら", "たり",
                          "ず", "ずに", "ない", "なく", "なかった", "ません", "なければ", "なら", "れば"]
                    .contains(where: { y.hasSuffix($0) }) { continue }
                // The second copy must continue past X: an exact repeat (お願いします、お願いします) is
                // emphasis or a list item, not an abandoned start.
                guard second + length < units.count, units[second + length].lexical else { continue }
                let continuation = units[second + length]
                let shortTail = cjk ? y.count <= 2 : trailing.count <= 1
                // A longer Y only when a filler visibly ends the abandoned attempt and Y is a whole
                // verb/auxiliary ending (CJK only). Punctuation alone can separate two complete clauses
                // (署名しました。署名してください). English stays at the one-word tail.
                let longTail = sawFiller && cjk && y.count <= 6
                    && (abandonedEndings.contains(y) || (x.last == "て" && abandonedEndingsAfterTe.contains(y)))
                guard shortTail || longTail else { continue }
                // A non-empty Y must look like an abandoned inflection rather than a
                // different word: CJK kana ending replaced by kana (送った→送って, not 案→名), English word
                // re-used by the restart (the room → the meeting room, not time → money).
                if !y.isEmpty {
                    if cjk {
                        guard isHiragana(y), isHiragana(continuation.text) else { continue }
                    } else {
                        let window = units[(second + length)..<min(units.count, second + length + 3)]
                        guard trailing.allSatisfy({ tail in window.contains { $0.text == tail.text } }) else { continue }
                    }
                }
                return units[start].range.lowerBound..<units[second].range.lowerBound
            }
            start = protectedEnd
        }
        return nil
    }

    private static let maxRestartSpan = 48

    private static func differentSpeechAct(fragment: String, restarted: Substring) -> Bool {
        let clause = String(restarted.prefix { !$0.isNewline && !"。．.！？!?、，,".contains($0) })
        // A predicate modifying a noun is not the act of the later main clause.
        if let relative = clause.range(of: "ている"), relative.upperBound < clause.endIndex {
            return false
        }
        let requests = ["ください", "下さい", "てほしい", "てもらえ", "ましょう"]
        if requests.contains(where: { clause.contains($0) }) || clause.hasSuffix("たい") { return true }
        let negative = ["ない", "ません"].contains(where: { fragment.hasSuffix($0) })
        let restartNegative = clause.contains("ない") || clause.contains("ません")
        return negative != restartNegative
    }

    /// Whole tails (after the common prefix X) that complete an abandoned clause: X ends at a verb stem
    /// (起動し|ました, 確認し|ています). Godan stem kana (送り|ました) and copulas are not included.
    private static let abandonedEndings: Set<String> = [
        "した", "して", "します", "しました", "しまして", "している", "していた", "しています",
        "していました", "ました", "ます", "まして", "ている", "ていた", "ています", "ていました",
        "てた", "てる", "てます", "てました",
    ]
    /// Tails after an X that already ends in the te-form (確認して|います).
    private static let abandonedEndingsAfterTe: Set<String> = ["いる", "いた", "います", "いました", "た", "る", "ます", "ました"]

    /// Fillers allowed between copies. Ambiguous ones (demonstratives, まあ) only when followed by a pause
    /// and not glued to a preceding word.
    private static let fillers: [(units: [String], needsPause: Bool)] = [
        (["え", "ー", "っ", "と"], false), (["え", "ー", "と"], false), (["え", "っ", "と"], false),
        (["あ", "の", "ー"], false), (["え", "ー"], false),
        (["あ", "の"], true), (["そ", "の"], true), (["ま", "あ"], true),
        (["um"], false), (["umm"], false), (["uh"], false), (["uhm"], false),
    ]

    private static func fillerLength(_ units: [Unit], endingAt end: Int, lowerBound: Int, restart: Int) -> Int? {
        for filler in fillers {
            let count = filler.units.count
            let begin = end - count
            guard begin >= lowerBound,
                  zip(units[begin..<end], filler.units).allSatisfy({ $0.text == $1 }) else { continue }
            if filler.needsPause {
                guard end < restart, units[end].pause,
                      begin == lowerBound || !units[begin - 1].lexical else { continue }
            }
            return count
        }
        return nil
    }

    /// Numeral idioms are blanked unless a numeral is adjacent or 一度 has a measurement context.
    /// Bare 一人 is a head count and stays protected.
    private static let numeralIdioms: [[Character]] = (NumberExtractor.idiomExclusions + ["一度", "一人で"])
        .sorted { $0.count > $1.count }.map(Array.init)

    private static func maskingNumeralIdioms(_ text: String) -> String {
        let original = Array(text)
        var chars = original
        func isNumeral(_ character: Character) -> Bool {
            character.unicodeScalars.contains { $0.properties.numericType != nil }
        }
        for idiom in numeralIdioms where idiom.count <= chars.count {
            var i = 0
            while i + idiom.count <= chars.count {
                if Array(chars[i..<(i + idiom.count)]) == idiom,
                   !(i > 0 && isNumeral(chars[i - 1])),
                   !(i + idiom.count < chars.count && isNumeral(chars[i + idiom.count])) {
                    if idiom == Array("一度") {
                        let before = String(original[max(0, i - 4)..<i])
                        let end = i + idiom.count
                        let after = String(original[end..<min(original.count, end + 3)])
                        let measurementBefore = ["零下", "マイナス", "約", "およそ", "摂氏", "華氏", "気温", "室温", "温度", "角度"]
                        let measurementAfter = ["で", "です", "だ", "の", "以上", "以下", "未満", "前後", "くらい", "ぐらい", "程度", "上が", "下が", "上昇", "低下"]
                        if measurementBefore.contains(where: { before.contains($0) })
                            || measurementAfter.contains(where: { after.hasPrefix($0) }) {
                            i += idiom.count
                            continue
                        }
                    }
                    for j in i..<(i + idiom.count) { chars[j] = "□" }
                    i += idiom.count
                } else {
                    i += 1
                }
            }
        }
        return String(chars)
    }

    private static let connectors: Set<String> = [
        "と", "や", "の", "も", "に", "を", "は", "が", "で", "へ", "か", "and", "or", "of", "to"
    ]

    private static func isHiragana(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
                || (0xFF66...0xFF9F).contains($0.value)
        }
    }

    private static func tokenize(_ text: String) -> [Unit] {
        var units: [Unit] = []
        var i = text.startIndex
        while i < text.endIndex {
            let character = text[i]
            let start = i
            i = text.index(after: i)
            if character.isWhitespace { continue }
            let cjk = isCJK(character)
            let lexical = character.isLetter || character.isNumber
            // Space-separated words are atomic: never match inside an English word.
            if lexical && !cjk {
                while i < text.endIndex, !isCJK(text[i]),
                      text[i].isLetter || text[i].isNumber || text[i] == "'" || text[i] == "’" {
                    i = text.index(after: i)
                }
            }
            // Match with Foundation's existing width/case folding convention, retaining original ranges.
            let folded = String(text[start..<i]).folding(options: [.widthInsensitive, .caseInsensitive], locale: nil)
            units.append(Unit(text: folded, range: start..<i, cjk: cjk, lexical: lexical,
                              pause: "。、，,.…".contains(character)))
        }
        return units
    }
}
