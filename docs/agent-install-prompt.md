# ItJustTalks 導入用プロンプト

配布元を確認し、下のコードブロック全体を、Macのローカルフォルダとコマンドを扱えるAIコーディングエージェントへ貼り付けてください。個人データの添付は不要です。作業を助けるエージェント自身の通信は、アプリのローカルAI処理とは別です。

英語版は[agent-install-prompt.en.md](agent-install-prompt.en.md)です（内容は同じ）。

```text
このMacへItJustTalks 0.1.1をソースからビルド・自己署名して新規導入してください。
取得元: https://github.com/GrShin5/ItJustTalks

守ること:
- 対象はItJustTalksだけです。AI処理はApple Foundation Modelsのオンデバイスモデルのみです。外部AIの導入・ログイン・APIキー設定は不要です。
- 利用者のデータを絶対にアップロードしないでください。発話、メール、選択本文、クリップボード、辞書、履歴、設定の本文を読取り・出力・外部送信しないでください。診断情報もアップロードせず、機密値は報告から除いてください。通信は指定ソースと必要な開発依存物の取得に限ります。
- セキュリティ設定は変更しないでください。Gatekeeper、SIP、権限データベース、キーチェーンの保護を緩めず、検証の無効化、ad-hoc署名、権限の一括リセットをしないでください。macOSの認証・許可操作はユーザー自身に任せてください。
- Koedexのアプリ・リポジトリ・データに触れないでください。`~/Library/Application Support/Koedex*` は読取り・書込み・移行・削除・権限変更すべて禁止です。
- 変更済みソースや競合を見つけたら停止し、勝手に破棄・上書きしないでください。コミット、push、公開、不要なファイル削除はしないでください。
- エラー時はそこで止め、原因と必要な次の操作を説明してください。署名や識別子の不一致を迂回しないでください。アプリ起動や録音・文章入力の確認はユーザーに任せてください。

macOS 27以上、AI機能にはApple silicon、Apple Intelligenceの有効化、モデル準備、MacとSiriの言語の一致が必要です。Command Line Tools（コマンドで開発するためのApple製ツール。Gitを含む）だけで導入できます。フルXcodeは不要です（Xcode 27も使用可）。Homebrew・OpenSSL 3の追加導入も不要です。/Applicationsへ書き込めるアカウント（通常は管理者）と2 GBの空き容量が必要です。
0.1.0はApple M1 MacBook Air（メモリ8 GB、macOS 27.2、フルXcode 27.2）で導入済みです。0.1.1はCommand Line Toolsだけで、Apple M5 Maxでのビルドと、Apple M1 MacBook Air（macOS 27.2）での新規導入を確認済みです。OpenSSL 3がないMacでの導入は未確認です。Core 3搭載Macは未確認です。

手順:
1. まず読取りだけでmacOSの版、Command Line Toolsの有無、~/Developer/ItJustTalksがDesktop・Documents・iCloud Drive・File Provider配下でないこと、/Applications/ItJustTalks.appの有無を確認してください。
2. 次に承認事項を1通にまとめ、ユーザーから一括で承認を得てください：(1) ~/Developer/ItJustTalksへのgit cloneと書込み、(2) 必要時の「ItJustTalks Dev」証明書の作成・ログインキーチェーンへの登録・コード署名だけの信頼設定、(3) /Applicationsへの配置、(4) 制限されたサンドボックスがある場合、scripts/install.shとそこから呼ぶスクリプトに限ったサンドボックス外の実行。ユーザーが操作する画面も説明してください：不足時だけCommand Line Toolsの導入画面、キーチェーンの認証画面（Touch ID／パスワード。導入中に1〜2回出ることがあり、どれも本人が承認します）、導入後のFinderからの起動とマイク・音声認識・アクセシビリティの許可画面です。拒否されたら停止してください。この承認は他の保護設定の変更を許可しません。
3. Command Line Toolsがなければ、ユーザーに xcode-select --install の実行・macOS画面での承認を依頼し、完了を待ってください。フルXcodeは不要です。証明書を手作業で作るよう依頼しないでください。Keychain Accessの手順は、スクリプトが失敗してその案内を出した場合だけの最終手段です。
4. git clone https://github.com/GrShin5/ItJustTalks ~/Developer/ItJustTalks で取得してください。ZIPは使わないでください。既存cloneを含めremote・ブランチ・git status --shortを確認し、取得元不一致・変更・競合なら停止してください。docs/manual/ja.mdの付録B、scripts/install.shとそこから呼ぶ全スクリプトを読み、内容を確認してください。
5. ソースフォルダで ITJUSTTALKS_LANG=ja bash scripts/install.sh --allow-signing-cert を実行してください。ツールの不備は証明書操作より先に検出されます。証明書は再利用されます。duplicate（同名が複数）やinaccessible（キーチェーン不達）なら新規作成せず停止します。終了コード3なら、表示された「あなたがやること」をユーザーに伝えてください（多くは認証画面を閉じた・時間切れの場合です）。ユーザーの準備ができたら同じコマンドを再実行し、その途中で出るmacOSの認証画面をユーザーに承認してもらってください。終了コード2やその他のエラーでは停止して説明してください。既存アプリは上書き・移動せず、異なるアプリなら更新用プロンプトへ案内してください。同じソースから作ったアプリが既に入っていれば「既にインストール済みです」と表示して終了します。
6. 配置場所、Info.plistの版、ソースコミット、検証結果、残る操作を短く報告してください。ユーザーにFinderからの起動、マイク・音声認識・アクセシビリティの許可、Apple IntelligenceとMac／Siriの言語一致の確認、短い合成文の入力テストを案内してください。導入やビルドの成功は実機テスト合格ではありません。

エージェントのサンドボックス（コマンドの動作範囲を制限する仕組み）では、Swiftのプラグインサーバー、署名の信頼判定（CSSMERR_TP_NOT_TRUSTED）、キーチェーン、~/Developerや/Applicationsへの書込みが失敗する場合があります。Macの故障とは限りません。`codesign -dvv` の表示の署名者欄が Authority=(unavailable) になることもありますが、署名者の不一致とは限りません。署名の照合は scripts/verify_app_identity.sh で行い、不合格なら停止してください。承認済みの実行範囲で再実行し、検証を無効にして通さないでください。

スクリプトの表示言語は環境変数ITJUSTTALKS_LANG（jaまたはen）、なければロケールに従い、ロケールが未設定・C・POSIXなら日本語です。ユーザーが英語を読む場合は、スクリプトの前にITJUSTTALKS_LANG=enを付けてください。
```
