import Testing
@testable import ItJustTalksAI

// Structural routing rules (P1 round 2). Phrasings differ from Evaluation/cases and Evaluation/holdout.

@Suite("CommandRouter — structural rules")
struct CommandRouterStructureTests {
    // MARK: Edit + question with a target → answer

    @Test(arguments: [
        // Yes/no or opinion questions → answer_question.
        ("箇条書きに直して、これで読み手に伝わるかな？", ClassifiedTaskType.transform, ClassifiedTaskType.answer_question),
        ("敬語に整えて、ちょっと硬すぎないか知りたい", .proofread_rewrite, .answer_question),
        ("中国語に訳して。この言い回しで誤解されないと思う？", .translate, .answer_question),
        ("要点を三行にして、大事な点が抜けてないかどうか見て", .summarize, .answer_question),
        ("Shorten this and let me know if it still sounds friendly", .transform, .answer_question),
        ("Polish the wording. Do you think the client will accept it?", .proofread_rewrite, .answer_question),
        ("Translate this to German, is it too informal?", .translate, .answer_question),
        // Wh-questions or a named explanation → explain_analyze.
        ("語尾を整えて、どこを変えたか教えて", .proofread_rewrite, .explain_analyze),
        ("この段落を短くして、何を削ったのか解説して", .transform, .explain_analyze),
        ("Tidy up the grammar and explain which parts were unclear", .proofread_rewrite, .explain_analyze),
    ])
    func questionWithTargetIsAnswer(_ c: (String, ClassifiedTaskType, ClassifiedTaskType)) {
        let adjusted = CommandRouter.adjustedTaskType(c.1, spokenInstruction: c.0, hasTarget: true)
        #expect(adjusted == c.2, "\(c.0)")
        #expect(CommandRouter.deriveKind(taskType: adjusted, hasTarget: true, spokenInstruction: c.0) == .answer)
    }

    // MARK: Reply requests with a tone word stay replies

    @Test(arguments: [
        ("確認が遅れていることを謝り、企画書を確認しますと丁寧に返信して", ClassifiedTaskType.proofread_rewrite, ClassifiedTaskType.compose_reply),
        ("短く返事して", .transform, .compose_reply),
        ("お礼を伝える返信を書いて", .proofread_rewrite, .compose_reply),
        ("Reply politely, apologize for the delay and say I will review it.", .proofread_rewrite, .compose_reply),
        ("Please write a reply that is short and friendly", .transform, .compose_reply),
        // Editing a reply text, or a translation, is not a new reply.
        ("この返信を丁寧にして", .proofread_rewrite, .proofread_rewrite),
        ("返事の文面を短くして", .transform, .transform),
        ("Make this reply more polite", .proofread_rewrite, .proofread_rewrite),
        ("英語にして返信して", .translate, .translate),
        ("この下書きを丁寧に直して返信して", .proofread_rewrite, .proofread_rewrite),
        ("Proofread this; I'll write a reply later", .proofread_rewrite, .proofread_rewrite),
    ])
    func replyRequestsWithToneStayReplies(_ c: (String, ClassifiedTaskType, ClassifiedTaskType)) {
        #expect(CommandRouter.adjustedTaskType(c.1, spokenInstruction: c.0, hasTarget: true) == c.2, "\(c.0)")
        #expect(CommandRouter.adjustedTaskType(c.1, spokenInstruction: c.0, hasTarget: false) != .compose_reply || c.1 == .compose_reply)
    }

    @Test(arguments: [
        // Requests phrased as questions stay edits (content).
        ("この文章を丁寧にしてくれる？", ClassifiedTaskType.proofread_rewrite),
        ("ここ、フランス語にしてもらえますか", .translate),
        ("もう少し短くできる？", .transform),
        ("Could you proofread this?", .proofread_rewrite),
        ("Can you make this sound warmer?", .transform),
        ("Please translate this into Korean", .translate),
        // No question at all.
        ("誤字を直して", .proofread_rewrite),
        ("Turn this into a numbered list", .transform),
    ])
    func requestQuestionsStayEdits(_ c: (String, ClassifiedTaskType)) {
        #expect(CommandRouter.adjustedTaskType(c.1, spokenInstruction: c.0, hasTarget: true) == c.1, "\(c.0)")
    }

    @Test func questionWithoutTargetIsUnchanged() {
        // Without a target the kind is already an answer; the task type is left to the classifier.
        #expect(CommandRouter.adjustedTaskType(.translate, spokenInstruction: "「おはよう」を英語にすると？", hasTarget: false) == .translate)
    }

    // MARK: Output intent

    @Test(arguments: [
        // Negated insertion with particles / other negative forms → show only.
        ("要約して、入力はしないで", CommandOutputIntent.showResult),
        ("清書して。貼り付けはしないでね", .showResult),
        ("英語にして、元の文には反映しなくていい", .showResult),
        ("短くして、ここには入れずに出しておいて", .showResult),
        ("整えて。上書きは不要です", .showResult),
        ("直して、まだ挿入しちゃだめ", .showResult),
        ("Rewrite it, but no need to paste it anywhere", .showResult),
        ("Make it concise, instead of inserting it just let me read it", .showResult),
        // Show stems.
        ("翻訳を画面に出すだけでいい", .showResult),
        ("結果を見せるだけにして", .showResult),
        // Hedged / conflicting.
        ("校正して、入れてもいいし見るだけでもいい", .showResult),
        ("要約して、ここに貼ってもかまわない", .showResult),
        ("Translate it and paste it if you want", .showResult),
        // Affirmative insertion still inserts.
        ("丁寧にして、入力欄に入れて", .insertAtTarget),
        ("Summarize it and paste the result", .insertAtTarget),
        // No destination.
        ("誤字を直して", .automatic),
        ("入力ミスを直して", .automatic),
    ])
    func outputIntent(_ c: (String, CommandOutputIntent)) {
        #expect(CommandRouter.outputIntent(spokenInstruction: c.0) == c.1, "\(c.0)")
    }
}
