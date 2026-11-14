import Foundation
import FoundationModels
import Testing
@testable import ItJustTalksAI

private func usage(_ output: Int) -> TokenUsage { TokenUsage(inputTokens: 100, outputTokens: output) }

private func runPipeline(
    _ input: CleanupInput, fake: FakeGenerator, deadline: DeadlinePolicy = roomyDeadline
) async -> CleanupResult? {
    let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
    let outcome = await CleanupPipeline().run(input, operation: UUID(), coordinator: coordinator, deadline: deadline)
    guard case .delivered(let result) = outcome else { return nil }
    return result
}

private let plainInput = CleanupInput(transcript: "えーと、明日の会議は午後3時からです", promptLanguage: .ja, handsFree: false)
private let correctionInput = CleanupInput(transcript: "椅子を六脚、いや八脚お願いします", promptLanguage: .ja, handsFree: true)
private let correctionJSON = "{\"corrections\": [{\"retracted\": \"六脚\", \"replacement\": \"八脚\"}]}"

@Suite("CleanupPipeline")
struct CleanupPipelineTests {
    @Test func chunkingPreservesCustomInstructionWhenMinimumBodyFits() async throws {
        let body = String(repeating: "あ", count: 1200)
        let custom = String(repeating: "い", count: 2000)
        let probe = FakeGenerator()
        let fixed = try await probe.tokenCount(for: .instructions(PromptCatalog.template(.cleanup, language: .ja).text))
        let prompt = PromptAssembler.cleanupPrompt(transcript: body, stylePreferences: custom, language: .ja)
        let full = try await probe.tokenCount(for: .prompt(prompt))
        let bodyTokens = try await probe.tokenCount(for: .prompt(body))
        // Actual overhead + 800 tokens fits the full body without custom preferences, but requires
        // chunks with preferences. Still leaves much more than the minimum chunk body.
        let context = fixed + full + ContextBudgeter().configuration.profiles[.cleanup]!.reservation.reservation(forBodyTokens: bodyTokens) - 500
        let budget = BudgetInput(task: .cleanup, contextSize: context, fixedInstructionTokens: fixed,
                                 promptTokens: full, bodyTokens: bodyTokens)
        guard case .needsChunking = ContextBudgeter().decide(budget) else { Issue.record("Fixture must need chunking"); return }
        let fake = FakeGenerator(contextSize: context)
        let result = await runPipeline(CleanupInput(transcript: body, customInstruction: custom,
                                       promptLanguage: .ja, handsFree: false), fake: fake)
        #expect(result?.status == .failed(.generationError))
        #expect(result?.diagnostics.budgetStop == nil)
        #expect(fake.receivedRequests.count == 1)
        #expect(fake.receivedRequests.first?.prompt.contains(custom) == true)
        let tooLongBody = await runPipeline(CleanupInput(transcript: body + body + body, customInstruction: custom,
                                            promptLanguage: .ja, handsFree: false), fake: FakeGenerator(contextSize: context))
        #expect(tooLongBody?.status == .failed(.generationError))
    }

    @Test func longCustomInstructionIsDistinctFromLongBody() async {
        let entries = (0..<1000).map { DictionaryEntry(preferred: "Product\($0)", readings: ["alias\($0),別名\($0)"]) }
        let instruction = String(repeating: "あ", count: 20_000)
        for handsFree in [false, true] {
            let fake = FakeGenerator()
            let input = CleanupInput(transcript: "alias999 の資料です。", customInstruction: instruction,
                                     dictionaryEntries: entries, promptLanguage: .ja, handsFree: handsFree)
            let result = await runPipeline(input, fake: fake)
            #expect(result?.status == .failed(.customInstructionTooLong))
            #expect(result?.diagnostics.budgetStop == .impossible(.customInstructionTooLong))
            #expect(result?.diagnostics.dictionarySelected == 1)
            #expect(fake.receivedRequests.isEmpty)
            #expect(input.customInstruction == instruction && input.dictionaryEntries == entries)
        }
        let fake = FakeGenerator()
        let body = CleanupInput(transcript: String(repeating: "あ", count: 200_000), customInstruction: "丁寧に。",
                                promptLanguage: .ja, handsFree: false)
        #expect(await runPipeline(body, fake: fake)?.status == .failed(.contextSizeExceeded))
    }

