import Foundation

/// Removes only isolated hesitation words at a pause, retaining quoted text verbatim.
enum FillerStripper {
    private static let filler = try! NSRegularExpression(
        // Not ええ (yes), ううん (no) or うーん (kept as content by the validator); lower-case um/uh only.
        pattern: #"(?:え[ーえ]*っ?と[ーお]*|えー+|あの[ーう]+|[Uu]m+|[Uu]h+)(?=[、,\t 　]|\z)"#
    )

    static func strip(_ text: String, source: String? = nil) -> String {
        var result = ""
        var index = text.startIndex
        var quoteEnds: [Character] = []
        var atPause = true
        let quotes: [Character: Character] = ["「": "」", "『": "』", "“": "”", "‘": "’", "\"": "\"", "'": "'"]
        let sourceFillers = source.map { standaloneFillers(in: $0, quotes: quotes) } ?? []
        // With a source, strip hesitation words only when the speaker actually hesitated.
        let sourceHesitates = source.map { strip($0) != $0 } ?? true
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            // Apostrophes inside words are not quotation marks.
            let apostrophe = (character == "'" || character == "’") && index > text.startIndex
                && text[text.index(before: index)].isLetter && next < text.endIndex && text[next].isLetter
            if !apostrophe, quoteEnds.last == character {
                quoteEnds.removeLast()
            } else if !apostrophe, let end = quotes[character] {
                quoteEnds.append(end)
            } else if quoteEnds.isEmpty,
                      (index == text.startIndex || isPause(text[text.index(before: index)])),
                      let word = ["まあ", "なんか"].first(where: { word in
                          guard sourceFillers.contains(word), text[index...].hasPrefix(word),
                                let end = text.index(index, offsetBy: word.count, limitedBy: text.endIndex),
                                end < text.endIndex else { return false }
                          return text[end] == "、" || text[end].isWhitespace && !text[end].isNewline
                      }) {
                index = text.index(index, offsetBy: word.count)
                while index < text.endIndex, text[index] == "、" || (text[index].isWhitespace && !text[index].isNewline) {
                    index = text.index(after: index)
                }
                continue
            } else if quoteEnds.isEmpty, atPause, sourceHesitates,
                      let match = filler.firstMatch(in: text, options: [.anchored],
                          range: NSRange(index..<text.endIndex, in: text)),
                      let range = Range(match.range, in: text) {
                index = range.upperBound
                // Consume the filler's separator, preserving sentence ends and line breaks.
                while index < text.endIndex, "、,\t 　".contains(text[index]) {
                    index = text.index(after: index)
                }
                continue
            }
            result.append(character)
            if quoteEnds.isEmpty {
                if character.isNewline || "。、？！!?".contains(character) {
                    atPause = true
                } else if !character.isWhitespace {
                    atPause = false
                }
            } else {
                atPause = false
            }
            index = next
        }
        // A reply that is only a hesitation word stays as spoken.
        return result.allSatisfy(\.isWhitespace) ? text : result
    }

    private static func isPause(_ character: Character) -> Bool {
        character.isWhitespace || "。、？！!?".contains(character)
    }

    private static func standaloneFillers(in text: String, quotes: [Character: Character]) -> Set<String> {
        var found: Set<String> = []
        var quoteEnds: [Character] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let apostrophe = (character == "'" || character == "’") && index > text.startIndex
                && text[text.index(before: index)].isLetter && next < text.endIndex && text[next].isLetter
            if !apostrophe, quoteEnds.last == character {
                quoteEnds.removeLast()
            } else if !apostrophe, let end = quotes[character] {
                quoteEnds.append(end)
            } else if quoteEnds.isEmpty, (index == text.startIndex || isPause(text[text.index(before: index)])) {
                for word in ["まあ", "なんか"] where text[index...].hasPrefix(word) {
                    let end = text.index(index, offsetBy: word.count)
                    if end == text.endIndex || isPause(text[end]) { found.insert(word) }
                }
            }
            index = next
        }
        return found
    }
}
