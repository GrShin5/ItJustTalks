import Foundation
import Testing
@testable import ItJustTalks

@Suite("Settings UI quality")
@MainActor
struct SettingsUIQualityTests {
    @Test func aiStartRejectsExactAndPrefixHandsFreeConflicts() {
        var settings = ItJustTalksSettings.default
        for enabled in [false, true] {
            settings.handsFreeSendSettings.enabled = enabled
            for binding in [HotkeyBinding.handsFreeSend,
                            HotkeyBinding(keys: [.rightShift]),
                            HotkeyBinding(keys: [.function, .rightShift, .space])] {
                #expect(settings.aiCommandStartConflicts(binding))
            }
            #expect(settings.aiCommandStartConflicts(settings.normalHotkeyBinding))
            #expect(!settings.aiCommandStartConflicts(.aiCommandStart))
        }
    }

    @Test func onboardingAndSettingsShareStartConflictValidation() throws {
        let onboarding = try source("Permissions/OnboardingView.swift")
        let settings = try source("Settings/SettingsView.swift")
        #expect(onboarding.contains("!settingsStore.settings.aiCommandStartConflicts(candidate)"))
        #expect(settings.contains("store.settings.aiCommandStartConflicts(binding)"))
        let error = "通常モードまたはハンズフリー送信モードですでに使われている起動キーです。別のキーを選んでください。"
        #expect(onboarding.contains(error))
        #expect(settings.contains(error))
    }

    @Test(arguments: [false, true])
    func customInstructionWriteFailurePreservesSettingAndAllowsRetry(forAICommand: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(storageRootURL: root)
        #expect(store.setCustomInstruction("Synthetic saved instruction", forAICommand: forAICommand))
        let before = store.settings
        let file = root.appendingPathComponent("settings.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(!store.setCustomInstruction("Synthetic draft", forAICommand: forAICommand))
        #expect(store.settings == before)
        #expect(!store.flushPendingSave())
        try FileManager.default.removeItem(at: file)
        #expect(store.setCustomInstruction("Synthetic draft", forAICommand: forAICommand))
        let saved = try JSONDecoder().decode(ItJustTalksSettings.self, from: Data(contentsOf: file))
        #expect(saved == store.settings)
        #expect((forAICommand ? saved.aiCommandSettings.additionalInstruction : saved.customInstruction) == "Synthetic draft")
    }

    @Test func customInstructionRejectsBlockedSettingsAndUIOnlyRecordsSuccess() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid synthetic settings".utf8).write(to: root.appendingPathComponent("settings.json"))
        let store = SettingsStore(storageRootURL: root)
        let before = store.settings
        #expect(!store.save())
        #expect(!store.setCustomInstruction("Synthetic draft", forAICommand: false))
        #expect(!store.setCustomInstruction("Synthetic draft", forAICommand: true))
        #expect(store.settings == before)
        let settings = try source("Settings/SettingsView.swift")
        #expect(settings.contains("guard store.setCustomInstruction(customInstructionDraft, forAICommand: false) else"))
        #expect(settings.contains("guard store.setCustomInstruction(aiCommandCustomInstructionDraft, forAICommand: true) else"))
        #expect(AppLocalizer.hasTranslation(for: saveFailureKey, language: .english))
    }

    @Test func historyHelpExplainsStorageWithoutAIAssist() throws {
        let key = "「履歴をすべて削除」は、保存済み本文とメタデータをすべて削除します。AIアシストがOFFでも、安全に挿入した本文は履歴設定に従って保存・表示されます。AIアシストに失敗して未整形の本文を挿入した場合や、結果ウィンドウに本文を表示した場合も保存します。出力前に中止した場合は保存しません。過去の本文のない履歴も全削除の対象です。"
        try expectLocalizedUIKey(key, in: "Settings/SettingsView.swift")
        #expect(AppLocalizer.text(key, language: .english).contains("Even with AI Assist off"))
    }

    @Test func dictionaryHelpExplainsReplacementExceptions() throws {
        let key = "3文字以上の読み方は、認識結果にそのまま現れると表記へ置き換わりますが、文字種の境界や候補の競合などにより置き換わらない場合があります。2文字以下の読み方はAIが文脈で判断します。"
        try expectLocalizedUIKey(key, in: "Settings/UserDictionaryWindow.swift")
        #expect(AppLocalizationCatalog.requiredEnglishKeys.contains(key))
        #expect(AppLocalizer.text(key, language: .english).contains("may prevent replacement"))
    }

