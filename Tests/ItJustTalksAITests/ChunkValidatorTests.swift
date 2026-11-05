import Testing
@testable import ItJustTalksAI

@Suite("ChunkValidator")
struct ChunkValidatorTests {
    let validator = ChunkValidator()

    func chunk(_ i: Int, _ range: Range<Int>, source: String = "本文です", output: String = "本文です。",
               _ outcome: ValidationOutcome = .complete) -> ChunkResult {
        ChunkResult(index: i, sourceRange: range, source: source, output: output, outcome: outcome)
    }

    @Test func allCompleteAndContiguous() {
        let chunks = [chunk(0, 0..<10, output: "最初の段落です。"), chunk(1, 10..<20, output: "次の段落です。"),
                      chunk(2, 20..<25, output: "最後です。")]
        #expect(validator.validate(chunks, sourceLength: 25) == .complete)
    }

    @Test func oneFailedChunkRejectsAll() {
        let chunks = [chunk(0, 0..<10, output: "最初の段落です。"),
                      chunk(1, 10..<20, output: "", .failed([.emptyOutput]))]
        #expect(validator.validate(chunks, sourceLength: 20) == .failed([.chunkFailed(index: 1)]))
    }

    @Test func reviewChunkMakesWholeReview() {
        let chunks = [chunk(0, 0..<10, output: "最初の段落です。"),
                      chunk(1, 10..<20, output: "次です。", .needsReview([.truncated]))]
        #expect(validator.validate(chunks, sourceLength: 20) == .needsReview([.chunkNeedsReview(index: 1)]))
    }

    @Test func gapsAndOverlaps() {
        #expect(validator.validate([chunk(0, 0..<10, output: "一つ目。"), chunk(1, 12..<20, output: "二つ目。")], sourceLength: 20)
            == .failed([.chunkBoundaryGap(index: 1)]))
        #expect(validator.validate([chunk(0, 0..<10, output: "一つ目。"), chunk(1, 8..<20, output: "二つ目。")], sourceLength: 20)
            == .failed([.chunkBoundaryOverlap(index: 1)]))
        #expect(validator.validate([chunk(0, 0..<10, output: "一つ目。")], sourceLength: 20)
            == .failed([.chunkBoundaryGap(index: 1)]))
        #expect(validator.validate([], sourceLength: 20) == .failed([.chunkBoundaryGap(index: 0)]))
    }

    @Test func boundaryDuplicate() {
        let chunks = [chunk(0, 0..<10, output: "前半の内容です。資料は金曜日に送ります。"),
                      chunk(1, 10..<20, output: "資料は金曜日に送ります。後半の内容です。")]
        #expect(validator.validate(chunks, sourceLength: 20) == .needsReview([.chunkBoundaryDuplicate(index: 1)]))
    }

    @Test func crossChunkCorrectionCue() {
        let chunks = [chunk(0, 0..<10, source: "会議は月曜です", output: "会議は月曜です。"),
                      chunk(1, 10..<20, source: "さっきの月曜は取り消しで火曜です", output: "月曜は取り消しで火曜です。")]
        #expect(validator.validate(chunks, sourceLength: 20) == .needsReview([.crossChunkCorrection(index: 1)]))
        // A cue inside the first chunk is handled by normal cleanup, not flagged.
        #expect(validator.correctionCueChunkIndices(["訂正します、火曜です", "以上です"]).isEmpty)
        #expect(validator.correctionCueChunkIndices(["first part", "scratch that, use Tuesday"]) == [1])
        // M8: common self-correction cues at the start of a later chunk (they can refer to the previous chunk).
        for cue in ["いや、火曜です。資料も送ります。", "じゃなくて、火曜です。", "やっぱり、火曜です。以上です。",
                    "actually, Tuesday. Thanks.", "no wait, Tuesday."] {
            #expect(validator.correctionCueChunkIndices(["会議は月曜です。", cue]) == [1])
        }
        // Ordinary words and later sentences are not flagged ("使いやすい" contains "いや").
        for text in ["この画面は使いやすいです。", "資料を送ります。月曜ではなく火曜に届きます。",
                     "Thanks. The room is actually larger."] {
            #expect(validator.correctionCueChunkIndices(["会議は月曜です。", text]).isEmpty)
        }
    }
}
