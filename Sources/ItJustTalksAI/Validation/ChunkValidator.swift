import Foundation

/// One processed chunk of a long text (§5.2). `sourceRange` is in characters of the original text.
public struct ChunkResult: Sendable {
    public var index: Int
    public var sourceRange: Range<Int>
    public var source: String
    public var output: String
    public var outcome: ValidationOutcome

    public init(index: Int, sourceRange: Range<Int>, source: String, output: String, outcome: ValidationOutcome) {
        self.index = index
        self.sourceRange = sourceRange
        self.source = source
        self.output = output
        self.outcome = outcome
    }
}

/// Chunk consistency and cross-chunk correction rules (§3.6, ADD-05). All-or-nothing: the combined result
/// is `complete` only when every chunk is complete, ranges tile the source exactly, no boundary sentence is
/// duplicated, and no later chunk contains a correction cue. Simple first implementation; the
/// `ChunkPlanner` (another work item) supplies the ranges.
public struct ChunkValidator: Sendable {
    public var thresholds: ValidationThresholds

    public init(thresholds: ValidationThresholds = .provisionalDefault) {
        self.thresholds = thresholds
    }

    /// - Parameter spokenCorrections: check later chunks for spoken corrections of earlier ones (dictation only;
    ///   written AI-command targets are not checked).
    public func validate(_ chunks: [ChunkResult], sourceLength: Int, spokenCorrections: Bool = true) -> ValidationOutcome {
        var failures: [ValidationReason] = []
        var reviews: [ValidationReason] = []
        let ordered = chunks.sorted { $0.index < $1.index }

        guard !ordered.isEmpty else {
            return sourceLength > 0 ? .failed([.chunkBoundaryGap(index: 0)]) : .failed([.emptyOutput])
        }

        // Every chunk must be complete.
        for chunk in ordered {
            switch chunk.outcome {
            case .complete: break
            case .needsReview: reviews.append(.chunkNeedsReview(index: chunk.index))
            case .failed: failures.append(.chunkFailed(index: chunk.index))
            }
        }

        // Source ranges must tile [0, sourceLength) without gaps or overlaps, indices 0..<n in order.
        var expectedStart = 0
        for (position, chunk) in ordered.enumerated() {
            if chunk.index != position { failures.append(.chunkBoundaryGap(index: position)) }
            if chunk.sourceRange.lowerBound > expectedStart {
                failures.append(.chunkBoundaryGap(index: chunk.index))
            } else if chunk.sourceRange.lowerBound < expectedStart {
                failures.append(.chunkBoundaryOverlap(index: chunk.index))
            }
            expectedStart = max(expectedStart, chunk.sourceRange.upperBound)
        }
        if expectedStart < sourceLength {
            failures.append(.chunkBoundaryGap(index: ordered.count))
        } else if expectedStart > sourceLength {
            failures.append(.chunkBoundaryOverlap(index: ordered.count - 1))
        }

        // Output boundary duplicate: last sentence of chunk i repeated as the first sentence of chunk i+1.
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            if let tail = Self.sentences(previous.output).last,
               let head = Self.sentences(next.output).first,
               tail.count >= thresholds.chunkDuplicateMinimumCharacters,
               tail == head {
                reviews.append(.chunkBoundaryDuplicate(index: next.index))
            }
        }

        // Cross-chunk corrections: a later chunk refers back ("さっきの…取り消し").
        if spokenCorrections {
            for index in correctionCueChunkIndices(ordered.map(\.source)) {
                reviews.append(.crossChunkCorrection(index: ordered[index].index))
            }
        }

        return .from(failures: failures, reviews: reviews)
    }

    /// Positions (≥ 1) of chunk sources that may correct an earlier chunk: a self-correction cue in the chunk's
    /// first sentence (it can refer to the end of the previous chunk), or a retraction word anywhere (a distant
    /// correction, QA-13). Cues later in a chunk are resolved within the chunk by the normal cleanup.
    public func correctionCueChunkIndices(_ chunkSources: [String]) -> [Int] {
        let cues = thresholds.crossChunkCorrectionCues.map { $0.precomposedStringWithCompatibilityMapping.lowercased() }
        return chunkSources.enumerated().dropFirst().compactMap { position, source in
            let text = source.precomposedStringWithCompatibilityMapping.lowercased()
            if cues.contains(where: { text.contains($0) }) { return position }
            let first = ChunkPlanner.ranges(Array(source), within: 0..<source.count, level: 1).first
                .map { String(Array(source)[$0]) } ?? source
            return SelfCorrection.hasCue(in: first) ? position : nil
        }
    }

    static func sentences(_ text: String) -> [String] {
        text.split(whereSeparator: { "。．.!?！？\n".contains($0) })
            .map { ResultValidator.normalizeForMatch(String($0)) }
            .filter { !$0.isEmpty }
    }
}
