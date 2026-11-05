import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("CommandRouter")
struct CommandRouterTests {
    // MARK: - Output intent

    @Test(arguments: [
        ("校正して", CommandOutputIntent.automatic),
        ("Proofread this", .automatic),
        ("校正して、表示だけして", .showResult),
        ("結果だけ見せて", .showResult),
        ("貼らないで、要約して", .showResult),
        ("Just show me the result", .showResult),
        ("Fix the grammar but don't paste it", .showResult),
        ("do not insert it, only show", .showResult),
        ("ここに入れて", .insertAtTarget),
        ("丁寧にして、ここに入力して", .insertAtTarget),
        ("箇条書きにして貼り付けて", .insertAtTarget),
        ("Make this more formal and insert it here", .insertAtTarget),
        ("Paste it here", .insertAtTarget),
        // Katakana / width folding.
        ("ペーストして", .insertAtTarget),
        ("ﾍﾟｰｽﾄして", .insertAtTarget),
        ("ＳＨＯＷ ＩＴ ＯＮＬＹ", .showResult),
        // Conflicting.
        ("表示だけにしてここに入れて", .showResult),
        ("見せて、いや貼り付けて", .showResult),
        ("Show it only, and also paste it here", .showResult),
        // Ambiguous destination.
        ("結果はどこかに出しておいて", .showResult),
        ("put it somewhere", .showResult),
    ])
    func outputIntent(instruction: String, expected: CommandOutputIntent) {
        #expect(CommandRouter.outputIntent(spokenInstruction: instruction) == expected)
    }

    @Test func outputIntentIgnoresNothingButTheInstruction() {
        // The function has no target parameter: injected phrases in a target cannot matter by construction.
        #expect(CommandRouter.outputIntent(spokenInstruction: "校正して") == .automatic)
        #expect(CommandRouter.outputIntent(spokenInstruction: "") == .automatic)
    }

    // MARK: - Web check

    @Test(arguments: [
        "最新のニュースを教えて",
        "今日の為替レートを教えて",
        "明日の東京の天気は？",
        "現在の日経平均株価を調べてここに入れて",
        "What are the latest headlines today?",
        "What is the dollar to yen exchange rate right now?",
        "最新のAI newsを教えて",
        "今日のドル円のrateは？",
        "この会社について検索して",
        "Search the web for a good ramen shop",
    ])
    func webFiresWithoutTarget(instruction: String) {
        #expect(CommandRouter.requiresWeb(spokenInstruction: instruction, hasTarget: false), "\(instruction)")
    }

    @Test(arguments: [
        "為替の仕組みを説明して",
        "日本の首都はどこですか",
        "What is the capital of France?",
        "Pythonでlistを逆にする方法を教えて",
        "ニュース記事の書き方を教えて",
        "Write a news article about our launch",
        "次の文章を英語にして、今日は晴れています",
    ])
    func webDoesNotFireForOrdinaryRequests(instruction: String) {
        #expect(!CommandRouter.requiresWeb(spokenInstruction: instruction, hasTarget: false), "\(instruction)")
    }

    @Test(arguments: [
        "今日届いたメールを要約して",
        "最新版の資料を英語に翻訳して",
        "Summarize the email I received today",
        "今日のニュース記事を要約して",
        "Translate the latest news article into Japanese",
        "校正して",
    ])
    func webDoesNotFireWhenTransformingProvidedText(instruction: String) {
        #expect(!CommandRouter.requiresWeb(spokenInstruction: instruction, hasTarget: true))
    }

    @Test func webStillFiresWithTargetWhenNotOperatingOnIt() {
        #expect(CommandRouter.requiresWeb(spokenInstruction: "最新のニュースを教えて", hasTarget: true))
        #expect(CommandRouter.requiresWeb(spokenInstruction: "What is the weather tomorrow?", hasTarget: true))
    }

    // MARK: - Kind table

