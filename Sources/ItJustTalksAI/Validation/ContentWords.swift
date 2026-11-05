import Foundation
import NaturalLanguage

/// Content-word extraction for the overlap check (ADD-04), using `NLTokenizer`.
///
/// A token counts as a content word when it contains kanji, katakana, Latin letters or digits and is not a
/// short/stop word. Hiragana-only tokens (particles, auxiliaries, fillers such as えーと) are ignored.
enum ContentWords {
    private static let englishStopWords: Set<String> = [
        "the", "and", "for", "but", "you", "your", "are", "was", "were", "this", "that", "with", "have",
        "has", "had", "from", "they", "them", "their", "there", "then", "than", "will", "would", "could",
        "should", "can", "about", "into", "just", "like", "what", "when", "which", "who", "how", "its", "it's",
        "our", "out", "all", "any", "also", "been", "being", "did", "does", "doing", "very", "really", "some",
        "so", "um", "uh", "hmm", "well", "okay", "yeah",
    ]
    /// Spelled-out numbers fold to digits so "3" ↔ "three" is not counted as a lost/new word
    /// (number changes are checked separately by `NumberExtractor`).
    private static let englishNumberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
        "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18",
        "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60",
        "seventy": "70", "eighty": "80", "ninety": "90",
    ]

    /// Informal contractions fold to the word a cleanup typically writes ("gonna" → "going").
    private static let englishContractions: [String: String] = [
        "gonna": "going", "wanna": "want", "gotta": "got", "kinda": "kind", "sorta": "sort", "lemme": "let",
        "gimme": "give", "dunno": "know", "outta": "out", "lotta": "lot",
    ]

    static func extract(from text: String) -> Set<String> {
        Set(extractInOrder(from: text))
    }

    static func extractInOrder(from text: String) -> [String] {
        let normalized = normalize(NumberExtractor.replacingNumerals(in: text))
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        var words: [String] = []
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            var token = String(normalized[range])
            if let digits = englishNumberWords[token] { token = digits }
            if let expanded = englishContractions[token] { token = expanded }
            if isContentWord(token) { words.append(token) }
            return true
        }
        return words
    }

    /// NFKC + lowercase; katakana-hiragana are kept distinct on purpose (katakana marks loanwords/names).
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }

    static func isContentWord(_ token: String) -> Bool {
        var hasKanji = false
        var hasKatakana = false
        var hasLatin = false
        var hasDigit = false
        for scalar in token.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005: hasKanji = true
            case 0x30A1...0x30FA, 0x31F0...0x31FF: hasKatakana = true
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: hasLatin = true
            case 0x30...0x39: hasDigit = true
            default: break
            }
        }
        if hasKanji || hasKatakana || hasDigit { return true }
        if hasLatin {
            return token.count >= 3 && !englishStopWords.contains(token)
        }
        return false
    }

    // MARK: - Readings (kana ↔ kanji spelling changes are not new content)

    /// Word tokens of `text` (normalized like `extract`) with their in-context Latin transcription from the
    /// system tokenizer ("会議室" → 会議=kaigi, 室=shitsu; "かいぎしつ" → かいぎ=kaigi, しつ=shitsu).
    static func readingTokens(_ text: String) -> [(surface: String, reading: String)] {
        let normalized = normalize(NumberExtractor.replacingNumerals(in: text))
        let string = normalized as NSString
        let cfString = normalized as CFString
        guard let tokenizer = CFStringTokenizerCreate(
            nil, cfString, CFRangeMake(0, CFStringGetLength(cfString)), kCFStringTokenizerUnitWord,
            Locale(identifier: "ja") as CFLocale
        ) else { return [] }
        var tokens: [(String, String)] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let surface = string.substring(with: NSRange(location: range.location, length: range.length))
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            tokens.append((surface, (latin ?? surface).lowercased().filter { !$0.isWhitespace }))
        }
        return tokens
    }

    private static func isJapaneseContent(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x30A1...0x30FA).contains($0.value) || $0.value == 0x3005
        }
    }

    /// Surfaces of Japanese tokens in `text` whose in-context reading equals a run of whole consecutive token
    /// readings in `other` (token-aligned, so "asu" never matches inside "arimasu").
    static func readingLicensedSurfaces(of text: String, against other: String) -> Set<String> {
        let otherReadings = readingTokens(other).map(\.reading).filter { !$0.isEmpty }
        var result = Set<String>()
        for token in readingTokens(text) where isJapaneseContent(token.surface) {
            let reading = token.reading
            guard reading.filter(\.isLetter).count >= 2 else { continue }
            if alignedContains(otherReadings, reading) { result.insert(token.surface) }
        }
        return result
    }

    /// Japanese tokens of `text` with a reading of at least 3 letters (particles excluded), and how many of
    /// them have no token-aligned reading in `source`. Used where content words cannot see the change:
    /// hiragana-only answers such as "ありがとう" → "どういたしまして".
    /// `phoneticEvidence`: the source without retracted speech; a katakana rendering of whole hiragana words
    /// in it is not new (てんぷれーと → テンプレート).
    static func longKanaTokens(of text: String, against source: String, phoneticEvidence: String? = nil) -> (total: Int, new: Int) {
        let sourceReadings = readingTokens(source).map(\.reading).filter { !$0.isEmpty }
        let tokens = readingTokens(text)
        let spokenInHiragana = PhoneticReading.wordsSpokenInHiragana(
            Set(tokens.map(\.surface).filter(PhoneticReading.isKatakanaWord)), source: phoneticEvidence ?? source
        )
        var total = 0
        var new = 0
        for token in tokens {
            let japanese = token.surface.unicodeScalars.contains {
                (0x3041...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
            }
            guard japanese, token.reading.filter(\.isLetter).count >= 3 else { continue }
            total += 1
            if !alignedContains(sourceReadings, token.reading), !spokenInHiragana.contains(token.surface) { new += 1 }
        }
        return (total, new)
    }

    private static func alignedContains(_ readings: [String], _ reading: String) -> Bool {
        for i in readings.indices {
            var joined = ""
            for j in i..<readings.count {
                joined += readings[j]
                if joined == reading { return true }
                if joined.count >= reading.count || !reading.hasPrefix(joined) { break }
            }
        }
        return false
    }

    /// True when `word` can be written entirely as a concatenation of reading-licensed surfaces.
    static func isSpelled(_ word: String, byAnyOf surfaces: Set<String>) -> Bool {
        guard !word.isEmpty, !surfaces.isEmpty else { return false }
        let chars = Array(word)
        var reachable = [Bool](repeating: false, count: chars.count + 1)
        reachable[0] = true
        for i in 0..<chars.count where reachable[i] {
            for surface in surfaces {
                let s = Array(surface)
                if i + s.count <= chars.count, Array(chars[i..<(i + s.count)]) == s { reachable[i + s.count] = true }
            }
        }
        return reachable[chars.count]
    }
}
