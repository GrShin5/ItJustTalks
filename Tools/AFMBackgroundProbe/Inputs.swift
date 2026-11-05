// Synthetic dictation-like Japanese sentences. No real people, addresses, or emails.
enum ProbeInputs {
    static let sentences: [String] = [
        "えーと、明日の会議なんですけど、あのー、午後三時からに変更になったので、えっと、資料の準備をお願いします。",
        "ええと、今週のスケジュールを確認して、その、金曜日の午前中に打ち合わせを入れられるか見てもらえますか。",
        "あのですね、新しい企画書のたたき台ができたので、えー、ちょっと目を通していただけるとありがたいです。",
        "えーっと、先月の売上の数字をまとめて、まあ、グラフにして共有フォルダに置いておいてください。",
        "そのー、来週の出張なんですが、えと、新幹線の時間を朝早めにしたほうがいいかなと思っています。",
        "えー、今日は天気がよかったので、あの、昼休みに少し散歩をして、えっと、気分転換ができました。",
        "ええと、テスト環境で動作確認をしたところ、その、一部の画面で表示が崩れていることがわかりました。",
        "あのー、議事録のフォーマットを見直して、えーと、決定事項と宿題が分かりやすくなるようにしたいです。",
        "えっと、新しいソフトの使い方について、まあ、簡単な手順書を作っておくと便利だと思うんですよね。",
        "えーとですね、今月の目標は、あの、作業の進め方を整理して、えー、無駄な会議を減らすことです。"
    ]

    static let instructions = "Clean up this dictated Japanese text. Output only the cleaned text."

    /// Short input for burst / interval modes, cycling through the list.
    static func short(_ index: Int) -> String {
        sentences[index % sentences.count]
    }

    /// Medium input (about 600-900 characters) for chunk mode, rotated by index.
    static func medium(_ index: Int) -> String {
        var text = ""
        var i = index
        while text.count < 700 {
            text += sentences[i % sentences.count]
            i += 1
        }
        return text
    }
}