    @Test func initialLanguageHelpMatchesAutomaticAIOutput() throws {
        for (language, key) in [(AppLanguage.japanese, "日本語の表示・音声認識、AI出力は自動"),
                                (.english, "英語の表示・音声認識、AI出力は自動")] {
            #expect(AIOutputLanguage.initialValue(for: language) == .automatic)
            try expectLocalizedUIKey(key, in: "Permissions/OnboardingView.swift")
            #expect(AppLocalizer.text(key, language: .english).contains("automatic AI output"))
        }
    }

    @Test func controlsExposeLocalizedActionTargetAndScaleValue() throws {
        let settings = try source("Settings/SettingsView.swift")
        let dictionary = try source("Settings/UserDictionaryWindow.swift")
        #expect(settings.contains(".accessibilityLabel(uiFormat(\"履歴を選択: %@\", historyDateFormatter.string(from: entry.createdAt)))"))
        #expect(settings.contains(".accessibilityLabel(uiText(\"設定画面の表示倍率\"))"))
        #expect(settings.contains(".accessibilityValue(\"\\(Int((store.settings.settingsDisplayScale * 100).rounded()))%\")"))
        #expect(dictionary.contains(".accessibilityLabel(uiFormat(\"ユーザー辞書項目を有効にする: %@\", entry.preferredForm))"))
        for key in ["履歴を選択: %@", "設定画面の表示倍率", "ユーザー辞書項目を有効にする: %@"] {
            for language in AppLanguage.allCases {
                #expect(AppLocalizer.hasTranslation(for: key, language: language))
            }
        }
    }

    @Test func csvFailureRemainsInSheetWithDraftAndResolutionForRetry() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var failWrites = false
        let store = PersonalDictionaryStore(storageRootURL: root, atomicDataWriter: { data, url in
            if failWrites { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        })
        #expect(store.add(preferredForm: "Synthetic word", spokenForms: [], notes: "").succeeded)
        let row = UserDictionaryCSV.Row(physicalLine: 2, preferredForm: "Synthetic word",
            spokenForms: ["Synthetic reading"], notes: "", enabled: false)
        var draft = UserDictionaryImportPlanner.makeDraft(
            parseResult: .init(rows: [row], issues: []), existingEntries: store.entries)
        let entry = try #require(store.entries.first)
        draft.setAction(.replace(existingID: entry.id), for: 0)
        var confirmation = DictionaryImportConfirmationState(draft: draft)
        let save: (UserDictionaryImportDraft) -> String? = { candidate in
            do { _ = try store.applyImport(candidate); return nil }
            catch { return "Synthetic failure: retry" }
        }
        failWrites = true
        confirmation.confirm(using: save)
        #expect(confirmation.saveError != nil)
        #expect(confirmation.draft == draft)
        #expect(store.entries == draft.existingEntriesSnapshot)
        failWrites = false
        confirmation.confirm(using: save)
        #expect(confirmation.saveError == nil)
        #expect(store.entries.first?.enabled == false)
        let sheet = try source("Settings/UserDictionaryImportSheet.swift")
        #expect(sheet.contains("if let saveError = confirmation.saveError"))
        #expect(sheet.contains("confirmation.confirm(using: onConfirm)"))
        let window = try source("Settings/UserDictionaryWindow.swift")
        #expect(window.contains("return uiText(\"CSVの読み込みを保存できませんでした。内容と選択は残っています。もう一度試してください。\")"))
    }

    @Test func compatibilityCommentMatchesNewInstallDefault() throws {
        #expect(ExternalAppCompatibilitySettings.default.autoReplaceAICommandSelection)
        let settings = try source("Settings/SettingsStore.swift")
        #expect(!settings.contains("automatic external replacement is opt-in separately"))
    }

    private var saveFailureKey: String {
        "カスタムインストラクションを保存できませんでした。草稿は残っています。もう一度「保存」を押してください。"
    }

    private func expectLocalizedUIKey(_ key: String, in path: String) throws {
        #expect(try source(path).contains(key))
        for language in AppLanguage.allCases {
            #expect(AppLocalizer.hasTranslation(for: key, language: language))
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/ItJustTalks/\(path)"), encoding: .utf8)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