    @Test func trailingWhitespaceNormalizationPreservesInnerSpacesAndLineBreaks() {
        #expect(CleanupPipeline.trimmingTrailingLineWhitespace("  first  word \t\n\t\nsecond\tword  \r\nthird \rfinal\t ")
            == "  first  word\n\nsecond\tword\r\nthird\rfinal")
        #expect(CleanupPipeline.trimmingTrailingLineWhitespace("first\n\nlast\n") == "first\n\nlast\n")
    }

    @Test func normalizedOutputIsReturnedAndValidatedWithOrWithoutPreferences() async {
        for custom in [nil, "一文ごとに改行する"] as [String?] {
            let input = CleanupInput(transcript: "明日は会議です。資料を確認してください。",
                                     customInstruction: custom, promptLanguage: .ja, handsFree: false)
            let fake = FakeGenerator(script: [.init(.text("明日は会議です。  \n資料を確認してください。\t ", usage: usage(12)))])
            let result = await runPipeline(input, fake: fake)
            #expect(result?.text == "明日は会議です。\n資料を確認してください。")
            #expect(result?.status == .complete)
            #expect(result?.diagnostics.validation?.outcome == .complete)
        }
    }

    @Test func bulletRequestEndingExemptionRequiresPreferencesAndNormalMode() async {
        for custom in [nil, "", " \t\n", "箇条書きにする"] as [String?] {
            for handsFree in [false, true] {
                let input = CleanupInput(transcript: "資料と見積もりを確認してください",
                                         customInstruction: custom, promptLanguage: .ja, handsFree: handsFree)
                let fake = FakeGenerator(script: [.init(.text("・資料を確認  \n・見積もりを確認\t", usage: usage(12)))])
                let result = await runPipeline(input, fake: fake)
                #expect(result?.text == "・資料を確認\n・見積もりを確認")
                let outcome = result?.diagnostics.validation?.outcome
                #expect(outcome != nil)
                #expect(outcome?.reasons.contains(.requestEndingLost) == (handsFree || custom != "箇条書きにする"))
            }
        }
    }

    @Test func completeCleanup() async {
        let fake = FakeGenerator(script: [.init(.text("明日の会議は午後3時からです。", usage: usage(12)))])
        let result = await runPipeline(plainInput, fake: fake)
        #expect(result?.status == .complete)
        #expect(result?.text == "明日の会議は午後3時からです。")
        #expect(result?.diagnostics.calls.map(\.stage) == [.cleanup])
        #expect(result?.diagnostics.contextSize == 4096)
        #expect(result?.diagnostics.variantName == "fake")
        #expect(result?.diagnostics.outputTokens == 12)
        let request = fake.receivedRequests.first
        #expect(request?.greedy == true)
        #expect(request?.guardrails == .permissiveContentTransformations)
    }

    @Test func twoStageCleanupAppliesSpans() async {
        let fake = FakeGenerator(script: [
            .init(.text(correctionJSON, usage: usage(20))),
            .init(.text("椅子を八脚お願いします。", usage: usage(10))),
        ])
        let result = await runPipeline(correctionInput, fake: fake)
        #expect(result?.status == .complete)
        #expect(result?.diagnostics.calls.map(\.stage) == [.selfCorrection, .cleanup])
        #expect(result?.diagnostics.measures["stageA.applied"] == 1)
        #expect(result?.diagnostics.promptKeys.count == 2)
        // Stage B saw the corrected transcript.
        #expect(fake.receivedRequests.last?.prompt.contains("六脚") == false)
    }

    /// A dictionary entry found only by sound is applied normally but never sent in hands-free mode.
    @Test func soundOnlyDictionaryReplacementNeedsReviewInHandsFree() async {
        let entries = [DictionaryEntry(preferred: "渡邉", readings: ["わたなべ"])]
        for handsFree in [false, true] {
            let input = CleanupInput(
                transcript: "渡辺部長に確認をお願いします", dictionaryEntries: entries, promptLanguage: .ja, handsFree: handsFree
            )
            let fake = FakeGenerator(script: [.init(.text("渡邉部長に確認をお願いします。", usage: usage(12)))])
            let result = await runPipeline(input, fake: fake)
            #expect(result?.diagnostics.dictionarySelected == 1)
            #expect(fake.receivedRequests.last?.prompt.contains("表記：渡邉（聞き取り例：わたなべ）") == true)
            #expect(result?.status == (handsFree ? .needsReview([.unverifiedDictionaryReplacement]) : .complete))
        }
    }

    /// Hands-free: an entry matched literally does not license rewriting a homophone elsewhere (砂糖 → 佐藤).
    @Test func literalDictionaryEntryDoesNotLicenseExtraUsesInHandsFree() async {
        let entries = [DictionaryEntry(preferred: "佐藤", readings: ["さとう"])]
        let input = CleanupInput(
            transcript: "さとうさんに砂糖を渡してください", dictionaryEntries: entries, promptLanguage: .ja, handsFree: true
        )
        let fake = FakeGenerator(script: [.init(.text("佐藤さんに佐藤を渡してください。", usage: usage(12)))])
        let result = await runPipeline(input, fake: fake)
        #expect(result?.status == .needsReview([.unverifiedDictionaryReplacement]))
        let faithful = FakeGenerator(script: [.init(.text("佐藤さんに砂糖を渡してください。", usage: usage(12)))])
        #expect(await runPipeline(input, fake: faithful)?.status == .complete)
    }

    @Test func literalDictionarySubstitutionBeforeAndAfterGeneration() async {
        for handsFree in [false, true] {
            for (transcript, reading, preferred, output, expected) in [
                ("コーデックスの優先度を確認してください", "コーデックス", "Codex", "コーデックスの優先度を確認してください。", "Codexの優先度を確認してください。"),
                ("ユーセージを確認してください", "ユーセージ", "Usage", "Usageを確認してください。", "Usageを確認してください。"),
                ("タップナウで画像を作る", "タップナウ", "TapNow", "TapNowで画像を作る。", "TapNowで画像を作る。"),
                ("コミットアンドプッシュしてください", "コミットアンドプッシュ", "Commit&Push", "Commit&Pushしてください。", "Commit&Pushしてください。"),
            ] {
                let input = CleanupInput(transcript: transcript, dictionaryEntries: [
                    DictionaryEntry(preferred: preferred, readings: [reading]),
                ], promptLanguage: .ja, handsFree: handsFree)
                let fake = FakeGenerator(script: [.init(.text(output, usage: usage(12)))])
                let result = await runPipeline(input, fake: fake)
                #expect(result?.status == .complete)
                #expect(result?.text == expected)
                #expect(result?.diagnostics.measures["dictionary.substitutions"] == 1)
                #expect(fake.receivedRequests.last?.prompt.contains(String(expected.dropLast())) == true)
            }
        }
    }

    @Test func literalAddressesSymbolsAndFixedPhrasesComplete() async {
        for handsFree in [false, true] {
            for (transcript, reading, preferred, expected) in [
                ("オフィス住所を入力して", "オフィス住所", "東京都渋谷区架空町1番地", "東京都渋谷区架空町1番地を入力して"),
                ("請求書の送付先はオフィス住所です", "オフィス住所", "東京都渋谷区架空町1番地", "請求書の送付先は東京都渋谷区架空町1番地です"),
                ("矢印右を入れてください", "矢印右", "→", "→を入れてください"),
                ("定型挨拶", "定型挨拶", "お世話になっております。\nよろしくお願いします。", "お世話になっております。\nよろしくお願いします。"),
            ] {
                let input = CleanupInput(transcript: transcript, dictionaryEntries: [
                    DictionaryEntry(preferred: preferred, readings: [reading]),
                ], promptLanguage: .ja, handsFree: handsFree)
                let fake = FakeGenerator(script: [.init(.text(expected, usage: usage(30)))])
                let result = await runPipeline(input, fake: fake)
                #expect(result?.status == .complete)
                #expect(result?.text == expected)
                #expect(result?.diagnostics.measures["dictionary.substitutions"] == 1)
                #expect(fake.receivedRequests.last?.prompt.contains(expected) == true)
            }
        }
    }

    @Test func modelOnlyReadingsAreNeverSubstituted() async {
        for handsFree in [false, true] {
            for code in ["ja", "en"] {
                let input = CleanupInput(transcript: "明日の会議は午後三時です", dictionaryEntries: [
                    DictionaryEntry(preferred: "東京都架空区", readings: ["オフィス住所"]),
                ], promptLanguage: .ja, outputLanguage: OutputLanguage(code: code, name: code), handsFree: handsFree)
                let result = await runPipeline(input, fake: FakeGenerator(script: [.init(.text("オフィス住所", usage: usage(8)))]))
                #expect(result?.text == "オフィス住所")
                #expect(result?.diagnostics.measures["dictionary.substitutions"] == 0)
            }
        }
    }

    @Test func unspokenOrRepeatedSymbolCannotBecomeComplete() async {
        for handsFree in [false, true] {
            for (source, output) in [("えーと", "→"), ("えーと", "→→→"), ("右矢印", "→→→")] {
                let input = CleanupInput(transcript: source, dictionaryEntries: [
                    DictionaryEntry(preferred: "→", readings: ["右矢印"]),
                ], promptLanguage: .ja, handsFree: handsFree)
                let result = await runPipeline(input, fake: FakeGenerator(script: [.init(.text(output, usage: usage(3)))]))
                #expect(result?.status != .complete)
            }
        }
    }

    @Test func fixedPhraseWithFidelityKeywords() async {
        let phrase = "あの件はいやだとは言っていません。"
        for handsFree in [false, true] {
            let input = CleanupInput(transcript: "定型説明", dictionaryEntries: [
                DictionaryEntry(preferred: phrase, readings: ["定型説明"]),
            ], promptLanguage: .ja, handsFree: handsFree)
            let result = await runPipeline(input, fake: FakeGenerator(script: [.init(.text(phrase, usage: usage(15)))]))
            #expect(result?.text == phrase)
            #expect(result?.status == .complete)
            for reason in [ValidationReason.residualFiller, .selfCorrectionKept, .negationChanged] {
                #expect(result?.diagnostics.validation?.outcome.reasons.contains(reason) == false)
            }
        }
    }

    @Test func registeredSymbolAloneIsNotEmptyOutput() async {
        for handsFree in [false, true] {
            let input = CleanupInput(transcript: "右矢印", dictionaryEntries: [DictionaryEntry(preferred: "→", readings: ["右矢印"])],
                promptLanguage: .ja, handsFree: handsFree)
            let result = await runPipeline(input, fake: FakeGenerator(script: [.init(.text("→", usage: usage(2)))]))
            #expect(result?.status == .complete)
            #expect(result?.text == "→")
            let empty = await runPipeline(CleanupInput(transcript: "えーと", promptLanguage: .ja, handsFree: handsFree),
                fake: FakeGenerator(script: [.init(.text("。", usage: usage(1)))]))
            #expect(empty?.status != .complete)
        }
    }

    @Test func dictionaryOnlyAndOriginalASCIIWordsAreLanguageNeutral() async {
        for handsFree in [false, true] {
            for outputLanguage in [nil, OutputLanguage(code: "ja", name: "日本語")] {
                for (transcript, entries, output) in [
                    ("コーデックスアップサーバー", [DictionaryEntry(preferred: "Codex App Server", readings: ["コーデックスアップサーバー"])], "Codex App Server"),
                    ("アスクユーザーインプット。", [DictionaryEntry(preferred: "ask_user_input", readings: ["アスクユーザーインプット"])], "ask_user_input。"),
                    ("コーデックス", [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])], "Codex"),
                    ("タイプレスとHeyCodex", [DictionaryEntry(preferred: "Typeless", readings: ["タイプレス"])], "TypelessとHeyCodex"),
                ] {
                    let input = CleanupInput(transcript: transcript, dictionaryEntries: entries,
                        promptLanguage: .ja, outputLanguage: outputLanguage, handsFree: handsFree)
                    let result = await runPipeline(input, fake: FakeGenerator(script: [.init(.text(output, usage: usage(12)))]))
                    #expect(result?.status == .complete, "\(transcript) hf=\(handsFree) \(outputLanguage?.code ?? "auto") \(String(describing: result?.status))")
                }
                let translated = CleanupInput(transcript: "コーデックスとタイプレスを使う", dictionaryEntries: [
                    DictionaryEntry(preferred: "Codex", readings: ["コーデックス"]),
                    DictionaryEntry(preferred: "Typeless", readings: ["タイプレス"]),
                ], promptLanguage: .ja, outputLanguage: outputLanguage, handsFree: handsFree)
                let result = await runPipeline(translated, fake: FakeGenerator(script: [.init(.text("Use Codex and Typeless.", usage: usage(12)))]))
                #expect(result?.status != .complete)
                #expect(result?.diagnostics.validation?.outcome.reasons.contains {
                    if case .languageMismatch = $0 { return true }
                    return false
                } == true)
            }
        }
    }

    @Test func selfCorrectionWithLiteralDictionaryReading() async {
        let input = CleanupInput(
            transcript: "コーデックスの設定、いやコーデックスの優先度を確認してください",
            dictionaryEntries: [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])],
            promptLanguage: .ja, handsFree: true
        )
        let json = "{\"corrections\": [{\"retracted\": \"コーデックスの設定\", \"replacement\": \"コーデックスの優先度\"}]}"
        let fake = FakeGenerator(script: [.init(.text(json, usage: usage(20))),
                                         .init(.text("コーデックスの優先度を確認してください。", usage: usage(12)))])
        let result = await runPipeline(input, fake: fake)
        #expect(result?.status == .complete)
        #expect(result?.text == "Codexの優先度を確認してください。")
        #expect(result?.text?.contains("設定") == false)
        #expect(result?.diagnostics.measures["dictionary.substitutions"] == 1)
        let retained = FakeGenerator(script: [.init(.text(json, usage: usage(20))),
            .init(.text("Codexの設定とCodexの優先度を確認してください。", usage: usage(12)))])
        let rejected = await runPipeline(input, fake: retained)
        #expect(rejected?.status != .complete)
    }

    @Test func dictionaryNamesDoNotChangeLanguageDecisions() async {
        let input = CleanupInput(
            transcript: "コーデックスとタイプレスを使う",
            dictionaryEntries: [DictionaryEntry(preferred: "The Advanced Code Assistant", readings: ["コーデックス"]),
                                DictionaryEntry(preferred: "The Modern Voice Input", readings: ["タイプレス"])],
            promptLanguage: .ja, outputLanguage: OutputLanguage(code: "ja", name: "日本語"), handsFree: true
        )
        let fake = FakeGenerator(script: [.init(.text("コーデックスとタイプレスを使う。", usage: usage(12)))])
        let result = await runPipeline(input, fake: fake)
        #expect(result?.status == .complete)
        #expect(result?.text == "The Advanced Code AssistantとThe Modern Voice Inputを使う。")
        #expect(result?.diagnostics.validation?.outcome.reasons.contains(.overlapUnverifiable) == false)
        #expect(result?.diagnostics.validation?.metrics.detectedLanguage == nil)
    }

    @Test func shortLanguageRemainderMustContainExpectedScript() async {
        let entries = [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"]),
                       DictionaryEntry(preferred: "Typeless", readings: ["タイプレス"])]
        let input = CleanupInput(
            transcript: "コーデックスとタイプレスを使う", dictionaryEntries: entries,
            promptLanguage: .ja, outputLanguage: OutputLanguage(code: "ja", name: "日本語"), handsFree: true
        )
        for output in ["Use Codex and Typeless.", "Use codex and typeless."] {
            let fake = FakeGenerator(script: [.init(.text(output, usage: usage(12)))])
            let result = await runPipeline(input, fake: fake)
            #expect(result?.status != .complete)
            #expect(result?.diagnostics.validation?.outcome.reasons.contains {
                if case .languageMismatch = $0 { return true }
                return false
            } == true)
        }
        for output in ["Codexとタイプレスを使う。", "codexとtypelessを使う。"] {
            let fake = FakeGenerator(script: [.init(.text(output, usage: usage(12)))])
            let result = await runPipeline(input, fake: fake)
            #expect(result?.status == .complete)
            // The full output exceeds the language threshold; case-insensitive name removal leaves Japanese.
            #expect(result?.diagnostics.validation?.metrics.detectedLanguage == nil)
        }
    }

    @Test func shortLanguageRemainderUsesSpokenLanguageWhenOutputLanguageIsAutomatic() async {
        let entries = [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"]),
                       DictionaryEntry(preferred: "Typeless", readings: ["タイプレス"])]
        let input = CleanupInput(
            transcript: "コーデックスとタイプレスを使う", dictionaryEntries: entries, promptLanguage: .ja, handsFree: true
        )
        let english = await runPipeline(input, fake: FakeGenerator(script: [.init(.text("Use Codex and Typeless.", usage: usage(12)))]))
        #expect(english?.status != .complete)
        let japanese = await runPipeline(input, fake: FakeGenerator(script: [.init(.text("CodexとTypelessを使う。", usage: usage(12)))]))
        #expect(japanese?.status == .complete)
        let latinLed = CleanupInput(
            transcript: "It just talksで入力テスト中", dictionaryEntries: [DictionaryEntry(preferred: "ItJustTalks", readings: ["it just talks"])],
            promptLanguage: .ja, handsFree: true
        )
        let latinLedResult = await runPipeline(latinLed, fake: FakeGenerator(script: [.init(.text("ItJustTalksで入力テスト中", usage: usage(12)))]))
        #expect(latinLedResult?.status == .complete)
    }

    @Test func embeddedRetractedReadingIsStillRejected() async {
        let input = CleanupInput(
            transcript: "ベータコーデックス、いやクロードを使う。コードエックスの設定も確認",
            dictionaryEntries: [DictionaryEntry(preferred: "Codex", readings: ["コーデックス", "コードエックス"])],
            promptLanguage: .ja, handsFree: true
        )
        let json = "{\"corrections\": [{\"retracted\": \"コーデックス\", \"replacement\": \"クロード\"}]}"
        let fake = FakeGenerator(script: [.init(.text(json, usage: usage(20))),
            .init(.text("ベータコーデックスとクロードを使う。コードエックスの設定も確認。", usage: usage(12)))])
        let result = await runPipeline(input, fake: fake)
        #expect(result?.diagnostics.validation?.outcome.reasons.contains(.selfCorrectionKept) == true)
    }

    @Test func truncation() async {
        let fake = FakeGenerator(script: [.init(.text("明日の会議は", usage: usage(100_000)))])
        let result = await runPipeline(plainInput, fake: fake)
        #expect(result?.status == .failed(.validationFailed))
        #expect(result?.diagnostics.validation?.outcome.reasons.contains(.truncated) == true)
    }

    @Test func refusal() async {
        let fake = FakeGenerator(script: [.init(.failure(.refusal)), .init(.text("never"))])
        let result = await runPipeline(plainInput, fake: fake)
        #expect(result?.status == .failed(.guardrail))
        #expect(result?.text == nil)
        #expect(fake.receivedRequests.count == 1)
    }

    @Test func emptyOutput() async {
        let fake = FakeGenerator(script: [.init(.text("", usage: usage(1)))])
        let result = await runPipeline(plainInput, fake: fake)
        #expect(result?.status == .failed(.validationFailed))
        #expect(result?.diagnostics.validation?.outcome.reasons.contains(.emptyOutput) == true)
    }

    @Test func delayedResponsePastDeadline() async {
        let fake = FakeGenerator(script: [.init(.text("明日の会議は午後3時からです。", usage: usage(12)), delay: .seconds(5))])
        let start = ContinuousClock.now
        let result = await runPipeline(plainInput, fake: fake, deadline: DeadlinePolicy(cap: .milliseconds(200)))
        #expect(result?.status == .failed(.timeout))
        #expect(result?.text == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func responseAfterCancelIsNotDelivered() async {
        let fake = FakeGenerator(script: [.init(.text("明日の会議は午後3時からです。", usage: usage(12)), delay: .seconds(5))])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let operation = UUID()
        let task = Task { await CleanupPipeline().run(plainInput, operation: operation, coordinator: coordinator) }
        await eventually { !fake.receivedRequests.isEmpty }
        await coordinator.cancel(operation: operation)
        #expect(cancellation(await task.value) == .cancelled)
    }

    @Test func rateLimitedThenSuccess() async {
        let fake = FakeGenerator(script: [
            .init(.failure(.rateLimited(resetDate: nil))),
            .init(.text("明日の会議は午後3時からです。", usage: usage(12))),
        ])
        let result = await runPipeline(plainInput, fake: fake)
        #expect(result?.status == .complete)
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func rateLimitedTwice() async {
        let fake = FakeGenerator(script: [
            .init(.failure(.rateLimited(resetDate: nil))),
            .init(.failure(.rateLimited(resetDate: nil))),
            .init(.text("never")),
        ])
        let result = await runPipeline(plainInput, fake: fake)
        #expect(result?.status == .failed(.rateLimited))
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func contextSizeExceededFromFramework() async {
        let fake = FakeGenerator(script: [.init(.failure(.contextSizeExceeded(contextSize: 4096, tokenCount: 5000)))])
        let result = await runPipeline(plainInput, fake: fake)
        #expect(result?.status == .failed(.contextSizeExceeded))
        #expect(fake.receivedRequests.count == 1)
    }

    @Test func longBodyRunsChunkGeneration() async {
        let long = CleanupInput(transcript: String(repeating: "明日の会議は午後3時からです。", count: 400), promptLanguage: .ja, handsFree: false)
        let fake = FakeGenerator(script: [.init(.text("never"))])
        let result = await runPipeline(long, fake: fake)
        // "never" fails validation against chunk 1: the run stops before chunk 2 (no partial text is applied).
        #expect(result?.status == .failed(.validationFailed))
        #expect((result?.diagnostics.measures["chunk.count"] ?? 0) > 1)
        #expect(fake.receivedRequests.count == 1)
    }

    @Test func unavailable() async {
        let fake = FakeGenerator(availability: .unavailable(.modelNotReady))
        let result = await runPipeline(plainInput, fake: fake)
        #expect(result?.status == .failed(.modelNotReady))
    }

    @Test func stageAFailureFallsBackToSingleStage() async {
        let fake = FakeGenerator(script: [
            .init(.failure(.refusal)),
            .init(.text("椅子を八脚お願いします。", usage: usage(10))),
        ])
        let result = await runPipeline(correctionInput, fake: fake)
        #expect(result?.diagnostics.measures["stageA.failed"] == 1)
        #expect(result?.diagnostics.calls.map(\.stage) == [.selfCorrection, .cleanup])
        #expect(result?.text == "椅子を八脚お願いします。")
    }

    @Test func hangingTokenCountTimesOutAndReleasesTheSlot() async {
        let fake = FakeGenerator(script: [.init(.text("明日の会議は午後3時からです。", usage: usage(12)))])
        let hanging = HangingTokenCountGenerator(base: fake, hangingCalls: 1)
        let coordinator = GenerationCoordinator(generator: hanging, configuration: fastConfiguration)
        let start = ContinuousClock.now
        let first = await CleanupPipeline().run(
            plainInput, operation: UUID(), coordinator: coordinator, deadline: DeadlinePolicy(cap: .milliseconds(200))
        )
        guard case .delivered(let timedOut) = first else { Issue.record("cancelled"); return }
        #expect(timedOut.status == .failed(.timeout))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(fake.receivedRequests.isEmpty)
        // The next operation runs normally.
        let second = await CleanupPipeline().run(plainInput, operation: UUID(), coordinator: coordinator, deadline: roomyDeadline)
        guard case .delivered(let completed) = second else { Issue.record("cancelled"); return }
        #expect(completed.status == .complete)
    }

    @Test func cancelDuringHangingTokenCount() async {
        let fake = FakeGenerator(script: [.init(.text("never"))])
        let hanging = HangingTokenCountGenerator(base: fake, hangingCalls: 1)
        let coordinator = GenerationCoordinator(generator: hanging, configuration: fastConfiguration)
        let operation = UUID()
        let task = Task { await CleanupPipeline().run(plainInput, operation: operation, coordinator: coordinator) }
        await eventually { hanging.hangsStarted > 0 }
        let cancelAt = ContinuousClock.now
        await coordinator.cancel(operation: operation)
        #expect(cancellation(await task.value) == .cancelled)
        #expect(ContinuousClock.now - cancelAt < .seconds(1))
        #expect(fake.receivedRequests.isEmpty)
    }

    @Test func stageARateLimitedTwiceEndsWithoutCleanupCall() async {
        let fake = FakeGenerator(script: [
            .init(.failure(.rateLimited(resetDate: nil))),
            .init(.failure(.rateLimited(resetDate: nil))),
            .init(.text("椅子を八脚お願いします。", usage: usage(10))),
        ])
        let result = await runPipeline(correctionInput, fake: fake)
        #expect(result?.status == .failed(.rateLimited))
        #expect(fake.receivedRequests.count == 2)
        #expect(result?.diagnostics.calls.map(\.stage) == [.selfCorrection])
    }

    @Test func stageATimeoutEndsWithoutCleanupCall() async {
        let fake = FakeGenerator(script: [
            .init(.text(correctionJSON, usage: usage(20)), delay: .seconds(5)),
            .init(.text("椅子を八脚お願いします。", usage: usage(10))),
        ])
        let result = await runPipeline(correctionInput, fake: fake, deadline: DeadlinePolicy(cap: .milliseconds(200)))
        #expect(result?.status == .failed(.timeout))
        #expect(fake.receivedRequests.count == 1)
    }

    @Test func diagnosticsCarryNoText() async {
        let fake = FakeGenerator(script: [
            .init(.text(correctionJSON, usage: usage(20))),
            .init(.text("椅子を八脚お願いします。", usage: usage(10))),
        ])
        guard let result = await runPipeline(correctionInput, fake: fake) else { Issue.record("cancelled"); return }
        let dump = String(describing: result.diagnostics)
        for fragment in ["椅子", "六脚", "八脚", "お願い"] { #expect(!dump.contains(fragment)) }
    }
}

// MARK: - Equivalence with the pre-move afm-eval cleanup

/// Frozen copy of the afm-eval cleanup flow before it moved into the library (Tools/afm-eval StageA.swift +
/// Pipelines.cleanup, `--correction-method spans --guardrails auto`), minus the eval bookkeeping. The
/// pipeline must produce the same requests, output, spans and validation for the same scripted replies.
private struct ReferenceOutcome: Equatable {
    var requests: [GenerationRequest]
    var output: String?
    var report: ValidationReport?
    var failure: AIFailure?
    var measures: [String: Double]
    var promptKeys: [String]
    var dictionarySelected: Int
    var dictionaryOmitted: Int
}

private struct ReferenceItem: Sendable {
    var transcript: String
    var customInstruction: String?
    var dictionary: [DictionaryEntry]
    var outputLanguage: OutputLanguage?
    var handsFree: Bool
    var language: PromptLanguage
}

private func referenceBudget(
    _ generator: FakeGenerator, task: AITask, instructions: String, prompt: String, body: String, schemaTokens: Int = 0
) async -> (Int?, [String: Double]) {
    let fixed = (try? await generator.tokenCount(for: .instructions(instructions))) ?? 0
    let promptTokens = (try? await generator.tokenCount(for: .prompt(prompt))) ?? 0
    let bodyTokens = body.isEmpty ? 0 : min((try? await generator.tokenCount(for: .prompt(body))) ?? 0, promptTokens)
    var measures: [String: Double] = [
        "budget.contextSize": Double(generator.contextSize),
        "budget.fixedInstructionTokens": Double(fixed),
        "budget.promptTokens": Double(promptTokens),
        "budget.bodyTokens": Double(bodyTokens),
        "budget.schemaTokens": Double(schemaTokens),
    ]
    let decision = ContextBudgeter().decide(BudgetInput(
        task: task, contextSize: generator.contextSize, fixedInstructionTokens: fixed,
        promptTokens: promptTokens, bodyTokens: bodyTokens, schemaTokens: schemaTokens
    ))
    guard case .fits(let maximum) = decision else { return (nil, measures) }
    measures["budget.maxResponseTokens"] = Double(maximum)
    return (maximum, measures)
}

private func referenceCleanup(_ item: ReferenceItem, generator: FakeGenerator) async -> ReferenceOutcome {
    let language = item.language
    var measures: [String: Double] = [:]
    var promptKeys: [String] = []
    // Stage A
    var transcript = item.transcript
    var spans: [SelfCorrectionSpan]?
    if SelfCorrection.hasCue(in: item.transcript) {
        measures["stageA.ran"] = 1
        let template = PromptCatalog.template(.selfCorrection, language: language)
        promptKeys.append(template.key)
        let prompt = PromptAssembler.selfCorrectionPrompt(transcript: item.transcript, language: language)
        let schemaTokens = (try? await generator.schemaTokenCount(for: SelfCorrectionList.self)) ?? 0
        let (maxTokens, _) = await referenceBudget(
            generator, task: .selfCorrection, instructions: template.text, prompt: prompt, body: item.transcript, schemaTokens: schemaTokens
        )
        if let maxTokens {
            let request = GenerationRequest(
                instructions: template.text, prompt: prompt, maximumResponseTokens: maxTokens, greedy: true,
                guardrails: AITask.selfCorrection.guardrails
            )
            do {
                let value = try await generator.generate(request, generating: SelfCorrectionList.self)
                if let usage = value.usage {
                    measures["stageA.inputTokens"] = Double(usage.inputTokens)
                    measures["stageA.outputTokens"] = Double(usage.outputTokens)
                }
                if value.isTruncated { measures["stageA.truncated"] = 1 }
                let proposals = value.value.corrections.map { ($0.retracted, $0.replacement) }
                measures["stageA.proposals"] = Double(proposals.count)
                let outcome = SelfCorrection.apply(proposals, to: item.transcript)
                measures["stageA.verifiedProposals"] = Double(outcome.verifiedProposals)
                measures["stageA.droppedProposals"] = Double(outcome.droppedProposals)
                spans = outcome.spans
                if let corrected = outcome.corrected {
                    transcript = corrected
                    measures["stageA.applied"] = corrected == item.transcript ? 0 : 1
                } else {
                    measures["stageA.fallback"] = 1
                }
            } catch {
                measures["stageA.failed"] = 1
            }
        } else {
            measures["stageA.skipped"] = 1
        }
    }
    // Stage B
    let template = PromptCatalog.template(.cleanup, language: language)
    promptKeys.append(template.key)
    let selection = DictionarySelector().select(
        entries: item.dictionary, text: transcript,
        options: DictionarySelectionOptions(includeMemo: true, promptLanguage: language)
    )
    let prompt = PromptAssembler.cleanupPrompt(
        // cleanup@6: spellings already resolved literally are not repeated as hints.
        transcript: transcript, dictionaryHints: selection.unresolvedHints(in: transcript), stylePreferences: item.customInstruction,
        outputLanguage: item.outputLanguage, language: language
    )
    let (maxTokens, budgetMeasures) = await referenceBudget(
        generator, task: .cleanup, instructions: template.text, prompt: prompt, body: transcript
    )
    measures.merge(budgetMeasures) { _, new in new }
    var outcome = ReferenceOutcome(
        requests: [], output: nil, report: nil, failure: nil, measures: measures, promptKeys: promptKeys,
        dictionarySelected: selection.selected.count, dictionaryOmitted: selection.omittedCount
    )
    guard let maxTokens else { return outcome }
    let request = GenerationRequest(
        instructions: template.text, prompt: prompt, maximumResponseTokens: maxTokens, greedy: true,
        guardrails: AITask.cleanup.guardrails
    )
    do {
        let generated = try await generator.generate(request)
        outcome.output = generated.text
        outcome.report = ResultValidator().evaluate(ValidationInput(
            task: .cleanup, source: item.transcript, output: generated.text, isTruncated: generated.isTruncated,
            protectedInstructions: [template.text], userSuppliedTexts: [],
            allowedNewTerms: selection.hints.map(\.preferred),
            expectedOutputLanguage: item.outputLanguage?.code, handsFree: item.handsFree, selfCorrections: spans
        ))
    } catch {
        outcome.failure = error
    }
    outcome.requests = generator.receivedRequests
    return outcome
}

private struct EquivalenceCase: Sendable, CustomTestStringConvertible {
    var name: String
    var item: ReferenceItem
    var script: [FakeGenerator.Step]
    var testDescription: String { name }
}

// Legacy equivalence covers unchanged behavior. Filler preprocessing intentionally differs
// from the old evaluator and is covered, including original-source validation, in FillerStripperTests.
private let equivalenceCases: [EquivalenceCase] = [
    EquivalenceCase(
        name: "plain + dictionary + custom instruction",
        item: ReferenceItem(
            transcript: "ルミナ端末の更新は明日の午後3時からです",
            customInstruction: "です・ます調で書く",
            dictionary: [DictionaryEntry(preferred: "ルミナ端末", readings: ["るみなたんまつ"], memo: "社内端末")],
            outputLanguage: nil, handsFree: false, language: .ja
        ),
        script: [.init(.text("ルミナ端末の更新は明日の午後3時からです。", usage: usage(20)))]
    ),
    EquivalenceCase(
        name: "self-correction applied, hands-free",
        item: ReferenceItem(
            transcript: "椅子を六脚、いや八脚お願いします", customInstruction: nil, dictionary: [],
            outputLanguage: nil, handsFree: true, language: .ja
        ),
        script: [.init(.text(correctionJSON, usage: usage(20))), .init(.text("椅子を八脚お願いします。", usage: usage(10)))]
    ),
    EquivalenceCase(
        name: "stage A refusal falls back",
        item: ReferenceItem(
            transcript: "駐車場は使えます、あ、違う、使えません", customInstruction: nil, dictionary: [],
            outputLanguage: nil, handsFree: false, language: .ja
        ),
        script: [.init(.failure(.refusal)), .init(.text("駐車場は使えます、使えません。", usage: usage(10)))]
    ),
    EquivalenceCase(
        name: "english, new number rejected",
        item: ReferenceItem(
            transcript: "so the meeting is at three tomorrow", customInstruction: nil, dictionary: [],
            outputLanguage: OutputLanguage(code: "en", name: "English"), handsFree: true, language: .en
        ),
        script: [.init(.text("The meeting is at 4 tomorrow.", usage: usage(10)))]
    ),
    EquivalenceCase(
        name: "cleanup generation failure",
        item: ReferenceItem(
            transcript: "明日は雨です", customInstruction: nil, dictionary: [], outputLanguage: nil, handsFree: false, language: .ja
        ),
        script: [.init(.failure(.guardrailViolation))]
    ),
]

@Suite("CleanupPipeline equivalence with pre-move afm-eval")
struct CleanupPipelineEquivalenceTests {
    @Test(arguments: equivalenceCases)
    fileprivate func sameAsReference(_ testCase: EquivalenceCase) async {
        let referenceFake = FakeGenerator(script: testCase.script)
        let reference = await referenceCleanup(testCase.item, generator: referenceFake)

        let fake = FakeGenerator(script: testCase.script)
        let input = CleanupInput(
            transcript: testCase.item.transcript, customInstruction: testCase.item.customInstruction,
            dictionaryEntries: testCase.item.dictionary, promptLanguage: testCase.item.language,
            outputLanguage: testCase.item.outputLanguage, handsFree: testCase.item.handsFree
        )
        guard let result = await runPipeline(input, fake: fake) else { Issue.record("cancelled"); return }
        let diagnostics = result.diagnostics
        // Legacy equivalence uses an already preferred spelling; literal substitutions are tested above.
        #expect(diagnostics.measures["dictionary.substitutions"] == 0)
        let measures = diagnostics.measures.filter { !$0.key.hasSuffix("latencyMs") && $0.key != "dictionary.substitutions" }

        #expect(fake.receivedRequests == reference.requests)
        #expect(result.text == reference.output)
        #expect(diagnostics.validation == reference.report)
        #expect(diagnostics.failure == reference.failure)
        #expect(measures == reference.measures)
        #expect(diagnostics.promptKeys == reference.promptKeys)
        #expect(diagnostics.dictionarySelected == reference.dictionarySelected)
        #expect(diagnostics.dictionaryOmitted == reference.dictionaryOmitted)
    }
}

/// Wraps a FakeGenerator; its first `hangingCalls` token counts never return in practice (they ignore
/// cancellation and sleep for a minute).
final class HangingTokenCountGenerator: TextGenerating, @unchecked Sendable {
    private let base: FakeGenerator
    private let lock = NSLock()
    private var remaining: Int
    private var started = 0

    init(base: FakeGenerator, hangingCalls: Int) {
        self.base = base
        self.remaining = hangingCalls
    }

    var hangsStarted: Int { lock.withLock { started } }
    var availability: ModelAvailability { base.availability }
    var contextSize: Int { base.contextSize }
    var variantName: String? { base.variantName }

    func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int {
        let hang: Bool = lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            started += 1
            return true
        }
        if hang { await Task.detached { try? await Task.sleep(for: .seconds(60)) }.value }
        return try await base.tokenCount(for: subject)
    }

    func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int {
        try await base.schemaTokenCount(for: type)
    }

    func generate(_ request: GenerationRequest) async throws(AIFailure) -> GenerationResult {
        try await base.generate(request)
    }

    func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest, generating type: Output.Type
    ) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        try await base.generate(request, generating: type)
    }
}
