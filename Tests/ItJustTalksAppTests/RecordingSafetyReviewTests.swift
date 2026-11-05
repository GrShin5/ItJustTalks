import Foundation
import AVFoundation
import Testing
@testable import ItJustTalks

@MainActor
@Suite struct RecordingSafetyReviewTests {
    @Test func emptyFinalVoiceTriggerUsesDedicatedFallbackEvenWithPartialTail() {
        let session = HandsFreeSendSession(snapshot: HandsFreeSendSnapshot(settings: .default,
            sttLanguage: .japanese, externalCompatibilityEnabledAtRecordingStart: false))
        #expect(session.claimStop(intent: .send, evidence: .voiceTrigger))
        session.captureVoiceTriggerFallbackTranscript("合成本文。ストップ送信")
        var stop = TranscriptionStopResult(finalText: "", fullText: "合成本文。ストップ送信",
            timedOut: false, hasUnfinalizedTail: true)
        session.revokeSendAuthorization()
        #expect(DictationTranscriptCompletenessPolicy.usesVoiceTriggerFallback(
            for: stop, isVoiceTriggerSend: session.isVoiceTriggerSend))
        #expect(session.voiceTriggerFallbackTranscript == stop.fullText)
        #expect(AICommandTranscriptCompletenessPolicy.decision(for: stop)
            == .showTranscript(stop.fullText, noticeKey: AICommandTranscriptCompletenessPolicy.transcriptionFinalEmptyKey))
        #expect(!DictationTranscriptCompletenessPolicy.usesVoiceTriggerFallback(for: stop, isVoiceTriggerSend: false))
        stop.audioLost = true
        #expect(!DictationTranscriptCompletenessPolicy.usesVoiceTriggerFallback(for: stop, isVoiceTriggerSend: true))
        stop.audioLost = false
        stop.recognitionFailed = true
        #expect(!DictationTranscriptCompletenessPolicy.usesVoiceTriggerFallback(for: stop, isVoiceTriggerSend: true))
    }

    @Test func onlyAdditionalLexicalContentIsAnUnfinalizedTail() {
        for (final, partial, expected) in [
            ("合成本文", "合成本文。  ", false),
            ("合成本文。", "合成本文", false),
            ("前半と後半。", "前半", false),
            ("前半と後半。", "後半", false),
            ("Hello, world.", "Hello world!", false),
            ("確定本文。", "確定本文。追加の指示", true),
            ("", "途中結果", true),
            ("", " 。!? ", false)
        ] {
            #expect(TranscriptionStopResult.containsUnfinalizedContent(finalText: final, partialText: partial) == expected)
        }
    }

    @Test func punctuationOnlyVolatileTailDoesNotBlockCompletedRecording() async throws {
        let engine = TranscriptionEngine(lifecycleTestSeam: .init(suspend: { _, _ in }, bypassSpeechFramework: true))
        try await engine.reconfigure(to: .japanese)
        let id = UUID()
        _ = try await engine.startStreaming(streamID: id)
        engine.debugAcceptTextResult("合成本文", isFinal: true)
        engine.debugAcceptTextResult("。 ", isFinal: false)
        let stop = await engine.stopStreamingResult(streamID: id)
        #expect(!stop.hasUnfinalizedTail)
        #expect(DictationTranscriptCompletenessPolicy.decision(for: stop) == .proceed)
    }

    @Test func conversionFailureLogIsLimitedToOncePerRecording() {
        let state = RecordingFailureState()
        #expect(state.shouldLogConversionFailure())
        #expect(!state.shouldLogConversionFailure())
        #expect(!state.shouldLogConversionFailure())
        #expect(RecordingFailureState().shouldLogConversionFailure())
    }

    @Test func historyConsentIsRecheckedForBothInputSources() {
        for source in [AICommandInputSource.selection, .clipboard] {
            for start in [false, true] {
                var settings = AICommandSettings.default
                settings.historyEnabled = start
                let session = VoiceSession(mode: .aiCommand, inputSource: source,
                    aiCommandSettings: settings, cleanupEnabledAtRecordingStart: false)
                for current in [false, true] {
                    settings.historyEnabled = current
                    #expect(VoiceSession.allowsAIHistory(startEnabled: session.aiCommandSettings?.historyEnabled == true,
                        currentEnabled: settings.historyEnabled) == (start && current))
                    #expect(session.inputSource == source)
                }
            }
        }
    }

    @Test func compatibilityCannotExpandAfterRecordingStarts() {
        for start in [false, true] {
            for scoped in [false, true] {
                for replacement in [false, true] {
                    let session = VoiceSession(mode: .voiceInput,
                        externalCompatibilityEnabledAtRecordingStart: start,
                        aiCommandExplicitInsertionAllowedAtRecordingStart: start && replacement,
                        scopedClipboardFallbackAllowedAtRecordingStart: scoped,
                        cleanupEnabledAtRecordingStart: false)
                    for now in [false, true] {
                        for allowedNow in [false, true] {
                            #expect(session.allowsCompatibility(currentEnabled: now) == (start && now))
                            #expect(session.allowsScopedClipboardFallback(currentEnabled: now, currentAllowed: allowedNow)
                                == (start && scoped && now && allowedNow))
                            #expect(session.allowsAIReplacement(currentAllowed: now && allowedNow)
                                == (start && replacement && now && allowedNow))
                        }
                    }
                }
            }
        }
    }

    @Test func handsFreeNewlineProtectionSurvivesRevokedSendAuthorization() {
        let snapshot = HandsFreeSendSnapshot(settings: .default, sttLanguage: .japanese,
            externalCompatibilityEnabledAtRecordingStart: true)
        let session = VoiceSession(mode: .voiceInput, handsFreeSendSnapshot: snapshot,
            cleanupEnabledAtRecordingStart: false)
        #expect(!session.allowsUnverifiedMultilineText)
        session.handsFreeSendSession?.revokeSendAuthorization()
        #expect(!session.allowsUnverifiedMultilineText)
        #expect(VoiceSession(mode: .voiceInput, cleanupEnabledAtRecordingStart: false).allowsUnverifiedMultilineText)
    }

    @Test func allNewlineScalarsBlockUnverifiedHandsFreeInsertion() {
        for separator in ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
            let original = "合成本文" + separator + "続き"
            let sanitized = InvisibleCharacterSanitizer.sanitize(original)
            for evidence in [HandsFreeSendSession.StopEvidence.autoStop, .hudFinish] {
                let session = VoiceSession(mode: .voiceInput,
                    handsFreeSendSnapshot: HandsFreeSendSnapshot(settings: .default, sttLanguage: .japanese,
                        externalCompatibilityEnabledAtRecordingStart: true), cleanupEnabledAtRecordingStart: false)
                #expect(session.handsFreeSendSession?.claimStop(intent: .insertOnly, evidence: evidence) == true)
                #expect(!UnverifiedInsertionPolicy.permitsText(sanitized,
                    allowMultiline: session.allowsUnverifiedMultilineText,
                    originalContainsNewline: UnverifiedInsertionPolicy.containsNewline(original)))
            }
        }
        #expect(UnverifiedInsertionPolicy.permitsText("合成本文", allowMultiline: false))
        #expect(UnverifiedInsertionPolicy.permitsText("合成\r\n本文", allowMultiline: true))
    }

    @Test func compatibilityConsentIsReadAgainAtFallbackBoundary() async {
        var enabled = true
        let live = { enabled }
        #expect(UnverifiedInsertionPolicy.consent(startAllowed: true, liveAllowed: live))
        await Task.yield()
        enabled = false
        #expect(!UnverifiedInsertionPolicy.consent(startAllowed: true, liveAllowed: live))
        enabled = true
        #expect(!UnverifiedInsertionPolicy.consent(startAllowed: false, liveAllowed: live))
    }

    @Test func emptyClipboardDoesNotReadTextAndDiffersFromUnreadableText() {
        var reads = 0
        let empty = ClipboardSourceReadPolicy.decision(secureInputEnabled: false, itemCount: 0,
            availableTypes: [], readString: { reads += 1; return nil }, maximumCharacters: 100)
        #expect(empty == .empty)
        #expect(reads == 0)
        let unreadable = ClipboardSourceReadPolicy.decision(secureInputEnabled: false, itemCount: 1,
            availableTypes: ["public.utf8-plain-text"], readString: { reads += 1; return nil }, maximumCharacters: 100)
        #expect(unreadable == .nonText)
        #expect(reads == 1)
    }

    @Test func hintsRespectModeAndFilterDisabledEntries() {
        let entries = [PersonalDictionaryEntry(preferredForm: " Synthetic "),
                       PersonalDictionaryEntry(preferredForm: "Disabled", enabled: false)]
        for mode in [VoiceMode.voiceInput, .aiCommand] {
            #expect(TranscriptionEngine.contextualStrings(mode: mode, handsFree: true, entries: entries).isEmpty)
            #expect(TranscriptionEngine.contextualStrings(mode: mode, handsFree: false, entries: entries) == ["Synthetic"])
        }
    }

    @Test func incompleteRecognitionAndAudioAlwaysRequireReview() {
        for flag in 0..<3 {
            var stop = TranscriptionStopResult(finalText: "確定した前半。", fullText: "確定した前半。未確定の末尾", timedOut: false)
            stop.recognitionFailed = flag == 0
            stop.hasUnfinalizedTail = flag == 1
            stop.audioLost = flag == 2
            #expect(DictationTranscriptCompletenessPolicy.decision(for: stop)
                == .review(stop.fullText, notice: .transcriptionIncomplete))
            #expect(AICommandTranscriptCompletenessPolicy.decision(for: stop)
                == .showTranscript(stop.fullText, noticeKey: DictationCleanupMessages.transcriptionIncompleteKey))
        }
        var empty = TranscriptionStopResult.empty
        empty.audioLost = true
        #expect(DictationTranscriptCompletenessPolicy.decision(for: empty)
            == .review("", notice: .transcriptionIncomplete))
    }

    @Test func onlyDroppedBuffersWithAudioMarkRecordingIncomplete() {
        let first = RecordingFailureState()
        first.recordDroppedAudio(frameCount: 0)
        #expect(!first.hasFailed)
        first.recordDroppedAudio(frameCount: 1)
        #expect(first.hasFailed)
        #expect(!RecordingFailureState().hasFailed)
    }

    @Test func allocationFailureMarksOnlyNonemptyAudioIncomplete() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        for frameCount in [AVAudioFrameCount(0), AVAudioFrameCount(8)] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 8))
            buffer.frameLength = frameCount
            if let samples = buffer.floatChannelData?[0] {
                for index in 0..<Int(frameCount) { samples[index] = 0 }
            }
            let failure = RecordingFailureState()
            let delivered = RecordingFailureState()
            var lastLevel = Date.distantPast
            AudioRecorder.process(buffer: buffer, inputFormat: input, converter: converter,
                targetFormat: output, lastLevelLogAt: &lastLevel, onLevel: nil,
                onBuffer: { _ in delivered.markFailed() }, recordingFailure: failure,
                makeOutputBuffer: { _, _ in nil })
            #expect(failure.hasFailed == (frameCount > 0))
            #expect(!delivered.hasFailed)
        }
    }

    @Test func resultStreamFailurePreservesFullAvailableText() async throws {
        let gate = RecordingStreamTestGate()
        let seam = TranscriptionEngine.LifecycleTestSeam(suspend: { point, _ in
            if point == .fakeResultsStream {
                await gate.wait()
                throw CocoaError(.fileReadUnknown)
            }
        }, bypassSpeechFramework: true)
        let engine = TranscriptionEngine(lifecycleTestSeam: seam)
        try await engine.reconfigure(to: .japanese)
        let id = UUID()
        _ = try await engine.startStreaming(streamID: id)
        engine.debugAcceptTextResult("確定した前半。", isFinal: true)
        engine.debugAcceptTextResult("未確定の末尾", isFinal: false)
        await gate.release()
        let result = await engine.stopStreamingResult(streamID: id)
        #expect(result.recognitionFailed)
        #expect(result.hasUnfinalizedTail)
        #expect(result.fullText == "確定した前半。未確定の末尾")
        #expect(DictationTranscriptCompletenessPolicy.decision(for: result)
            == .review(result.fullText, notice: .transcriptionIncomplete))
    }

    @Test func incompleteNoticeAndSupportedLanguagesAreLocalized() {
        let range = DictationCleanupMessages.supportedLanguagesKey
        for key in [range, DictationCleanupMessages.transcriptionIncompleteKey] {
            #expect(DictationCleanupMessages.allKeys.contains(key))
            #expect(AICommandMessages.allKeys.contains(key))
            #expect(AppLocalizationCatalog.requiredEnglishKeys.contains(key))
        }
        #expect(DictationCleanupMessages.reasonKeys(.unsupportedLanguage).contains(range))
        #expect(AICommandMessages.reasonKeys(.unsupportedLanguage).contains(range))
        #expect(DictationCleanupMessages.noticeKeys(.aiFailed(.unsupportedLanguage)).contains(range))
        for language in [AppLanguage.japanese, .english] {
            for key in [range, DictationCleanupMessages.transcriptionIncompleteKey] {
                #expect(AppLocalizer.hasTranslation(for: key, language: language))
            }
        }
        #expect(AppLocalizer.text(range, language: .english).contains("Japanese and English"))
    }
}

private actor RecordingStreamTestGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
