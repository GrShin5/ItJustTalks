import Foundation

/// One numeric value found in a text, in order of appearance.
///
/// `value` is a canonical decimal string ("1500", "3.5", "-5"). A numeral run that cannot be parsed safely
/// (e.g. "1.2.3") is kept verbatim as `"?<run>"`, so it only matches the identical run in the source
/// (fail-closed: never silently dropped). `offset` / `end` are character offsets in the extractor's
/// normalized text (see `NumberExtractor.Analysis.text`). `unit` is the text right after the number
/// (first character, or the next English word), used to pair a retracted value with its correction.
struct NumberToken: Hashable, Sendable {
    var value: String
    var offset: Int
    var end: Int
    var unit: String
}

/// Extracts numeric values after normalizing full-width/other-script digits, digit-group commas, kanji
/// numerals (incl. 十/百/千/万/億/兆, decimals such as 1.5万 and digit-by-digit forms such as 二〇二六),
/// signs (-, −, マイナス, ▲, minus), hiragana counters (ふたつ, はつか) and English number words
/// (with hundred/thousand/million, ordinals and month names).
///
/// Values are canonical decimal strings so "千五百", "1,500" and "１５００" compare equal.
enum NumberExtractor {
    struct Analysis {
        /// Normalized text the offsets refer to.
        var text: [Character]
        var tokens: [NumberToken]
    }

    private static let kanjiDigits: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let smallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    private static let largeUnits: [Character: Decimal] = [
        "万": 10_000, "億": 100_000_000, "兆": Decimal(string: "1000000000000")!,
    ]
    /// Rare / variant numeral characters folded to the common form before parsing.
    private static let numeralVariants: [Character: String] = [
        "两": "二", "兩": "二", "廿": "二十", "卅": "三十", "○": "〇", "壱": "一", "弐": "二", "萬": "万",
    ]
    /// Characters that mark the following number as negative (after `マイナス` etc. are folded to "−").
    private static let minusSign: Character = "−"

    /// Words containing kanji numerals that usually are not quantities. Removed from the *output* side only,
    /// and only when no numeral is directly adjacent (so 二十分 / 十分の一 keep their numbers).
    static let idiomExclusions: [String] = [
        "一緒", "一応", "一方", "一般", "統一", "唯一", "同一", "一生懸命", "万が一", "万一", "一旦", "一気",
        "一層", "一切", "一体", "一致", "一流", "一瞬", "一言", "一部始終", "一石二鳥", "千差万別",
        "万全", "万能", "一時的", "一向",
    ]
    /// "十分" is ignored on the output side only when clearly used as "enough" (十分に / 十分な / 十分注意 …).
    /// Anything else (十分後, 3時十分, 十分です …) is treated as 10 minutes (fail-closed).
    private static let juubunIdiomFollowers: [String] = [
        "に", "な", "注意", "理解", "検討", "準備", "確認", "気を", "過ぎ", "すぎ", "可能", "足り", "満足", "承知",
    ]
    /// Text right before "十分" that makes it a time/duration (3時十分に, 約十分, あと十分).
    private static let juubunQuantityPreceders: [String] = ["時", "約", "各", "毎", "あと", "残り", "およそ", "ほぼ", "最大", "最低"]

    /// Hiragana numerals that are unambiguous as whole words.
    private static let hiraganaNumerals: [(String, Int)] = [
        ("ここのつ", 9), ("ひとつ", 1), ("ふたつ", 2), ("みっつ", 3), ("よっつ", 4), ("いつつ", 5), ("むっつ", 6),
        ("ななつ", 7), ("やっつ", 8), ("ついたち", 1), ("ふつか", 2), ("みっか", 3), ("よっか", 4), ("むいか", 6),
        ("ここのか", 9), ("とおか", 10), ("はつか", 20),
    ]

