import Foundation

/// Romanized sound keys for comparing spellings by how they are read (dictionary selection §5.3 and the
/// cleanup validator). Pure, deterministic and locale-independent; never logs.
///
/// Kana are romanized mora by mora with a fixed Hepburn table, words containing kanji use the system
/// tokenizer's in-context Latin transcription, Latin words are kept as letters. Keys keep vowel length but
/// spell it one way (ー, おう/おお, えい/ええ, doubled vowels and macrons all become "<vowel>:"), so ジェイ /
/// じぇー and 斉藤 / さいとう compare equal while さいとう / サイト and こんどう / 今度 do not.
enum PhoneticReading {
    enum Script: Sendable, Equatable {
        case hiragana, katakana, mixedKana, han, latin
    }

    /// One comparable piece of text: a kana mora, a whole tokenizer word containing kanji, or a Latin word.
    struct Unit: Sendable, Equatable {
        /// Unicode scalar offsets in the analysed string (`end` exclusive).
        var start: Int
        var end: Int
        /// Lower-case ASCII romanization of this unit (not yet long-vowel folded).
        var romaji: [UInt8]
        var script: Script
        /// The unit starts / ends at a tokenizer word boundary (kanji words always do).
        var startsWord: Bool = true
        var endsWord: Bool = true
        /// The tokenizer word starting here is a particle (は, の, を …).
        var startsParticle: Bool = false
        /// A kanji word containing a numeral (三時, 2回): never matched by sound (三時 is not さんじ the name).
        var hasNumeral: Bool = false
    }

    /// Longest key considered anywhere (bytes); longer readings never match by sound.
    static let maxKeyLength = 64

    /// Key and mora count of a whole term (a dictionary reading, an output word).
    struct Key: Sendable, Hashable {
        var key: String
        var morae: Int
    }

    // MARK: - Keys

    /// Sound key of `term` read as a whole (whitespace and punctuation ignored); nil when nothing is readable.
    static func key(of term: String) -> Key? {
        let units = units(term.precomposedStringWithCompatibilityMapping.lowercased())
        guard !units.isEmpty else { return nil }
        var builder = KeyBuilder()
        for unit in units { builder.append(unit.romaji) }
        guard !builder.bytes.isEmpty, builder.bytes.count <= maxKeyLength else { return nil }
        return Key(key: builder.string, morae: moraCount(builder.bytes))
    }

    /// Keys of a dictionary's readings, cached per dictionary version: the selector asks for the same readings
    /// on every request, so the table is rebuilt only when the set of readings changes (keys of readings that
    /// stay are reused).
    static func cachedKeys(of readings: [String]) -> [String: Key] {
        keyCache.keys(for: readings)
    }

    private static let keyCache = KeyCache()

    private final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var version: Set<String> = []
        private var table: [String: Key] = [:]