    @Test func kindTable() {
        func kind(_ type: ClassifiedTaskType, _ hasTarget: Bool, _ spoken: String = "これを処理して") -> CommandKind {
            CommandRouter.deriveKind(taskType: type, hasTarget: hasTarget, spokenInstruction: spoken)
        }
        // Rewrites with a target are content.
        for type in [ClassifiedTaskType.proofread_rewrite, .translate, .transform] {
            #expect(kind(type, true) == .content)
            #expect(kind(type, false) == .answer)
        }
        // Summaries / extractions: content only when the instruction explicitly asks to replace the target.
        for type in [ClassifiedTaskType.summarize, .extract] {
            #expect(kind(type, true, "要約して") == .answer)
            #expect(kind(type, true, "日付と金額を一覧にして") == .answer)
            #expect(kind(type, true, "要約に書き換えて") == .content)
            #expect(kind(type, false, "要約に書き換えて") == .answer)
        }
        for type in [ClassifiedTaskType.explain_analyze, .answer_question, .compose_reply] {
            #expect(kind(type, true, "書き換えて") == .answer)
            #expect(kind(type, false) == .answer)
        }
        #expect(kind(.insufficient_target, false) == .clarification)
        #expect(kind(.not_executable, true) == .refusal)
        #expect(kind(.requires_web, false) == .requiresWeb)
    }

    @Test(arguments: [
        "この議事録を三行の箇条書きに書き換えて",
        "要約で置き換えて",
        "本文を要点だけに差し替えて",
        "結論だけの文章に直して",
        "Replace it with a two-line summary",
        "Rewrite it as a short summary",
        "rewrite this into three bullet points",
    ])
    func explicitReplacement(_ instruction: String) {
        #expect(CommandRouter.asksToReplaceTarget(spokenInstruction: instruction), "\(instruction)")
        #expect(CommandRouter.deriveKind(taskType: .summarize, hasTarget: true, spokenInstruction: instruction) == .content)
    }

    @Test(arguments: [
        "要約して",
        "要約して、ここに入れて",
        "要約して、元の文章は置き換えないで",
        "大事なところを抜き出して貼り付けて",
        "要点を直してから教えて",
        "Summarize this and paste it here",
        "Summarize it but don't replace the original",
        "Extract the dates, do not overwrite anything",
    ])
    func noExplicitReplacement(_ instruction: String) {
        #expect(!CommandRouter.asksToReplaceTarget(spokenInstruction: instruction), "\(instruction)")
        #expect(CommandRouter.deriveKind(taskType: .summarize, hasTarget: true, spokenInstruction: instruction) == .answer)
        #expect(CommandRouter.deriveKind(taskType: .extract, hasTarget: true, spokenInstruction: instruction) == .answer)
    }

    @Test(arguments: [
        ("文法を直して、どこが違ったか教えて", ClassifiedTaskType.proofread_rewrite),
        ("添削して、理由も説明して", .proofread_rewrite),
        ("言い換えて、なぜその表現がいいか教えて", .transform),
        ("Fix the typos and tell me what you changed", .proofread_rewrite),
        ("Proofread this and explain the mistakes", .proofread_rewrite),
        ("edit this and let me know why", .transform),
    ])
    func editPlusQuestionIsExplanation(_ c: (String, ClassifiedTaskType)) {
        let adjusted = CommandRouter.adjustedTaskType(c.1, spokenInstruction: c.0)
        #expect(adjusted == .explain_analyze, "\(c.0)")
        #expect(CommandRouter.deriveKind(taskType: adjusted, hasTarget: true, spokenInstruction: c.0) == .answer)
    }

    @Test(arguments: [
        ("校正して", ClassifiedTaskType.proofread_rewrite),
        ("丁寧な文章に直して、ここに入力して", .proofread_rewrite),
        ("Fix the grammar but just show me the result", .proofread_rewrite),
        ("英語に翻訳して", .translate),
        ("要約して教えて", .summarize),
        ("おすすめの勉強法を教えて", .answer_question),
        ("この文章を説明して", .explain_analyze),
    ])
    func taskTypeKeptWithoutMixedRequest(_ c: (String, ClassifiedTaskType)) {
        #expect(CommandRouter.adjustedTaskType(c.1, spokenInstruction: c.0) == c.1, "\(c.0)")
    }