    private static let englishUnits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let englishTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let englishOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90, "hundredth": 100, "thousandth": 1000,
    ]
    private static let englishMultipliers: [String: Decimal] = [
        "hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
        "trillion": Decimal(string: "1000000000000")!, "dozen": 12,
    ]
    /// Month names always count; ambiguous ones ("may", abbreviations) only next to a number.
    private static let englishMonths: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "june": 6, "july": 7, "august": 8,
        "september": 9, "october": 10, "november": 11, "december": 12,
    ]
    private static let englishMonthsNearNumberOnly: [String: Int] = [
        "may": 5, "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9,
        "oct": 10, "nov": 11, "dec": 12,
    ]
    /// Standalone "one" after these words is a pronoun ("which one"), ignored on the output side only.
    private static let pronounOneDeterminers: Set<String> = ["the", "this", "that", "each", "which", "no"]

    // MARK: - API

    static func numbers(in text: String, excludingIdioms: Bool) -> Set<String> {
        Set(analyze(text, excludingIdioms: excludingIdioms).tokens.map(\.value))
    }

    static func sequence(in text: String, excludingIdioms: Bool) -> [String] {
        analyze(text, excludingIdioms: excludingIdioms).tokens.map(\.value)
    }

    static func analyze(_ text: String, excludingIdioms: Bool) -> Analysis {
        var chars = Array(normalize(text))
        if excludingIdioms { chars = blankingIdioms(chars) }
        var tokens = numeralTokens(in: chars)
        tokens = englishTokens(in: chars, digitTokens: tokens, skipPronounOne: excludingIdioms)
        tokens.sort { $0.offset < $1.offset }
        return Analysis(text: chars, tokens: tokens)
    }

    /// Bare ambiguous month spellings are only evidence for an extracted source month of the same name.
    static func bareCapitalizedMonths(in analysis: Analysis) -> [String] {
        let covered = Set(analysis.tokens.map(\.offset))
        let words = englishWords(in: analysis.text)
        return words.indices.compactMap { index in
            let word = words[index]
            guard englishMonthsNearNumberOnly[word.text] != nil, analysis.text[word.offset].isUppercase,
                  !covered.contains(word.offset) else { return nil }
            if word.text == "may", index + 1 < words.count,
               onlySpaces(analysis.text, word.end, words[index + 1].offset) {
                // A modal followed by a pronoun/verb must never stand in for the number five.
                let pronouns: Set<String> = ["i", "we", "you", "he", "she", "it", "they", "one"]
                let datePrepositions: Set<String> = ["on", "in", "by", "until", "during", "for", "of", "before", "after", "through"]
                guard !pronouns.contains(words[index + 1].text), index > 0,
                      datePrepositions.contains(words[index - 1].text),
                      onlySpaces(analysis.text, words[index - 1].end, word.offset) else { return nil }
            }
            return word.text
        }
    }

    static func ambiguousMonthName(_ token: NumberToken, in analysis: Analysis) -> String? {
        let word = String(analysis.text[token.offset..<token.end]).lowercased()
        return englishMonthsNearNumberOnly[word] != nil ? word : nil
    }

    /// Text with every numeral run replaced by its canonical value ("千五百" → "1500", "1,500" → "1500"),
    /// so the overlap check does not treat a numeral-format change as lost content.
    static func replacingNumerals(in text: String) -> String {
        let chars = Array(normalize(text))
        var result = ""
        var cursor = 0
        for token in numeralTokens(in: chars) where !token.value.hasPrefix("?") {
            guard token.offset >= cursor else { continue }
            result += String(chars[cursor..<token.offset])
            result += token.value.hasPrefix("-") ? String(token.value.dropFirst()) : token.value
            cursor = token.end
        }
        result += String(chars[cursor...])
        return result
    }

    // MARK: - Normalization

    /// NFKC, other-script decimal digits → ASCII, numeral variants, sign words → "−", digit-group commas removed.
    static func normalize(_ text: String) -> String {
        var out = ""
        for c in text.precomposedStringWithCompatibilityMapping {
            if let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1,
               scalar.properties.numericType == .decimal, let digit = c.wholeNumberValue, !c.isASCII {
                out += String(digit)
            } else if let variant = numeralVariants[c] {
                out += variant
            } else if c == "▲" || c == "△" || c == "−" {
                out.append(minusSign)
            } else {
                out.append(c)
            }
        }
        out = out.replacingOccurrences(of: "マイナス\\s*", with: String(minusSign), options: .regularExpression)
        out = out.replacingOccurrences(of: "(氷点下|零下)\\s*", with: String(minusSign), options: .regularExpression)
        for (word, value) in hiraganaNumerals {
            out = out.replacingOccurrences(of: word, with: String(value))
        }
        // Ambiguous readings need date/quantity evidence, never a substring of "必要なのか".
        out = out.replacingOccurrences(of: #"(?:(?<=[0-9〇一二三四五六七八九十]月)|(?<=日付は)|(?<=日付が)|(?<=日付を)|(?<![\p{L}]))なのか(?=$|[にのはが、。\s])"#,
            with: "7日", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<![ぁ-ゖ])なな(?=[個本枚人冊回時分秒円日月歳台件])"#,
            with: "7", options: .regularExpression)
        return removeDigitGroupCommas(out)
    }

    /// "1,500" → "1500" (only commas between a digit and exactly three digits).
    private static func removeDigitGroupCommas(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?<=\\d),(?=\\d{3}(?!\\d))") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func isNumeralCharacter(_ c: Character) -> Bool {
        (c.isASCII && c.isNumber) || kanjiDigits[c] != nil || smallUnits[c] != nil || largeUnits[c] != nil
    }

    private static func isASCIIDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    private static func blankingIdioms(_ chars: [Character]) -> [Character] {
        var result = chars
        let text = chars
        for idiom in idiomExclusions + ["十分"] {
            let pattern = Array(idiom)
            var i = 0
            while i + pattern.count <= text.count {
                guard Array(text[i..<(i + pattern.count)]) == pattern else { i += 1; continue }
                let before = i > 0 ? text[i - 1] : nil
                let afterIndex = i + pattern.count
                let after = afterIndex < text.count ? text[afterIndex] : nil
                var isIdiom = !(before.map(isNumeralCharacter) ?? false) && !(after.map(isNumeralCharacter) ?? false)
                    && before != "." && before != minusSign
                if isIdiom, idiom == "十分" {
                    let rest = String(text[afterIndex..<min(text.count, afterIndex + 3)])
                    let head = String(text[max(0, i - 3)..<i])
                    isIdiom = juubunIdiomFollowers.contains { rest.hasPrefix($0) }
                        && !juubunQuantityPreceders.contains { head.hasSuffix($0) }
                }
                if isIdiom {
                    for k in i..<afterIndex { result[k] = " " }
                }
                i += pattern.count
            }
        }
        return result
    }

    // MARK: - Numeral runs (arabic / kanji)

    private static func numeralTokens(in chars: [Character]) -> [NumberToken] {
        var tokens: [NumberToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let startsLeadingDot = c == "." && i + 1 < chars.count && isASCIIDigit(chars[i + 1])
                && (i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "."))
            guard isNumeralCharacter(c) || startsLeadingDot else { i += 1; continue }
            let start = i
            var run: [Character] = []
            while i < chars.count {
                let ch = chars[i]
                if isNumeralCharacter(ch) {
                    run.append(ch)
                } else if ch == ".", i + 1 < chars.count, isASCIIDigit(chars[i + 1]),
                          run.isEmpty || run.last!.isASCII {
                    run.append(ch)
                } else {
                    break
                }
                i += 1
            }
            // A run made only of large units ("万" alone) is not a number.
            if run.allSatisfy({ largeUnits[$0] != nil }) { continue }
            // Decimal has bounded precision. Preserve oversized runs verbatim rather than rounding facts.
            let digits = run.filter { isASCIIDigit($0) || kanjiDigits[$0] != nil }.count
            let scale = run.contains("兆") ? 12 : run.contains("億") ? 8 : run.contains("万") ? 4
                : run.contains("千") ? 3 : run.contains("百") ? 2 : run.contains("十") ? 1 : 0
            let oversized = digits + scale > 38
                || (run.firstIndex(of: ".").map { run.count - $0 - 1 > 127 } ?? false)
            var value = oversized ? "?" + String(run) : (parseRun(run).map(canonical) ?? "?" + String(run))
            if isNegative(chars, runStart: start), value != "0" { value = "-" + value }
            tokens.append(NumberToken(value: value, offset: start, end: i, unit: unit(after: i, in: chars)))
        }
        return tokens
    }

    /// "−5", "マイナス5" (folded to "−"), and "-5" when the hyphen is not between alphanumerics ("10-15", "A-5").
    private static func isNegative(_ chars: [Character], runStart: Int) -> Bool {
        var j = runStart - 1
        while j >= 0, chars[j] == " " { j -= 1 }
        guard j >= 0 else { return false }
        if chars[j] == minusSign { return true }
        if chars[j] == "-", j == runStart - 1 {
            let before = j > 0 ? chars[j - 1] : nil
            // "A-5", "10-15", "--5" are not signs; "は-5度" / " -5" are.
            return !(before.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } ?? false)
        }
        return false
    }

    static func parseRun(_ run: [Character]) -> Decimal? {
        var total = Decimal(0)
        var section = Decimal(0)
        var current = Decimal(0)
        var hasCurrent = false
        var fractionScale: Decimal?
        var sawDot = false
        for c in run {
            let digit: Int? = isASCIIDigit(c) ? c.wholeNumberValue : kanjiDigits[c]
            if let d = digit {
                if let scale = fractionScale {
                    current += Decimal(d) * scale
                    fractionScale = scale / 10
                } else {
                    current = current * 10 + Decimal(d)
                }
                hasCurrent = true
            } else if c == "." {
                // Two decimal points ("1.2.3": versions, IP addresses) cannot be read safely.
                if sawDot { return nil }
                sawDot = true
                fractionScale = Decimal(string: "0.1")!
                hasCurrent = true
            } else if let unit = smallUnits[c] {
                section += (hasCurrent ? current : 1) * Decimal(unit)
                current = 0
                hasCurrent = false
                fractionScale = nil
            } else if let unit = largeUnits[c] {
                let block = section + (hasCurrent ? current : 0)
                total += (block == 0 ? 1 : block) * unit
                section = 0
                current = 0
                hasCurrent = false
                fractionScale = nil
            } else {
                return nil
            }
        }
        return total + section + current
    }

    private static func canonical(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// First character after the number, or the next English word (singularized) when separated by a space.
    private static func unit(after index: Int, in chars: [Character]) -> String {
        var j = index
        while j < chars.count, chars[j] == " " { j += 1 }
        guard j < chars.count else { return "" }
        if chars[j].isASCII, chars[j].isLetter {
            var word = ""
            while j < chars.count, chars[j].isASCII, chars[j].isLetter { word.append(chars[j]); j += 1 }
            word = word.lowercased()
            if word.count > 3, word.hasSuffix("s") { word.removeLast() }
            return word
        }
        return String(chars[j])
    }

    // MARK: - English number words

    private struct Word {
        var text: String
        var offset: Int
        var end: Int
    }

    private static func englishWords(in chars: [Character]) -> [Word] {
        var words: [Word] = []
        var i = 0
        while i < chars.count {
            if chars[i].isASCII, chars[i].isLetter {
                let start = i
                var text = ""
                while i < chars.count, chars[i].isASCII, chars[i].isLetter { text.append(chars[i]); i += 1 }
                words.append(Word(text: text.lowercased(), offset: start, end: i))
            } else {
                i += 1
            }
        }
        return words
    }

    /// True when only spaces or a single hyphen separate the two positions (so "twenty-five", "five hundred").
    private static func joined(_ chars: [Character], from: Int, to: Int) -> Bool {
        guard from <= to else { return false }
        let gap = chars[from..<to]
        return gap.allSatisfy { $0 == " " || $0 == "-" } && gap.filter({ $0 == "-" }).count <= 1
    }

    private static func isNumberWord(_ w: String) -> Bool {
        englishUnits[w] != nil || englishTens[w] != nil || englishMultipliers[w] != nil || englishOrdinals[w] != nil
    }

    private static func onlySpaces(_ chars: [Character], _ from: Int, _ to: Int) -> Bool {
        from <= to && chars[from..<to].allSatisfy { $0 == " " }
    }

    private static func englishTokens(in chars: [Character], digitTokens: [NumberToken], skipPronounOne: Bool) -> [NumberToken] {
        var tokens = digitTokens
        let words = englishWords(in: chars)
        var mergedDigitTokens = Set<Int>()

        func nearNumber(_ k: Int) -> Bool {
            let w = words[k]
            if k > 0, isNumberWord(words[k - 1].text), joined(chars, from: words[k - 1].end, to: w.offset) { return true }
            if k + 1 < words.count, isNumberWord(words[k + 1].text), joined(chars, from: w.end, to: words[k + 1].offset) {
                return true
            }
            return tokens.contains {
                ($0.end <= w.offset && chars[$0.end..<w.offset].allSatisfy { $0 == " " || $0 == "," })
                    || ($0.offset >= w.end && onlySpaces(chars, w.end, $0.offset))
            }
        }

        var k = 0
        while k < words.count {
            let word = words[k].text
            let month = englishMonths[word] ?? (nearNumber(k) ? englishMonthsNearNumberOnly[word] : nil)
            if let month {
                tokens.append(NumberToken(value: String(month), offset: words[k].offset, end: words[k].end,
                                          unit: unit(after: words[k].end, in: chars)))
                k += 1
                continue
            }
            // "5 million", "1.5 thousand": a digit run directly followed by a multiplier word.
            if let multiplier = englishMultipliers[word], word != "dozen",
               let idx = tokens.firstIndex(where: { !$0.value.hasPrefix("?") && $0.end <= words[k].offset
                   && onlySpaces(chars, $0.end, words[k].offset) }),
               !mergedDigitTokens.contains(idx),
               let base = Decimal(string: tokens[idx].value, locale: Locale(identifier: "en_US_POSIX")) {
                tokens[idx] = NumberToken(value: canonical(base * multiplier), offset: tokens[idx].offset,
                                          end: words[k].end, unit: unit(after: words[k].end, in: chars))
                mergedDigitTokens.insert(idx)
                k += 1
                continue
            }
            let startsWithArticle = (word == "a" || word == "an") && k + 1 < words.count
                && englishMultipliers[words[k + 1].text] != nil && joined(chars, from: words[k].end, to: words[k + 1].offset)
            guard isNumberWord(word) || startsWithArticle else { k += 1; continue }
            let followedByNumberWord = k + 1 < words.count && isNumberWord(words[k + 1].text)
                && joined(chars, from: words[k].end, to: words[k + 1].offset)
            if word == "one", skipPronounOne, k > 0, pronounOneDeterminers.contains(words[k - 1].text), !followedByNumberWord {
                k += 1
                continue
            }

            // Parse one number phrase starting at word k.
            let start = words[k].offset
            var end = words[k].end
            var total = Decimal(0)
            var current = Decimal(0)
            var hasValue = false
            var previousEnd: Int?
            var j = k
            if startsWithArticle {
                current = 1
                previousEnd = words[k].end
                j = k + 1
            }
            phrase: while j < words.count {
                if let previousEnd {
                    // "one hundred and five"
                    if words[j].text == "and", hasValue, current >= 100 || total > 0, j + 1 < words.count,
                       isNumberWord(words[j + 1].text), joined(chars, from: previousEnd, to: words[j].offset),
                       joined(chars, from: words[j].end, to: words[j + 1].offset) {
                        j += 1
                    } else if !joined(chars, from: previousEnd, to: words[j].offset) {
                        break phrase
                    }
                }
                let w = words[j].text
                let remainder = NSDecimalNumber(decimal: current).intValue % 100
                let unitSlotFree = remainder == 0 || (remainder >= 20 && remainder % 10 == 0)
                var finishes = false
                if let v = englishUnits[w] {
                    guard !hasValue || (v < 10 ? unitSlotFree : remainder == 0) else { break phrase }
                    current += Decimal(v)
                } else if let v = englishTens[w] {
                    guard !hasValue || remainder == 0 else { break phrase }
                    current += Decimal(v)
                } else if let v = englishOrdinals[w] {
                    if v >= 100 {
                        current = (current == 0 ? 1 : current) * Decimal(v)
                    } else {
                        guard !hasValue || (v < 10 ? unitSlotFree : remainder == 0) else { break phrase }
                        current += Decimal(v)
                    }
                    finishes = true
                } else if let m = englishMultipliers[w] {
                    if m == 100 || m == 12 {
                        current = (current == 0 ? 1 : current) * m
                    } else {
                        total += (current == 0 ? 1 : current) * m
                        current = 0
                    }
                } else {
                    break phrase
                }
                hasValue = true
                end = words[j].end
                previousEnd = words[j].end
                j += 1
                if finishes { break phrase }
            }
            if hasValue {
                var value = canonical(total + current)
                if k > 0, ["minus", "negative"].contains(words[k - 1].text), value != "0" { value = "-" + value }
                tokens.append(NumberToken(value: value, offset: start, end: end, unit: unit(after: end, in: chars)))
            }
            k = max(j, k + 1)
        }
        return tokens
    }
}
