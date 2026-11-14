import Foundation

/// Deterministic removal of an obvious cued restart in plain dictation: 「14枚いや19枚」,
/// 「来週の月曜、いや、来週の火曜」, 「集合は10時、いや9時」, 「高橋さん、いや森さん」.
///
/// Conservative by construction (anything unclear is left to Stage A and the model):
/// - The retraction starts and the replacement ends at a word boundary (text start, a mark, a particle,
///   or a change of script); a number is always compared whole (「10時」 never becomes 「0時」).
/// - Retraction and replacement share a prefix or suffix, have comparable lengths, and either both or
///   neither contain digits.
/// - Cues that are also ordinary words need a pause: 「やっぱり」「違う」「訂正」 must touch a pause
///   mark; 「いや」 must not follow hiragana (「これでいいや」). Contrastive 「じゃなくて」 only
///   corrects quantities and times (both sides contain digits); apologies are never cues here.
/// - Never crosses a sentence end.
enum CuedRestart {
    private static let cues = ["やっぱり", "じゃなくて", "ではなくて", "いや", "違う", "訂正"]
    private static let pausedCues: Set<String> = ["やっぱり", "違う", "訂正"]
    private static let numericOnlyCues: Set<String> = ["じゃなくて", "ではなくて"]
    private static let particles: Set<Character> = ["は", "が", "を", "に", "で", "と", "も", "へ", "や", "の"]
    private static let sentenceEnds: Set<Character> = ["。", "．", ".", "!", "?", "！", "？", "\n"]

    static func collapse(_ text: String) -> String {
        var chars = Array(text)
        var searchFrom = 0
        while let deletion = nextRestart(in: chars, from: searchFrom) {
            chars.removeSubrange(deletion)
            searchFrom = deletion.lowerBound
        }
        return String(chars)
    }

    private enum Script { case kanji, hiragana, katakana, digit, latin, other }

    private static func script(_ c: Character) -> Script {
        guard let v = c.unicodeScalars.first?.value else { return .other }
        switch v {
        case 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0xFF10...0xFF19: return .digit
        case 0x3041...0x309F: return .hiragana
        case 0x30A0...0x30FF, 0xFF66...0xFF9F: return .katakana
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3005: return .kanji
        default: return c.isLetter ? .latin : .other
        }
    }

    private static func isMark(_ c: Character) -> Bool { c.isPunctuation || c.isWhitespace || c.isSymbol }

    /// A digit-internal separator (「3.5」「1,000」) belongs to the number.
    private static func isNumberPart(_ s: [Character], _ i: Int) -> Bool {
        guard s.indices.contains(i) else { return false }
        if script(s[i]) == .digit { return true }
        return ".,．，".contains(s[i]) && i > 0 && i + 1 < s.count && script(s[i - 1]) == .digit && script(s[i + 1]) == .digit
    }

    /// True when a word may start at `i` (the boundary sits between `i - 1` and `i`).
    private static func boundary(_ s: [Character], _ i: Int) -> Bool {
        if i <= 0 || i >= s.count { return true }
        let a = s[i - 1], b = s[i]
        if isNumberPart(s, i - 1) && isNumberPart(s, i) { return false }
        if isMark(a) || isMark(b) { return true }
        if particles.contains(a) && script(b) != .hiragana { return true }
        if particles.contains(b) { return true }
        let sa = script(a), sb = script(b)
        // 「お客様」: a hiragana prefix glued to kanji is one word; other script changes are boundaries.
        if sa == .hiragana && sb == .kanji { return false }
        return sa != sb
    }

    private static func content(_ chars: ArraySlice<Character>) -> Bool {
        let array = Array(chars)
        return !array.indices.contains { isMark(array[$0]) && !isNumberPart(array, $0) }
    }

    private static func nextRestart(in s: [Character], from start: Int) -> Range<Int>? {
        var c = start
        while c < s.count {
            guard let cue = cues.first(where: { c + $0.count <= s.count && s[c..<(c + $0.count)].elementsEqual($0) }) else {
                c += 1; continue
            }
            defer { c += cue.count }
            let cueEnd = c + cue.count
            // Pause marks (not sentence ends) around the cue.
            var x = c
            while x > 0, isMark(s[x - 1]), !sentenceEnds.contains(s[x - 1]) { x -= 1 }
            var y = cueEnd
            while y < s.count, isMark(s[y]), !sentenceEnds.contains(s[y]) { y += 1 }
            let pausedBefore = x < c, pausedAfter = y > cueEnd
            // Without a pause, 「やっぱり」「違う」「訂正」 are ordinary words unless numbers are corrected.
            let requiresDigits = numericOnlyCues.contains(cue) || (pausedCues.contains(cue) && !pausedBefore && !pausedAfter)
            if cue == "いや", !pausedBefore, c > 0, script(s[c - 1]) == .hiragana { continue }
            guard x > 0, y < s.count else { continue }

            var best: (shared: Int, lx: Int, ly: Int)?
            for lx in 1...min(12, x) where boundary(s, x - lx) {
                let retracted = s[(x - lx)..<x]
                guard content(retracted) else { continue }
                // A retraction does not start with a particle or a glued hiragana ending (「は10時」).
                if script(retracted.first!) == .hiragana, !retracted.allSatisfy({ script($0) == .hiragana }) { continue }
                for ly in 1...min(12, s.count - y) where boundary(s, y + ly) {
                    let replacement = s[y..<(y + ly)]
                    guard content(replacement), !retracted.elementsEqual(replacement) else { continue }
                    guard max(lx, ly) <= 2 * min(lx, ly) + 1 else { continue }
                    let digitsX = retracted.contains { script($0) == .digit }
                    let digitsY = replacement.contains { script($0) == .digit }
                    guard digitsX == digitsY else { continue }
                    if requiresDigits, !digitsX { continue }
                    let rx = Array(retracted), ry = Array(replacement)
                    let prefix = zip(rx, ry).prefix(while: { $0 == $1 }).count
                    let suffix = zip(rx.reversed(), ry.reversed()).prefix(while: { $0 == $1 }).count
                    // A retraction spanning a phrase (「会議は3時」) is only taken when the replacement repeats
                    // that phrase (「来週の月曜」/「来週の火曜」).
                    if let inner = rx.indices.dropLast().first(where: { particles.contains(rx[$0]) && script(rx[$0 + 1]) != .hiragana }),
                       prefix <= inner, suffix < rx.count - inner { continue }
                    let shared = min(prefix + suffix, min(lx, ly))
                    guard shared >= 1, prefix < min(lx, ly) || lx != ly else { continue }
                    // Most shared characters first, then the whole retracted word (「高橋さん」 over 「さん」).
                    if let b = best, (shared, lx) <= (b.shared, b.lx) { continue }
                    best = (shared, lx, ly)
                }
            }
            if let best { return (x - best.lx)..<y }
        }
        return nil
    }
}