        func keys(for readings: [String]) -> [String: Key] {
            guard !Task.isCancelled else { return [:] }
            var cancellation = DictionaryCancellationCheckpoint()
            let requested = Set(readings)
            lock.lock()
            if requested == version {
                defer { lock.unlock() }
                return table
            }
            let previous = table
            lock.unlock()
            var rebuilt: [String: Key] = [:]
            for reading in requested {
                guard !cancellation.isCancelled() else { return [:] }
                if let known = previous[reading] {
                    rebuilt[reading] = known
                } else if let computed = PhoneticReading.key(of: reading) {
                    rebuilt[reading] = computed
                }
            }
            guard !Task.isCancelled else { return [:] }
            lock.lock()
            version = requested
            table = rebuilt
            lock.unlock()
            return rebuilt
        }
    }

    /// Calls `body` with the key of every run of adjacent units (`units[i].end == units[i+1].start`) that
    /// starts and ends at a word boundary and whose key length is in `keyLengths` (at most `maxKeyLength`).
    /// `body` gets the key and the first/last unit indices.
    static func forEachSpan(_ units: [Unit], keyLengths: Set<Int>, _ body: (String, Int, Int) -> Void) {
        guard !Task.isCancelled, let longest = keyLengths.max(), longest > 0 else { return }
        var cancellation = DictionaryCancellationCheckpoint()
        let limit = min(longest, maxKeyLength)
        for first in units.indices where units[first].startsWord {
            guard !cancellation.isCancelled() else { return }
            var builder = KeyBuilder()
            var last = first
            while last < units.count {
                if last > first, units[last].start != units[last - 1].end { break }
                builder.append(units[last].romaji)
                if builder.bytes.count > limit { break }
                if units[last].endsWord, keyLengths.contains(builder.bytes.count) { body(builder.string, first, last) }
                last += 1
            }
        }
    }

    // MARK: - Validator support

    /// Output words written in katakana, or short Latin words spelled out letter by letter, whose reading equals
    /// a run of whole hiragana words in `source` (てんぷれーと → テンプレート, えーぴーあい → API). The run must
    /// start and end at tokenizer word boundaries and have at least `minimumMorae` morae. `words` are compared
    /// as given (callers pass normalized content words); `source` should already exclude retracted speech.
    static func wordsSpokenInHiragana(_ words: Set<String>, source: String, minimumMorae: Int = 3) -> Set<String> {
        var candidates: [(word: String, keys: [String])] = []
        var lengths = Set<Int>()
        for word in words {
            var keys: [String] = []
            if isKatakanaWord(word), let key = key(of: word), key.morae >= minimumMorae {
                keys.append(key.key)
            }
            if isLatinWord(word), word.count <= maxAcronymLength, let key = acronymKey(of: word), key.morae >= minimumMorae {
                keys.append(key.key)
            }
            guard !keys.isEmpty else { continue }
            keys.forEach { lengths.insert($0.utf8.count) }
            candidates.append((word, keys))
        }
        guard !candidates.isEmpty else { return [] }
        // Evidence is one word, or words that do not start with a particle (は|あと is not ハート).
        let hiragana = units(source.precomposedStringWithCompatibilityMapping.lowercased())
            .filter { $0.script == .hiragana }
            .map { unit -> Unit in
                var unit = unit
                if unit.startsParticle { unit.startsWord = false }
                return unit
            }
        var spoken = Set<String>()
        forEachSpan(hiragana, keyLengths: lengths) { key, _, _ in spoken.insert(key) }
        return Set(candidates.filter { $0.keys.contains(where: spoken.contains) }.map(\.word))
    }

    static let maxAcronymLength = 6

    /// Key of a Latin word spelled out letter by letter in Japanese (API → えーぴーあい).
    static func acronymKey(of word: String) -> Key? {
        var kana = ""
        for character in word.lowercased() {
            guard let name = letterNames[character] else { return nil }
            kana += name
        }
        return kana.isEmpty ? nil : key(of: kana)
    }

    private static let letterNames: [Character: String] = [
        "a": "えー", "b": "びー", "c": "しー", "d": "でぃー", "e": "いー", "f": "えふ", "g": "じー", "h": "えいち",
        "i": "あい", "j": "じぇー", "k": "けー", "l": "える", "m": "えむ", "n": "えぬ", "o": "おー", "p": "ぴー",
        "q": "きゅー", "r": "あーる", "s": "えす", "t": "てぃー", "u": "ゆー", "v": "ぶい", "w": "だぶりゅー",
        "x": "えっくす", "y": "わい", "z": "ぜっと",
    ]

    static func isKatakanaWord(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy { (0x30A1...0x30FA).contains($0.value) || $0.value == 0x30FC }
    }

    static func isLatinWord(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy { (0x61...0x7A).contains($0.value) || (0x41...0x5A).contains($0.value) }
    }

    // MARK: - Units

    /// Units of `text`, in order. Separators, whitespace and unknown scripts produce no unit (a gap).
    static func units(_ text: String) -> [Unit] {
        guard !Task.isCancelled else { return [] }
        var cancellation = DictionaryCancellationCheckpoint()
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        let words = tokenizerWords(text, scalars: scalars)
        let hanTokens = words.han

        var units: [Unit] = []
        var kana = KanaRun()
        var index = 0
        while index < scalars.count {
            guard !cancellation.isCancelled() else { return [] }
            if let token = hanTokens[index] {
                kana.flush(into: &units)
                let romaji = clean(token.reading)
                if !romaji.isEmpty {
                    var unit = Unit(start: index, end: token.end, romaji: romaji, script: .han)
                    unit.hasNumeral = scalars[index..<token.end].contains(where: isNumeral)
                    units.append(unit)
                }
                index = token.end
                continue
            }
            let scalar = scalars[index]
            if isKana(scalar) {
                kana.add(scalar, at: index, into: &units)
                index += 1
                continue
            }
            kana.flush(into: &units)
            if isLatinOrDigit(scalar) {
                var end = index
                while end < scalars.count, isLatinOrDigit(scalars[end]), end == index || hanTokens[end] == nil {
                    guard !cancellation.isCancelled() else { return [] }
                    end += 1
                }
                var word = ""
                word.unicodeScalars.append(contentsOf: scalars[index..<end])
                let romaji = clean(word)
                if !romaji.isEmpty { units.append(Unit(start: index, end: end, romaji: romaji, script: .latin)) }
                index = end
                continue
            }
            index += 1
        }
        kana.flush(into: &units)
        for index in units.indices where units[index].script != .han {
            guard !cancellation.isCancelled() else { return [] }
            units[index].startsWord = words.boundaries.contains(units[index].start)
            units[index].endsWord = words.boundaries.contains(units[index].end)
            units[index].startsParticle = words.particleStarts.contains(units[index].start)
        }
        return units
    }

    /// Particles that never begin a word of evidence.
    private static let particles: Set<String> = [
        "は", "が", "を", "に", "で", "と", "も", "へ", "や", "の", "か", "ね", "よ", "な", "から", "まで", "より", "って",
    ]

    static func isNumeral(_ scalar: Unicode.Scalar) -> Bool {
        if (0x30...0x39).contains(scalar.value) { return true }
        return "〇零一二三四五六七八九十百千万億兆".unicodeScalars.contains(scalar)
    }

    /// Tokenizer word boundaries (scalar offsets) and the words that contain kanji, keyed by their first scalar
    /// offset, with the in-context reading.
    private static func tokenizerWords(
        _ text: String, scalars: [Unicode.Scalar]
    ) -> (boundaries: Set<Int>, particleStarts: Set<Int>, han: [Int: (end: Int, reading: String)]) {
        var cancellation = DictionaryCancellationCheckpoint()
        var utf16ToScalar: [Int: Int] = [:]
        var offset = 0
        for (index, scalar) in scalars.enumerated() {
            guard !cancellation.isCancelled() else { return ([], [], [:]) }
            utf16ToScalar[offset] = index
            offset += UTF16.width(scalar)
        }
        utf16ToScalar[offset] = scalars.count
        let cfString = text as CFString
        guard let tokenizer = CFStringTokenizerCreate(
            nil, cfString, CFRangeMake(0, CFStringGetLength(cfString)), kCFStringTokenizerUnitWord,
            Locale(identifier: "ja") as CFLocale
        ) else { return ([], [], [:]) }
        var boundaries = Set<Int>()
        var particleStarts = Set<Int>()
        var result: [Int: (end: Int, reading: String)] = [:]
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            guard !cancellation.isCancelled() else { return ([], [], [:]) }
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard let start = utf16ToScalar[range.location], let end = utf16ToScalar[range.location + range.length],
                  end > start else { continue }
            boundaries.insert(start)
            boundaries.insert(end)
            var surface = ""
            surface.unicodeScalars.append(contentsOf: scalars[start..<end])
            if particles.contains(surface) { particleStarts.insert(start) }
            guard scalars[start..<end].contains(where: isHan) else { continue }
            let reading = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            result[start] = (end, reading ?? "")
        }
        return (boundaries, particleStarts, result)
    }

    // MARK: - Kana

    /// Romaji of U+3041...U+3096 (ぁ...ゖ), Hepburn. っ is handled separately (empty here).
    static let hiraganaRomaji: [String] = [
        "a", "a", "i", "i", "u", "u", "e", "e", "o", "o",
        "ka", "ga", "ki", "gi", "ku", "gu", "ke", "ge", "ko", "go",
        "sa", "za", "shi", "ji", "su", "zu", "se", "ze", "so", "zo",
        "ta", "da", "chi", "ji", "", "tsu", "zu", "te", "de", "to", "do",
        "na", "ni", "nu", "ne", "no",
        "ha", "ba", "pa", "hi", "bi", "pi", "fu", "bu", "pu", "he", "be", "pe", "ho", "bo", "po",
        "ma", "mi", "mu", "me", "mo",
        "ya", "ya", "yu", "yu", "yo", "yo",
        "ra", "ri", "ru", "re", "ro",
        "wa", "wa", "i", "e", "o", "n", "vu", "ka", "ke",
    ]

    private static let smallVowels: [UInt32: String] = [0x3041: "a", 0x3043: "i", 0x3045: "u", 0x3047: "e", 0x3049: "o", 0x308E: "a"]
    private static let smallY: [UInt32: String] = [0x3083: "a", 0x3085: "u", 0x3087: "o"]
    private static let sokuon: UInt32 = 0x3063
    private static let prolonged: UInt32 = 0x30FC

    private struct KanaRun {
        /// Index in `units` of the first unit of the current run.
        var runFirstUnit: Int?
        var pendingSokuon: Int?

        mutating func flush(into units: inout [Unit]) {
            runFirstUnit = nil
            pendingSokuon = nil
        }

        mutating func add(_ scalar: Unicode.Scalar, at position: Int, into units: inout [Unit]) {
            if runFirstUnit == nil { runFirstUnit = units.count }
            let (value, script) = PhoneticReading.hiraganaValue(scalar)
            let hasPrevious = units.count > (runFirstUnit ?? units.count) && units[units.count - 1].end == position

            if value == PhoneticReading.prolonged {
                guard hasPrevious, let vowel = units[units.count - 1].romaji.last(where: PhoneticReading.isVowel) else { return }
                units[units.count - 1].romaji.append(vowel)
                units[units.count - 1].end = position + 1
                return
            }
            if let vowel = PhoneticReading.smallY[value], hasPrevious {
                extendLast(&units, position: position, script: script) { PhoneticReading.yoon($0, vowel) }
                return
            }
            if let vowel = PhoneticReading.smallVowels[value], hasPrevious {
                extendLast(&units, position: position, script: script) { PhoneticReading.consonant($0) + vowel }
                return
            }
            if value == PhoneticReading.sokuon {
                if pendingSokuon == nil { pendingSokuon = position }
                return
            }
            var romaji: String
            switch value {
            case 0x3041...0x3096: romaji = PhoneticReading.hiraganaRomaji[Int(value - 0x3041)]
            case 0x30F7: romaji = "va"
            case 0x30F8: romaji = "vi"
            case 0x30F9: romaji = "ve"
            case 0x30FA: romaji = "vo"
            default: return
            }
            var start = position
            if let sokuonStart = pendingSokuon {
                romaji = PhoneticReading.geminate(romaji)
                start = sokuonStart
                pendingSokuon = nil
            }
            units.append(Unit(start: start, end: position + 1, romaji: Array(romaji.utf8), script: script))
        }

        private func extendLast(
            _ units: inout [Unit], position: Int, script: Script, _ transform: (String) -> String
        ) {
            let last = units.count - 1
            let combined = transform(String(decoding: units[last].romaji, as: UTF8.self))
            units[last].romaji = Array(combined.utf8)
            units[last].end = position + 1
            if units[last].script != script { units[last].script = .mixedKana }
        }
    }

    /// Hiragana code point for a kana scalar (katakana shifted), with the source script.
    private static func hiraganaValue(_ scalar: Unicode.Scalar) -> (UInt32, Script) {
        let value = scalar.value
        switch value {
        case 0x30A1...0x30F6: return (value - 0x60, .katakana)
        case 0x30F7...0x30FA: return (value, .katakana)
        case 0x30FC: return (value, .hiragana)  // ー takes the script of the unit it extends.
        default: return (value, .hiragana)
        }
    }

    /// "ki" + ゃ → "kya", "shi" + ゅ → "shu", "ji" + ょ → "jo", "sshi" (っし) + ょ → "ssho".
    static func yoon(_ base: String, _ vowel: String) -> String {
        var stem = base
        if let last = stem.last, "aiueo".contains(last) { stem.removeLast() }
        if stem.hasSuffix("sh") || stem.hasSuffix("ch") || stem.hasSuffix("j") { return stem + vowel }
        return stem + "y" + vowel
    }

    /// Consonant part of a mora for small-vowel combinations: て+ぃ → "ti", ふ+ぁ → "fa", う+ぃ → "wi".
    static func consonant(_ base: String) -> String {
        switch base {
        case "u": return "w"
        case "i": return "y"
        default:
            var stem = base
            if stem.hasSuffix("tsu") || stem.hasSuffix("fu") || stem.hasSuffix("vu") {
                stem.removeLast()
                return stem
            }
            if let last = stem.last, "aiueo".contains(last) { stem.removeLast() }
            return stem
        }
    }

    /// っ before a mora: "ka" → "kka", "chi" → "tchi"; before a vowel it is silent.
    static func geminate(_ romaji: String) -> String {
        guard let first = romaji.first, !"aiueon".contains(first) else { return romaji }
        return romaji.hasPrefix("ch") ? "t" + romaji : String(first) + romaji
    }

    // MARK: - Normalization

    /// Lower-case ASCII letters and digits of a transcription; long-vowel marks spelled as doubled vowels
    /// (ō → "oo", so the key keeps the length), other diacritics removed, a few spelling variants unified.
    static func clean(_ raw: String) -> [UInt8] {
        var text = raw.lowercased()
        if text.unicodeScalars.contains(where: { !$0.isASCII }) {
            var spelled = ""
            for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
                // Combining macron / circumflex after a vowel: the vowel is long.
                if scalar.value == 0x0304 || scalar.value == 0x0302, let vowel = spelled.last, "aiueo".contains(vowel) {
                    spelled.append(vowel)
                } else {
                    spelled.unicodeScalars.append(scalar)
                }
            }
            text = spelled.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        var bytes = text.utf8.filter { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }
        guard bytes.count >= 3 else { return bytes }
        for (from, to) in [("dzu", "zu"), ("dji", "ji"), ("cch", "tch")] where contains(bytes, Array(from.utf8)) {
            bytes = Array(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: from, with: to).utf8)
        }
        return bytes
    }

    private static func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= bytes.count else { return false }
        for start in 0...(bytes.count - needle.count) where bytes[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }

    static func isVowel(_ byte: UInt8) -> Bool {
        byte == 0x61 || byte == 0x69 || byte == 0x75 || byte == 0x65 || byte == 0x6F
    }

    /// Morae of a (folded) key: vowels, length marks, a syllabic n (not before a vowel or y) and the first
    /// consonant of a doubled consonant (っ).
    static func moraCount(_ key: [UInt8]) -> Int {
        var count = 0
        for (index, byte) in key.enumerated() {
            let next = index + 1 < key.count ? key[index + 1] : nil
            if isVowel(byte) || byte == colon {
                count += 1
            } else if byte == 0x6E {
                if next == nil || !(isVowel(next!) || next == 0x79) { count += 1 }
            } else if let next, next == byte || (byte == 0x74 && next == 0x63) {
                count += 1  // "kk", "ss", "tch"
            }
        }
        return count
    }

    static let colon: UInt8 = 0x3A

    /// Streaming long-vowel spelling: a vowel after the same vowel, u after o (おう) and i after e (えい) become
    /// a length mark ":" ("to:", "ke:"); vowel length is kept, only its spelling is unified.
    struct KeyBuilder {
        var bytes: [UInt8] = []

        mutating func append(_ romaji: [UInt8]) {
            for byte in romaji {
                if PhoneticReading.isVowel(byte), let last = bytes.last, PhoneticReading.isVowel(last),
                   last == byte || (last == 0x6F && byte == 0x75) || (last == 0x65 && byte == 0x69) {
                    bytes.append(PhoneticReading.colon)
                    continue
                }
                bytes.append(byte)
            }
        }

        var string: String { String(decoding: bytes, as: UTF8.self) }
    }

    // MARK: - Scalar classes

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x3005: return true
        default: return false
        }
    }

    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x3096, 0x30A1...0x30FA, 0x30FC: return true
        default: return false
        }
    }

    static func isLatinOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F: return true
        default: return false
        }
    }
}