    // MARK: - Evaluation/cases/routing.jsonl

    private struct RoutingCase {
        var id: String
        var instruction: String
        var hasTarget: Bool
        var intent: String
        var taskType: String
        var replacement: Bool?
        var kind: String
    }

    private static func routingCases() throws -> [RoutingCase] {
        try EvaluationCases.load("routing").map { row in
            let input = row["input"] as! [String: Any]
            let expect = row["expect"] as! [String: Any]
            return RoutingCase(
                id: row["id"] as! String,
                instruction: input["instruction"] as! String,
                hasTarget: !(input["target"] is NSNull),
                intent: expect["outputIntent"] as! String,
                taskType: expect["taskType"] as! String,
                replacement: expect["isReplacementArtifact"] as? Bool,
                kind: expect["kind"] as! String
            )
        }
    }

    @Test func outputIntentAgreementOnRoutingSet() throws {
        let cases = try Self.routingCases()
        #expect(cases.count >= 60)
        var mismatches: [String] = []
        for item in cases where CommandRouter.outputIntent(spokenInstruction: item.instruction).rawValue != item.intent {
            mismatches.append(item.id)
        }
        let agreement = Double(cases.count - mismatches.count) / Double(cases.count)
        print("[routing.jsonl] outputIntent agreement \(cases.count - mismatches.count)/\(cases.count) = \(agreement); mismatches: \(mismatches)")
        #expect(agreement >= 0.95, "mismatches: \(mismatches)")
    }

    @Test func webCheckAgreementOnRoutingSet() throws {
        let cases = try Self.routingCases()
        var mismatches: [String] = []
        for item in cases {
            let predicted = CommandRouter.requiresWeb(spokenInstruction: item.instruction, hasTarget: item.hasTarget)
            if predicted != (item.taskType == "requires_web") { mismatches.append(item.id) }
        }
        let agreement = Double(cases.count - mismatches.count) / Double(cases.count)
        print("[routing.jsonl] web pre-check agreement \(cases.count - mismatches.count)/\(cases.count) = \(agreement); mismatches: \(mismatches)")
        #expect(agreement >= 0.95, "mismatches: \(mismatches)")
    }

    @Test func kindTableMatchesLabelsOnRoutingSet() throws {
        var mismatches: [String] = []
        for item in try Self.routingCases() {
            guard let type = ClassifiedTaskType(rawValue: item.taskType) else {
                Issue.record("unknown taskType in \(item.id)")
                continue
            }
            let kind = CommandRouter.deriveKind(taskType: type, hasTarget: item.hasTarget, spokenInstruction: item.instruction)
            if kind.rawValue != item.kind { mismatches.append(item.id) }
        }
        #expect(mismatches.isEmpty, "mismatches: \(mismatches)")
    }

    /// The task-type override never changes a correctly labelled case, and turns the classifier's
    /// "proofread" for a mixed "edit + tell me" instruction into an explanation.
    @Test func taskTypeOverrideOnRoutingSet() throws {
        var changed: [String] = []
        for item in try Self.routingCases() {
            guard let type = ClassifiedTaskType(rawValue: item.taskType) else { continue }
            if CommandRouter.adjustedTaskType(type, spokenInstruction: item.instruction, hasTarget: item.hasTarget) != type { changed.append(item.id) }
            if item.taskType == "explain_analyze" {
                for edit in [ClassifiedTaskType.proofread_rewrite, .transform]
                where CommandRouter.isEditPlusQuestion(item.instruction) {
                    #expect(CommandRouter.adjustedTaskType(edit, spokenInstruction: item.instruction) == .explain_analyze)
                }
            }
        }
        #expect(changed.isEmpty, "changed: \(changed)")
    }
}
