import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("PredicateRetention")
struct PredicateRetentionTests {
    private func validate(_ source: String, _ output: String, spans: [SelfCorrectionSpan] = []) -> ValidationOutcome {
        ResultValidator().validate(ValidationInput(
            task: .cleanup, source: source, output: output, isTruncated: false,
            protectedInstructions: [PromptCatalog.template(.cleanup, language: .ja).text],
            handsFree: false, selfCorrections: spans))
    }

    @Test(arguments: [
        ("保管箱を閉じた保管箱を閉じてください", "保管箱を閉じてください。"),
        ("研修資料を準備して、研修資料を準備しておいてもらえますか", "研修資料を準備してもらえますか"),
        ("窓を開けました、窓を開けたい", "窓を開けたい。"),
        ("窓を開けます、窓を開けません", "窓を開けません。"),
        ("窓を開けた、窓を開けてほしい", "窓を開けてほしい。"),
        ("窓を開けた、窓を開けて下さい", "窓を開けて下さい。"),
        ("窓を開けた、窓を開けましょう", "窓を開けましょう。"),
    ])
    func droppedContentNeedsReview(_ pair: (String, String)) {
        #expect(validate(pair.0, pair.1).reasons.contains(.lowContentRetention))
    }

    @Test(arguments: [
        ("保管箱を閉じた保管箱を閉じてください", "保管箱を閉じた。保管箱を閉じてください。"),
        ("研修資料を準備して、研修資料を準備しておいてもらえますか", "研修資料を準備して、研修資料を準備しておいてもらえますか。"),
        ("端末を起動した、端末を起動している", "端末を起動している。"),
        ("会場を予約し、会場を予約しておいて", "会場を予約しておいて。"),
        ("集合は三時、いや四時です", "集合は四時です。"),
        ("えーと、保管箱を閉じてください", "保管箱を閉じてください。"),
        ("あのー来週の月曜日に資料を三部印刷しておいてもらえますか", "来週の月曜日に資料を3部印刷しておいてもらえますか？"),
        ("I closed the box, please close the box", "I closed the box. Please close the box."),
    ])
    func faithfulCleanupIsComplete(_ pair: (String, String)) {
        #expect(validate(pair.0, pair.1) == .complete)
    }

    @Test func certifiedCorrectionIsExcluded() {
        let source = "使えます、あ、違う、使えません"
        let correction = SelfCorrection.apply([("使えます", "使えません")], to: source)
        #expect(!correction.spans.isEmpty)
        #expect(validate(source, "使えません。", spans: correction.spans) == .complete)
        let auxiliarySource = "資料を準備しておいて、いや、準備してください"
        let spans = [SelfCorrectionSpan(retracted: "準備しておいて", replacement: "準備してください")]
        #expect(!CleanupFidelity.dropsAuxiliary(source: auxiliarySource, output: "資料を準備してください。", spans: spans))
    }

    @Test(arguments: [
        ("書いておいた", "読んでおいた"), ("読んでおいた", "書いておいた"),
        ("書いておく", "読んでおく"), ("読んでおく", "書いておく"),
        ("書いておきます", "読んでおきます"), ("書いてしまった", "読んでしまった"),
        ("読んでしまった", "書いてしまった"), ("書いちゃった", "開けちゃった"),
        ("書いてあげる", "読んであげる"), ("書いてくれる", "読んでくれる"),
        ("書いてもらう", "読んでもらう"),
    ])
    func auxiliaryIsBoundToItsStem(_ pair: (String, String)) {
        #expect(CleanupFidelity.dropsAuxiliary(source: pair.0, output: "書いた。読んだ。" + pair.1))
        #expect(!CleanupFidelity.dropsAuxiliary(source: pair.0, output: pair.0 + "。"))
    }

    @Test func auxiliaryInflectionIsRetained() {
        #expect(!CleanupFidelity.dropsAuxiliary(source: "資料を準備しておいて", output: "資料を準備しておきます。"))
        #expect(!CleanupFidelity.dropsDistinctPredicate(source: "Start the engine, please start the engine", output: "Please start the engine."))
        #expect(!CleanupFidelity.dropsAuxiliary(source: "Please prepare it in advance", output: "Please prepare it."))
    }

    @Test(arguments: [
        ("保管箱を閉じた保管箱を閉じてください", "保管箱を閉じてください。", false),
        ("保管箱を閉じた保管箱を閉じてください", "保管箱を閉じた。保管箱を閉じてください。", true),
        ("研修資料を準備して、研修資料を準備しておいてもらえますか", "研修資料を準備してもらえますか", false),
        ("端末を起動した、端末を起動している", "端末を起動している。", true),
    ])
    func pipelineChecksBeforeRestartCollapser(_ item: (String, String, Bool)) async {
        let fake = FakeGenerator(script: [.init(.text(item.1))])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let input = CleanupInput(transcript: item.0, promptLanguage: .ja, handsFree: false)
        let outcome = await CleanupPipeline().run(input, operation: UUID(), coordinator: coordinator, deadline: roomyDeadline)
        guard case .delivered(let result) = outcome else { Issue.record("No result delivered"); return }
        #expect(result.diagnostics.validation?.outcome.isComplete == item.2)
        if !item.2 { #expect(result.diagnostics.validation?.outcome.reasons.contains(.lowContentRetention) == true) }
    }
}
