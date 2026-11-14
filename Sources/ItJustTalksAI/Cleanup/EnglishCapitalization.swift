import Foundation

/// Deterministic English capitalization for the projected path: the first word of the text and of each
/// sentence after . ! ? (or a line break), and the pronoun "I" with its contractions. Words are never
/// changed otherwise. Identifiers (iPhone, example.com, email addresses, x2) and words after common abbreviations
/// (e.g., p.m.) are left alone.
enum EnglishCapitalization {
    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "a.m", "p.m", "mr", "mrs", "ms", "dr"]
    private static let pronoun: Set<String> = ["i", "i'm", "i'll", "i've", "i'd", "i’m", "i’ll", "i’ve", "i’d"]

    static func apply(_ text: String) -> String {
        var chars = Array(text)
        var sentenceStart = true
        var previousWord = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || "'’.@/-_".contains(chars[j]) { j += 1 }
                // A trailing period ends the sentence; it is not part of the word.
                var end = j
                while end > i, ".".contains(chars[end - 1]) { end -= 1 }
                let word = String(chars[i..<end])
                let lower = word.lowercased()
                let plain = word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" }
                let allLower = word == lower
                if plain && allLower && (pronoun.contains(lower) || (sentenceStart && !abbreviations.contains(previousWord))) {
                    chars[i] = Character(String(chars[i]).uppercased())
                }
                // "U.S." and similar: a period inside the word marks an abbreviation, not a sentence end.
                previousWord = word.contains(".") ? "e.g" : lower
                sentenceStart = false
                i = end
                continue
            }
            if c.isNumber { sentenceStart = false }
            if "!?".contains(c) || c.isNewline { sentenceStart = true }
            if c == ".", !abbreviations.contains(previousWord) {
                // "3.5" or "example.com" keep going; a period followed by a space or the end closes a sentence.
                if i + 1 >= chars.count || chars[i + 1].isWhitespace { sentenceStart = true }
            }
            i += 1
        }
        return String(chars)
    }
}
