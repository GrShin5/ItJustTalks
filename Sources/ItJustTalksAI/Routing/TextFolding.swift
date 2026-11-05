import Foundation

/// Text normalization shared by the deterministic routing rules and the dictionary selector.
/// Pure and locale-independent.
enum TextFolding {
    /// NFKC, lower case (width and case fold), katakana → hiragana. Whitespace is kept.
    static func fold(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping.lowercased()
        let normalizedApostrophes = nfkc
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
        return normalizedApostrophes.applyingTransform(.hiraganaToKatakana, reverse: true) ?? normalizedApostrophes
    }

    /// Folded text without whitespace and without punctuation/symbols (Japanese phrase matching).
    static func compact(_ text: String) -> String {
        String(fold(text).unicodeScalars.filter { !isSeparator($0) })
    }

    /// Words made only of ASCII letters, digits and apostrophes, in order. Everything else (including CJK
    /// characters and punctuation) separates words, so English phrases can be found inside mixed text.
    static func asciiWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in fold(text).unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "'" {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        if properties.isWhitespace { return true }
        switch properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            // The prolonged sound mark is part of words ("ぺーすと"), not a separator.
            return scalar != "\u{30FC}"
        default:
            return false
        }
    }
}
