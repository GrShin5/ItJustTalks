import Foundation

/// Narrow English corrections. Delimited cues and parallel, typed items distinguish
/// corrections from ordinary apologies, answers and adverbs.
enum EnglishCuedRestart {
    private static let cue = #"(?i:no wait|sorry|I mean|actually|scratch that|or rather|make that)"#
    private static let number = #"[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?(?::[0-9]{2})?(?:[ ]?(?i:am|pm))?"#

    static func collapse(_ text: String) -> String {
        var result = text
        while let range = deletion(in: result) { result.removeSubrange(range) }
        while let repair = sentenceDeletion(in: result) {
            let offset = result.distance(from: result.startIndex, to: repair.lowerBound)
            let sentenceStart = result[..<repair.lowerBound].trimmingCharacters(in: .whitespaces).last.map { ".!?".contains($0) } ?? true
            result.removeSubrange(repair)
            if sentenceStart {
                let start = result.index(result.startIndex, offsetBy: offset)
                // Only an all-lower-case first word is capitalized ("iOS" stays).
                let word = result[start...].prefix { !$0.isWhitespace }
                if start < result.endIndex, word.allSatisfy({ !$0.isUppercase }) {
                    result.replaceSubrange(start...start, with: String(result[start]).uppercased())
                }
            }
        }
        return result
    }

    /// Sentence repairs require parallel wording or a complete, typed replacement fragment.
    static func sentenceDeletion(in text: String, retracted: String? = nil, replacement: String? = nil) -> Range<String.Index>? {
        guard text.unicodeScalars.allSatisfy({ !$0.properties.isAlphabetic || $0.isASCII }) else { return nil }
        let pattern = #"(?:^|(?<=[.!?]) )([A-Za-z0-9][^.!?\n]*?)\. +(?:No, *(?:wait\. *|wait, *)?|Actually, *|I mean[, ]+|Sorry, *)([A-Za-z0-9][^.!?\n]*)\.(?= |$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let weekdays = Set(["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"])
        let months = Set(["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"])
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let left = Range(match.range(at: 1), in: text), let right = Range(match.range(at: 2), in: text) else { continue }
            // A question immediately before this sentence can introduce an answer.
            let prior = text[..<left.lowerBound].trimmingCharacters(in: .whitespaces)
            if prior.last == "?" { continue }
            let a = text[left].split(separator: " ").map(String.init)
            let b = text[right].split(separator: " ").map(String.init)
            // Negation, contrast and reported questions are not corrections ("We don't need 6 boxes. No, 8 boxes.").
            let blocking: Set<String> = ["not", "but", "never", "cannot", "instead", "rather", "if", "whether",
                                         "asked", "said", "says", "ask", "wonder", "wondered"]
            if (a + b).contains(where: { word in
                let w = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                return blocking.contains(w) || w.hasSuffix("n't") || w.hasSuffix("n’t")
            }) { continue }
            var shared = 0
            while shared < min(a.count, b.count), a[shared].lowercased() == b[shared].lowercased() { shared += 1 }
            let parallel = shared >= 2 && shared == a.count - 1 && shared == b.count - 1
            let noun = !parallel && b.count == 2 && a.count >= 2 && a.last == b.last
            let count = noun ? 2 : 1
            guard parallel || b.count == count, a.count >= count else { continue }
            let x = parallel ? a.last! : a[a.count - count]
            let y = parallel ? b.last! : b[0]
            guard x.lowercased() != y.lowercased() else { continue }
            let before = a.dropLast(count).joined(separator: " ")
            let numeric = x.allSatisfy(\.isNumber) && y.allSatisfy(\.isNumber)
            let calendar = (weekdays.contains(x.lowercased()) && weekdays.contains(y.lowercased()))
                || (months.contains(x.lowercased()) && months.contains(y.lowercased()))
            let excluded = Set(["The", "This", "That", "Please", "Yes", "No", "Actually", "Sorry", "I"])
            let names = x.first?.isUppercase == true && y.first?.isUppercase == true
                && !excluded.contains(x) && !excluded.contains(y)
                && !weekdays.contains(x.lowercased()) && !weekdays.contains(y.lowercased())
                && !months.contains(x.lowercased()) && !months.contains(y.lowercased())
                && (zip(x, y).prefix(while: { $0 == $1 }).count >= 2
                    || before.range(of: #"(?i:\b(?:to|from|with|contact|ask|tell|named))$"#, options: .regularExpression) != nil)
            guard numeric || calendar || names else { continue }
            if let retracted, let replacement {
                guard (retracted.lowercased() == x.lowercased() && replacement.lowercased() == y.lowercased())
                    || (retracted.lowercased() == a.suffix(count).joined(separator: " ").lowercased()
                        && replacement.lowercased() == b.suffix(count).joined(separator: " ").lowercased()) else { continue }
            }
            let start = parallel ? left.lowerBound : text.index(left.upperBound, offsetBy: -a.suffix(count).joined(separator: " ").count)
            return start..<right.lowerBound
        }
        return nil
    }

    private static func deletion(in text: String) -> Range<String.Index>? {
        let item = "(?:\(number)|[A-Z][a-z]+)"
        let pattern = "(?<![\\p{L}\\p{N}.,:+−-])(\(item)),[ ]+\(cue),[ ]+(\(item))(?![\\p{L}\\p{N}:])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let left = Range(match.range(at: 1), in: text),
                  let right = Range(match.range(at: 2), in: text) else { continue }
            let a = String(text[left]), b = String(text[right])
            // Protect contrasts throughout the containing sentence, including "not A but B".
            let before = text[..<left.lowerBound].split(whereSeparator: { ".!?\n\r".contains($0) }).last.map(String.init) ?? ""
            let after = text[right.upperBound...].prefix(while: { !".!?\n\r".contains($0) })
            let context = before + a + " " + b + String(after)
            if context.range(of: #"\b(?:not|but)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            let numericA = a.first?.isNumber == true, numericB = b.first?.isNumber == true
            guard numericA == numericB, a != b else { continue }
            if numericA {
                // Bare numbers may inherit a replacement's time suffix, but two
                // explicit time markers must agree in kind (clock versus meridiem).
                let clockA = a.contains(":"), clockB = b.contains(":")
                let meridiemA = a.last?.isLetter == true, meridiemB = b.last?.isLetter == true
                if (clockA && meridiemB && !clockB) || (clockB && meridiemA && !clockA) { continue }
            } else {
                // Capitalization alone does not establish a name. Require a shared
                // stem or an explicit recipient context; reject common non-name tokens.
                let excluded: Set<String> = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "The", "This", "That", "Please", "Yes", "No"]
                guard !excluded.contains(a), !excluded.contains(b) else { continue }
                let shared = zip(a, b).prefix(while: { $0 == $1 }).count
                guard shared >= 2 || before.range(of: #"(?i:\b(?:to|from|with|contact|ask|tell|named)) $"#,
                                                  options: .regularExpression) != nil else { continue }
            }
            return left.lowerBound..<right.lowerBound
        }
        return nil
    }
}
