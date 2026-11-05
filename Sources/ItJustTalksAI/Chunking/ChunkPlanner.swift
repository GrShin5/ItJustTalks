import Foundation

public enum ChunkReferenceContext: Int, Sendable, Hashable {
    case none = 0
    case previousSentence = 1
}

public struct ChunkProgress: Sendable, Hashable {
    public var completed: Int
    public var total: Int
    public init(completed: Int, total: Int) { self.completed = completed; self.total = total }
}

public struct ChunkingSummary: Sendable, Hashable {
    public var chunkCount: Int
    public var mergeStages: Int
    public var referenceContext: ChunkReferenceContext
    public init(chunkCount: Int, mergeStages: Int, referenceContext: ChunkReferenceContext = .none) {
        self.chunkCount = chunkCount
        self.mergeStages = mergeStages
        self.referenceContext = referenceContext
    }
    var measures: [String: Double] {
        ["chunk.count": Double(chunkCount), "chunk.mergeStages": Double(mergeStages),
         "chunk.referenceContext": Double(referenceContext.rawValue)]
    }
}

public struct PlannedChunk: Sendable, Hashable {
    public var source: String
    public var sourceRange: Range<Int>
    public init(source: String, sourceRange: Range<Int>) { self.source = source; self.sourceRange = sourceRange }
}

public enum ChunkPlan: Sendable, Equatable {
    case chunks([PlannedChunk])
    case maximumChunkCountExceeded
    case unsplittable
}

/// Lossless grapheme-based partitioning; all token counts use the operation executor.
public struct ChunkPlanner: Sendable {
    /// Upper bound for a chunk once a text is split, below what the context allows: the on-device model dropped
    /// whole sentences from ~3,500- and some ~1,500-token chunks; ~800-token chunks completed more long cases (P6 afm-eval).
    /// Provisional; calibrate per model.
    public static let preferredChunkBodyTokens = 800

    public init() {}

    /// - Parameter balanced: size chunks evenly (`≤ preferredChunkBodyTokens`) instead of filling each to the limit.
    public func plan(_ body: String, maxBodyTokens: Int, targetTokens: Int? = nil, balanced: Bool = false,
                     maximumChunks: Int, using executor: some GenerationExecuting) async throws(AIFailure) -> ChunkPlan {
        let result = try await makePlan(body, maxBodyTokens: maxBodyTokens, targetTokens: targetTokens,
            balanced: balanced, maximumChunks: maximumChunks, using: executor)
        if balanced, result == .maximumChunkCountExceeded {
            return try await makePlan(body, maxBodyTokens: maxBodyTokens, targetTokens: targetTokens,
                balanced: false, maximumChunks: maximumChunks, using: executor)
        }
        return result
    }

    private func makePlan(_ body: String, maxBodyTokens: Int, targetTokens: Int?, balanced: Bool,
                          maximumChunks: Int, using executor: some GenerationExecuting) async throws(AIFailure) -> ChunkPlan {
        guard !Task.isCancelled else { throw .cancelled }
        var target = min(maxBodyTokens, targetTokens ?? maxBodyTokens)
        // Only when the preferred size is below the context limit; otherwise chunks fill to the limit as before.
        if balanced, maximumChunks > 0, target > Self.preferredChunkBodyTokens, !body.isEmpty {
            let total = try await executor.tokenCount(for: .prompt(body))
            let cap = min(target, Self.preferredChunkBodyTokens)
            // Never more chunks than allowed: fall back to longer chunks (up to the context limit) instead.
            let count = min(max(1, (total + cap - 1) / cap), maximumChunks)
            // 10% slack so sentence boundaries do not force an extra chunk.
            target = min(target, max(1, Int((Double(total) / Double(count) * 1.1).rounded(.up))))
        }
        guard target > 0, maximumChunks > 0 else { return .unsplittable }
        guard !body.isEmpty else { return .chunks([]) }
        let characters = Array(body)
        var units: [Range<Int>] = []
        for range in Self.ranges(characters, within: 0..<characters.count, level: 0) {
            guard try await divide(range, characters: characters, level: 1, target: target,
                                   executor: executor, units: &units) else { return .unsplittable }
        }
        var chunks: [PlannedChunk] = []
        var start = 0
        var end = 0
        for unit in units {
            guard !Task.isCancelled else { throw .cancelled }
            let candidate = String(characters[start..<unit.upperBound])
            if end > start, try await executor.tokenCount(for: .prompt(candidate)) > target {
                var boundary = end
                let sentences = Self.ranges(characters, within: start..<end, level: 1)
                let following = Self.ranges(characters, within: end..<characters.count, level: 1).first
                if sentences.count > 1, let following,
                   SelfCorrection.hasCue(in: String(characters[following])),
                   let last = sentences.last {
                    let earlier = last.lowerBound
                    let earlierTokens = try await executor.tokenCount(for: .prompt(String(characters[start..<earlier])))
                    if earlierTokens >= (target + 1) / 2, earlierTokens <= target { boundary = earlier }
                }
                chunks.append(PlannedChunk(source: String(characters[start..<boundary]), sourceRange: start..<boundary))
                if chunks.count >= maximumChunks { return .maximumChunkCountExceeded }
                start = boundary
                // A moved sentence plus the next unit may still exceed the target.
                if boundary < end, try await executor.tokenCount(for: .prompt(String(characters[start..<unit.upperBound]))) > target {
                    chunks.append(PlannedChunk(source: String(characters[start..<end]), sourceRange: start..<end))
                    if chunks.count >= maximumChunks { return .maximumChunkCountExceeded }
                    start = end
                }
            }
            end = unit.upperBound
        }
        if start < end { chunks.append(PlannedChunk(source: String(characters[start..<end]), sourceRange: start..<end)) }
        return chunks.count > maximumChunks ? .maximumChunkCountExceeded : .chunks(chunks)
    }

    private func divide(_ range: Range<Int>, characters: [Character], level: Int, target: Int,
                        executor: some GenerationExecuting, units: inout [Range<Int>]) async throws(AIFailure) -> Bool {
        guard !Task.isCancelled else { throw .cancelled }
        if try await executor.tokenCount(for: .prompt(String(characters[range]))) <= target {
            units.append(range)
            return true
        }
        guard range.count > 1, level <= 4 else { return false }
        if level == 4 {
            var start = range.lowerBound
            while start < range.upperBound {
                guard !Task.isCancelled else { throw .cancelled }
                guard try await executor.tokenCount(for: .prompt(String(characters[start...start]))) <= target else { return false }
                var low = start + 1
                var high = range.upperBound
                while low < high {
                    guard !Task.isCancelled else { throw .cancelled }
                    let mid = low + (high - low + 1) / 2
                    if try await executor.tokenCount(for: .prompt(String(characters[start..<mid]))) <= target {
                        low = mid
                    } else {
                        high = mid - 1
                    }
                }
                // Prefer a fitting boundary outside a digit run; a unit made only of digits must still split.
                if low < range.upperBound, characters[low - 1].isNumber, characters[low].isNumber,
                   let safe = (start + 1..<low).reversed().first(where: {
                       !characters[$0 - 1].isNumber || !characters[$0].isNumber
                   }) {
                    low = safe
                }
                units.append(start..<low)
                start = low
            }
            return true
        }
        for part in Self.ranges(characters, within: range, level: level) {
            guard try await divide(part, characters: characters, level: level + 1, target: target,
                                   executor: executor, units: &units) else { return false }
        }
        return true
    }

    static func ranges(_ characters: [Character], within range: Range<Int>, level: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = range.lowerBound
        var i = start
        while i < range.upperBound {
            let c = characters[i]
            let boundary: Bool
            switch level {
            case 0: boundary = c.isNewline
            case 1:
                if ".．".contains(c), i + 1 < characters.count {
                    let next = characters[i + 1]
                    boundary = !(next.isLetter || next.isNumber) || Self.isCJK(next)
                } else {
                    boundary = "。．.!?！？".contains(c) || c.isNewline
                }
            case 2:
                boundary = c == "、" || (",，".contains(c) && !(i > 0 && i + 1 < characters.count
                    && characters[i - 1].isNumber && characters[i + 1].isNumber))
            case 3: boundary = c.isWhitespace
            default: boundary = true
            }
            i += 1
            if boundary {
                if level == 1 {
                    while i < range.upperBound, "\"'”’」』）)]}】〉》".contains(characters[i]) { i += 1 }
                }
                if level < 4 {
                    while i < range.upperBound, characters[i].isWhitespace { i += 1 }
                }
                result.append(start..<i)
                start = i
            }
        }
        if start < range.upperBound { result.append(start..<range.upperBound) }
        return result
    }

    static func lastSentence(_ text: String) -> String? {
        let characters = Array(text)
        return ranges(characters, within: 0..<characters.count, level: 1).last.map {
            String(characters[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func bodyAfterReference(_ reference: String?, output: String) -> String {
        guard let reference else { return output }
        let normalized = ResultValidator.normalizeForMatch(reference)
        guard !normalized.isEmpty, ResultValidator.normalizeForMatch(output).hasPrefix(normalized) else { return output }
        var prefix = ""
        var count = 0
        for character in output {
            let candidate = prefix + String(character)
            if ResultValidator.normalizeForMatch(candidate).count > normalized.count { break }
            prefix = candidate
            count += 1
        }
        return String(output.dropFirst(count))
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x2E80...0xA4CF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
        }
    }

    private static func isLatinOrDigit(_ character: Character) -> Bool {
        character.isNumber || (character.isLetter && character.unicodeScalars.allSatisfy {
            $0.value <= 0x024F || (0x1E00...0x1EFF).contains($0.value)
        })
    }

    static func joined(_ chunks: [ChunkResult]) -> String {
        var output = ""
        var previousHadSeparator = true
        var previousSourceLast: Character?
        for chunk in chunks {
            // Only where the source itself had no space because it was not Latin text ("…です。" + "Next…" in a
            // translation); a Latin source split mid-run ("alpha,|beta") stays as written.
            if !previousHadSeparator, let last = output.last, let first = chunk.output.first,
               let sourceLast = previousSourceLast, !sourceLast.isASCII || !(chunk.source.first?.isASCII ?? true),
               (isLatinOrDigit(last) || ".,;:!?)".contains(last)), isLatinOrDigit(first) {
                output += " "
            }
            previousSourceLast = chunk.source.last
            let separator = String(chunk.source.reversed().prefix(while: { $0.isWhitespace }).reversed())
            output += separator.isEmpty ? chunk.output
                : String(chunk.output.reversed().drop(while: { $0.isWhitespace }).reversed()) + separator
            previousHadSeparator = !separator.isEmpty
        }
        return output
    }
}
