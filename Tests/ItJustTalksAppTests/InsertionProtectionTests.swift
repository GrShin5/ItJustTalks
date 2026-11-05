import AppKit
import Foundation
import Testing
@testable import ItJustTalks

// P4 W3: insertion & clipboard protections (ADD-02 / RV-04, RV-26, RV-27).
// Deterministic: AX and pasteboard access are injected; only isolated named pasteboards are used.

// MARK: - ADD-02 text matching

@Suite struct SelectionBindingMatchTests {
    @Test func exactMatchIsAccepted() {
        #expect(SelectionDestinationBindingPolicy.matches(
            selectedText: "明日の会議は午後からです。",
            destinationSelectedText: "明日の会議は午後からです。"
        ))
    }

    @Test func crlfAndTrailingWhitespaceAreAccepted() {
        #expect(SelectionDestinationBindingPolicy.matches(
            selectedText: "一行目\n二行目",
            destinationSelectedText: "一行目\r\n二行目  \r\n"
        ))
        #expect(SelectionDestinationBindingPolicy.matches(
            selectedText: "first line\r\nsecond line \t",
            destinationSelectedText: "first line\nsecond line"
        ))
    }

    @Test func oneCharacterDifferenceIsRejected() {
        #expect(!SelectionDestinationBindingPolicy.matches(
            selectedText: "明日の会議は午後からです。",
            destinationSelectedText: "明日の会談は午後からです。"
        ))
        #expect(!SelectionDestinationBindingPolicy.matches(
            selectedText: "abc",
            destinationSelectedText: "abd"
        ))
    }

    @Test func otherWhitespaceAndUnicodeDifferencesAreRejected() {
        // Leading whitespace and whitespace before an inner line break are not normalised.
        #expect(!SelectionDestinationBindingPolicy.matches(selectedText: "abc", destinationSelectedText: " abc"))
        #expect(!SelectionDestinationBindingPolicy.matches(selectedText: "a\nb", destinationSelectedText: "a \nb"))
        // A lone CR is not CRLF.
        #expect(!SelectionDestinationBindingPolicy.matches(selectedText: "a\nb", destinationSelectedText: "a\rb"))
        // Canonically equivalent but different scalars are still a difference.
        #expect(!SelectionDestinationBindingPolicy.matches(selectedText: "が", destinationSelectedText: "か\u{3099}"))
    }

    @Test func missingOrEmptyTargetIsRejected() {
        #expect(!SelectionDestinationBindingPolicy.matches(selectedText: "abc", destinationSelectedText: nil))
        #expect(!SelectionDestinationBindingPolicy.matches(selectedText: "   ", destinationSelectedText: ""))
        #expect(!SelectionDestinationBindingPolicy.matches(selectedText: "abc", destinationSelectedText: ""))
    }

    @MainActor
    @Test func temporaryCopyRevalidationUsesSameNormalisation() {
        let same = SelectionCaptureResult.selected(
            SelectedTextCaptureContext(text: "本文\r\n", captureMethod: .temporaryCopy)
        )
        let different = SelectionCaptureResult.selected(
            SelectedTextCaptureContext(text: "本分", captureMethod: .temporaryCopy)
        )
        #expect(SelectedTextCapture.revalidationMatches(same, expectedText: "本文"))
        #expect(!SelectedTextCapture.revalidationMatches(different, expectedText: "本文"))
        #expect(!SelectedTextCapture.revalidationMatches(.none, expectedText: "本文"))
        #expect(!SelectedTextCapture.revalidationMatches(
            .unavailable(.copyDidNotProduceText),
            expectedText: "本文"
        ))
    }
}

// MARK: - ADD-02 live AX verification table

@Suite struct SelectionVerificationPolicyTests {
    private func decide(
        focusMatches: Bool? = true,
        processMatches: Bool = true,
        secureInput: Bool = false,
        editable: InsertionDestinationState? = .editable,
        liveSelectedText: String? = "対象",
        liveValue: String? = nil,
        capturedRange: CFRange? = nil,
        liveRange: CFRange? = nil
    ) -> AICommandSelectionVerification {
        AICommandSelectionVerificationPolicy.decision(
            expectedText: "対象",
            secureInput: secureInput,
            processMatches: processMatches,
            focusMatches: focusMatches,
            editableState: editable,
            liveSelectedText: liveSelectedText,
            liveValue: liveValue,
            capturedRange: capturedRange,
            liveRange: liveRange
        )
    }

    @Test func sameEditableElementWithSameSelectionMatches() {
        #expect(decide() == .matched)
        #expect(decide(liveSelectedText: "対象 \r\n") == .matched)
    }

    @Test func changedSelectionOrElementIsRejected() {
        #expect(decide(liveSelectedText: "対称") == .mismatched)
        #expect(decide(focusMatches: false) == .mismatched)
        #expect(decide(processMatches: false) == .mismatched)
    }

    @Test func unverifiableAndNonEditableAreNotMatched() {
        #expect(decide(focusMatches: nil) == .unverifiable)
        #expect(decide(secureInput: true) == .unverifiable)
        #expect(decide(editable: .unknown) == .unverifiable)
        #expect(decide(editable: nil) == .unverifiable)
        #expect(decide(editable: .nonEditable) == .nonEditable)
        #expect(decide(liveSelectedText: nil, liveValue: nil) == .unverifiable)
    }

    @Test func valueSliceFallbackRequiresSameRange() {
        let range = CFRange(location: 3, length: 2)
        #expect(decide(liveSelectedText: nil, liveValue: "前置き対象後", capturedRange: range, liveRange: range) == .matched)
        #expect(decide(
            liveSelectedText: nil,
            liveValue: "前置き対象後",
            capturedRange: range,
            liveRange: CFRange(location: 0, length: 2)
        ) == .mismatched)
        #expect(decide(
            liveSelectedText: nil,
            liveValue: "短い",
            capturedRange: CFRange(location: 5, length: 2),
            liveRange: CFRange(location: 5, length: 2)
        ) == .mismatched)
    }
}

// MARK: - ADD-02 dispatch gate

@MainActor
@Suite struct SelectionReplacementGuardTests {
    private let selectionReplacement = AICommandInsertionOperation.automaticSourceReplacement(
        inputSource: .selection,
        hasActualSource: true
    )

    private final class Calls {
        var accessibility = 0
        var revalidation = 0
        var elementChecks = 0
    }

    private func decide(
        operation: AICommandInsertionOperation? = nil,
        selectedText: String? = "AIが読んだ本文",
        method: SelectionCaptureMethod? = .accessibility,
        bound: Bool? = true,
        temporaryCopyAllowedNow: Bool = true,
        accessibility: AICommandSelectionVerification = .matched,
        revalidation: Bool = true,
        elementChecks: [AICommandDestinationElementCheck] = [.sameElement(.editable), .sameElement(.editable)],
        calls: Calls = Calls()
    ) async -> AICommandSelectionReplacementGuard.Decision {
        var remainingChecks = elementChecks
        return await AICommandSelectionReplacementGuard.decide(
            operation: operation ?? selectionReplacement,
            selectedText: selectedText,
            captureMethod: method,
            boundAtRecordingStop: bound,
            temporaryCopyAllowedNow: temporaryCopyAllowedNow,
            verifyAccessibilitySelection: { _ in
                calls.accessibility += 1
                return accessibility
            },
            checkTemporaryCopyDestination: {
                calls.elementChecks += 1
                return remainingChecks.isEmpty ? .unconfirmed : remainingChecks.removeFirst()
            },
            revalidateTemporaryCopySelection: { _ in
                calls.revalidation += 1
                return revalidation
            }
        )
    }

    @Test func boundAndReverifiedAccessibilitySelectionProceeds() async {
        let calls = Calls()
        #expect(await decide(calls: calls) == .proceed)
        #expect(calls.accessibility == 1)
    }

    @Test func unboundAtRecordingStopRoutesToResultWindowWithoutReading() async {
        let calls = Calls()
        #expect(await decide(bound: false, calls: calls) == .routeToResultWindow(.mismatched))
        #expect(await decide(bound: nil, calls: calls) == .routeToResultWindow(.unverifiable))
        #expect(calls.accessibility == 0)
    }

    @Test func dispatchTimeMismatchUnverifiableOrNonEditableRoutesToResultWindow() async {
        #expect(await decide(accessibility: .mismatched) == .routeToResultWindow(.mismatched))
        #expect(await decide(accessibility: .unverifiable) == .routeToResultWindow(.unverifiable))
        #expect(await decide(accessibility: .nonEditable) == .routeToResultWindow(.nonEditable))
        #expect(await decide(method: nil) == .routeToResultWindow(.unverifiable))
        #expect(await decide(selectedText: nil) == .routeToResultWindow(.unverifiable))
    }

    @Test func temporaryCopySelectionIsRevalidatedBeforeDispatch() async {
        let calls = Calls()
        #expect(await decide(method: .temporaryCopy, bound: nil, calls: calls) == .proceed)
        #expect(calls.revalidation == 1)
        #expect(calls.accessibility == 0)
        #expect(await decide(method: .temporaryCopy, bound: nil, revalidation: false)
            == .routeToResultWindow(.unverifiable))
    }

    @Test func temporaryCopyRequiresTheStopTimeElementBeforeAndAfterRecopy() async {
        // No element captured at stop: never re-copy, never auto-replace.
        let notCaptured = Calls()
        #expect(await decide(method: .temporaryCopy, bound: nil, elementChecks: [.notCapturedAtStop], calls: notCaptured)
            == .routeToResultWindow(.unverifiable))
        #expect(notCaptured.revalidation == 0)
        // Focus moved to another element before the re-copy.
        let moved = Calls()
        #expect(await decide(method: .temporaryCopy, bound: nil, elementChecks: [.elementChanged], calls: moved)
            == .routeToResultWindow(.mismatched))
        #expect(moved.revalidation == 0)
        // Text matches but the element changed during the re-copy.
        #expect(await decide(
            method: .temporaryCopy,
            bound: nil,
            elementChecks: [.sameElement(.editable), .elementChanged]
        ) == .routeToResultWindow(.mismatched))
        // Known non-editable, secure, or unconfirmed element.
        #expect(await decide(method: .temporaryCopy, bound: nil, elementChecks: [.sameElement(.nonEditable)])
            == .routeToResultWindow(.nonEditable))
        #expect(await decide(method: .temporaryCopy, bound: nil, elementChecks: [.secureInput])
            == .routeToResultWindow(.unverifiable))
        #expect(await decide(method: .temporaryCopy, bound: nil, elementChecks: [.unconfirmed])
            == .routeToResultWindow(.unverifiable))
        // AX-limited editor: same element whose editability AX cannot report is allowed.
        #expect(await decide(
            method: .temporaryCopy,
            bound: nil,
            elementChecks: [.sameElement(.unknown), .sameElement(.unknown)]
        ) == .proceed)
    }

    @Test func temporaryCopyWithoutCurrentConsentDoesNotCopyAgain() async {
        let calls = Calls()
        #expect(await decide(method: .temporaryCopy, bound: nil, temporaryCopyAllowedNow: false, calls: calls)
            == .routeToResultWindow(.unverifiable))
        #expect(calls.revalidation == 0)
    }

    @Test func clipboardSourceAndExplicitInsertionAreExempt() async {
        let calls = Calls()
        let clipboard = AICommandInsertionOperation.automaticSourceReplacement(
            inputSource: .clipboard,
            hasActualSource: true
        )
        #expect(await decide(operation: clipboard, accessibility: .mismatched, revalidation: false, calls: calls) == .proceed)
        #expect(await decide(operation: .explicitTargetInsertion, accessibility: .mismatched, calls: calls) == .proceed)
        #expect(calls.accessibility == 0 && calls.revalidation == 0 && calls.elementChecks == 0)
    }

    @Test func bindingAtRecordingStopOnlyAppliesToAccessibilitySelection() {
        #expect(AICommandSelectionReplacementGuard.bindingAtRecordingStop(
            inputSource: .selection,
            selectedText: "本文",
            captureMethod: .accessibility,
            stoppedDestinationSelectedTextMatches: { _ in true }
        ) == true)
        // No AX destination at stop: cannot bind -> false.
        #expect(AICommandSelectionReplacementGuard.bindingAtRecordingStop(
            inputSource: .selection,
            selectedText: "本文",
            captureMethod: .accessibility,
            stoppedDestinationSelectedTextMatches: { _ in nil }
        ) == false)
        #expect(AICommandSelectionReplacementGuard.bindingAtRecordingStop(
            inputSource: .selection,
            selectedText: "本文",
            captureMethod: .temporaryCopy,
            stoppedDestinationSelectedTextMatches: { _ in true }
        ) == nil)
        #expect(AICommandSelectionReplacementGuard.bindingAtRecordingStop(
            inputSource: .clipboard,
            selectedText: "本文",
            captureMethod: nil,
            stoppedDestinationSelectedTextMatches: { _ in true }
        ) == nil)
    }
}

// MARK: - RV-04: no fall-through into the current focus

@Suite struct AccessibilityFallthroughTests {
    private func step(
        _ result: DirectTextInsertionResult,
        automatic: Bool = true,
        live: AICommandDestinationElementCheck? = .sameElement(.editable),
        scoped: Bool = false
    ) -> AICommandAccessibilityFallthroughPolicy.Step {
        AICommandAccessibilityFallthroughPolicy.step(
            after: result,
            isAutomaticReplacement: automatic,
            liveElement: live,
            scopedPasteAvailable: scoped
        )
    }

    @Test func verificationFailuresNeverTypeIntoCurrentFocus() {
        let failures: [DirectTextInsertionResult] = [
            .targetChanged, .nonEditable, .unconfirmed, .selectionNotCollapsed, .secureInput, .inserted,
        ]
        for result in failures {
            #expect(step(result, scoped: true) == .resultWindow)
            #expect(step(result, automatic: false) == .resultWindow)
        }
    }

    @Test func unsupportedAXWriteOnConfirmedEditableSameElementMayUseCompatibilityInput() {
        #expect(step(.notSupported) == .compatibilityInput)
        // Explicit insertion is validated separately (validateExplicitUnicodeTarget requires editable).
        #expect(step(.notSupported, automatic: false, live: nil) == .compatibilityInput)
    }

    @Test func unknownEditabilityNeverUsesUnicode() {
        #expect(step(.notSupported, live: .sameElement(.unknown)) == .resultWindow)
        #expect(step(.notSupported, live: .sameElement(.unknown), scoped: true) == .scopedPasteOnly)
        #expect(step(.notSupported, live: .unconfirmed) == .resultWindow)
        #expect(step(.notSupported, live: .elementChanged) == .resultWindow)
        #expect(step(.notSupported, live: nil) == .resultWindow)
    }
}

// MARK: - RV-26: temporary transport writes are currentHostOnly

@MainActor
@Suite struct TemporaryPasteboardOptionsTests {
    @Test func transportOptionsAreCurrentHostOnly() {
        #expect(TemporaryPasteboardTransportPolicy.contentsOptions == .currentHostOnly)
    }

    @Test func installWritesWithCurrentHostOnlyAndKeepsOwnershipProtection() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.itjusttalks.tests.rv26.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try #require(pasteboard.setString("before", forType: .string))

        var recordedOptions: [NSPasteboard.ContentsOptions] = []
        let installation = PasteboardPasteTransaction.install(
            text: "temporary",
            on: pasteboard,
            prepareContents: { board, options in
                recordedOptions.append(options)
                _ = board.prepareForNewContents(with: options)
            }
        )
        guard case .installed(let transaction) = installation else {
            Issue.record("install failed on an isolated pasteboard")
            return
        }
        #expect(recordedOptions == [.currentHostOnly])
        #expect(pasteboard.string(forType: .string) == "temporary")
        // Existing changeCount + owner-marker restoration still works.
        #expect(transaction.cancel() == .restored)
        #expect(pasteboard.string(forType: .string) == "before")
    }
}

// MARK: - RV-27: re-check the captured element right before Cmd-V

@MainActor
@Suite struct ScopedClipboardPasteGateTests {
    @Test func gateBlocksChangedNonEditableAndSecureTargets() {
        #expect(ScopedClipboardPasteGate.blockedResult(
            secureInputEnabled: false, targetMatchesFrontmost: true, elementState: .sameEditableElement
        ) == nil)
        #expect(ScopedClipboardPasteGate.blockedResult(
            secureInputEnabled: false, targetMatchesFrontmost: true, elementState: .elementChanged
        ) == .targetChanged)
        #expect(ScopedClipboardPasteGate.blockedResult(
            secureInputEnabled: false, targetMatchesFrontmost: true, elementState: .notEditable
        ) == .targetChanged)
        #expect(ScopedClipboardPasteGate.blockedResult(
            secureInputEnabled: false, targetMatchesFrontmost: true, elementState: .secureInput
        ) == .secureInputBlocked)
        #expect(ScopedClipboardPasteGate.blockedResult(
            secureInputEnabled: true, targetMatchesFrontmost: true, elementState: .sameEditableElement
        ) == .secureInputBlocked)
        #expect(ScopedClipboardPasteGate.blockedResult(
            secureInputEnabled: false, targetMatchesFrontmost: false, elementState: .sameEditableElement
        ) == .targetChanged)
    }

    private final class Harness {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.itjusttalks.tests.rv27.\(UUID().uuidString)"))
        var elementStates: [ScopedClipboardPasteTargetState]
        var secureStates: [Bool]
        var installs = 0
        var pastes = 0

        init(elementStates: [ScopedClipboardPasteTargetState], secureStates: [Bool] = [false, false]) {
            self.elementStates = elementStates
            self.secureStates = secureStates
            pasteboard.clearContents()
            pasteboard.setString("user clipboard", forType: .string)
        }

        @MainActor
        func runtime() -> ScopedClipboardTextTransport.Runtime {
            ScopedClipboardTextTransport.Runtime(
                secureInputEnabled: { self.secureStates.isEmpty ? false : self.secureStates.removeFirst() },
                targetMatchesFrontmost: { true },
                capturedElementState: {
                    self.elementStates.isEmpty ? .elementChanged : self.elementStates.removeFirst()
                },
                install: { text in
                    self.installs += 1
                    return PasteboardPasteTransaction.install(text: text, on: self.pasteboard)
                },
                postCommandV: {
                    self.pastes += 1
                    return true
                }
            )
        }
    }

    @Test func elementChangedBeforeInstallDoesNotTouchClipboardOrPaste() {
        let harness = Harness(elementStates: [.elementChanged])
        defer { harness.pasteboard.releaseGlobally() }
        let transport = ScopedClipboardTextTransport()
        #expect(transport.submit("出力", runtime: harness.runtime()) == .targetChanged)
        #expect(harness.installs == 0 && harness.pastes == 0)
        #expect(harness.pasteboard.string(forType: .string) == "user clipboard")
    }

    @Test func elementChangedRightBeforeCmdVDoesNotPasteAndRestoresClipboard() {
        let harness = Harness(elementStates: [.sameEditableElement, .elementChanged])
        defer { harness.pasteboard.releaseGlobally() }
        let transport = ScopedClipboardTextTransport()
        #expect(transport.submit("出力", runtime: harness.runtime()) == .targetChanged)
        #expect(harness.installs == 1 && harness.pastes == 0)
        #expect(harness.pasteboard.string(forType: .string) == "user clipboard")
    }

    @Test func nonEditableElementDoesNotPaste() {
        let harness = Harness(elementStates: [.sameEditableElement, .notEditable])
        defer { harness.pasteboard.releaseGlobally() }
        let transport = ScopedClipboardTextTransport()
        #expect(transport.submit("出力", runtime: harness.runtime()) == .targetChanged)
        #expect(harness.pastes == 0)
        #expect(harness.pasteboard.string(forType: .string) == "user clipboard")
    }

    @Test func secureInputRightBeforeCmdVDoesNotPaste() {
        let harness = Harness(
            elementStates: [.sameEditableElement, .sameEditableElement],
            secureStates: [false, true]
        )
        defer { harness.pasteboard.releaseGlobally() }
        let transport = ScopedClipboardTextTransport()
        #expect(transport.submit("出力", runtime: harness.runtime()) == .secureInputBlocked)
        #expect(harness.pastes == 0)
        #expect(harness.pasteboard.string(forType: .string) == "user clipboard")

        let secureField = Harness(elementStates: [.secureInput])
        defer { secureField.pasteboard.releaseGlobally() }
        #expect(transport.submit("出力", runtime: secureField.runtime()) == .secureInputBlocked)
        #expect(secureField.installs == 0 && secureField.pastes == 0)
    }

    @Test func sameEditableElementPastesExactlyOnce() {
        let harness = Harness(elementStates: [.sameEditableElement, .sameEditableElement])
        defer { harness.pasteboard.releaseGlobally() }
        let transport = ScopedClipboardTextTransport()
        #expect(transport.submit("出力", runtime: harness.runtime()) == .submitted)
        #expect(harness.installs == 1 && harness.pastes == 1)
        #expect(harness.pasteboard.string(forType: .string) == "出力")
        transport.restorePendingClipboardIfOwned()
        #expect(harness.pasteboard.string(forType: .string) == "user clipboard")
    }
}

// MARK: - RV-04 / item 2: never Unicode-type an auto-replacement without a confirmed destination

@Suite struct AutomaticReplacementTransportTests {
    private func transport(
        state: InsertionDestinationState?,
        pidMatches: Bool,
        requiresUserInputEvent: Bool = false,
        compatibility: Bool = true
    ) -> AICommandInsertionTransportPolicy.Transport {
        AICommandInsertionTransportPolicy.transport(
            operation: .automaticSourceReplacement(inputSource: .selection, hasActualSource: true),
            clipboardVariantEnabled: false,
            hasStoppedTarget: true,
            targetMatchesFrontmost: true,
            secureInputEnabled: false,
            destinationIsSecureTextField: false,
            allowExternalCompatibility: compatibility,
            allowScopedClipboardFallback: false,
            hasScopedFallbackTarget: false,
            scopedFallbackTargetMatchesFreshCapture: false,
            destinationState: state,
            destinationMatchesTargetPID: pidMatches,
            destinationRequiresUserInputEvent: requiresUserInputEvent
        )
    }

    @Test func missingOrForeignOrNonEditableDestinationNeverTypes() {
        #expect(transport(state: nil, pidMatches: false) == .blocked(.targetChanged))
        #expect(transport(state: .editable, pidMatches: false) == .blocked(.targetChanged))
        #expect(transport(state: .nonEditable, pidMatches: true) == .blocked(.nonEditable))
    }

    @Test func confirmedDestinationKeepsExistingTransports() {
        #expect(transport(state: .editable, pidMatches: true) == .accessibility)
        #expect(transport(state: .unknown, pidMatches: true) == .accessibility)
        #expect(transport(state: .editable, pidMatches: true, requiresUserInputEvent: true) == .unicode)
        // Unicode typing only when editability is positively known.
        #expect(transport(state: .unknown, pidMatches: true, requiresUserInputEvent: true) == .blocked(.nonEditable))
        #expect(transport(state: .editable, pidMatches: true, requiresUserInputEvent: true, compatibility: false)
            == .blocked(.externalCompatibilityDisabled))
    }
}

// MARK: - Item 1: incomplete STT finalization never drives AI Command

@Suite struct AICommandTranscriptCompletenessTests {
    @Test func timedOutInstructionShowsFullTextAndIsNotGenerated() {
        let stop = TranscriptionStopResult(
            finalText: "翻訳して。",
            fullText: "翻訳して。置き換えず表示だけにして",
            timedOut: true
        )
        #expect(AICommandTranscriptCompletenessPolicy.decision(for: stop) == .showTranscript(
            "翻訳して。置き換えず表示だけにして",
            noticeKey: AICommandTranscriptCompletenessPolicy.transcriptionTimedOutKey
        ))
    }

    @Test func emptyFinalWithPartialIsNotGenerated() {
        let stop = TranscriptionStopResult(finalText: "", fullText: "要約して", timedOut: false)
        #expect(AICommandTranscriptCompletenessPolicy.decision(for: stop) == .showTranscript(
            "要約して",
            noticeKey: AICommandTranscriptCompletenessPolicy.transcriptionFinalEmptyKey
        ))
    }

    @Test func completeInstructionProceedsAndEmptyStaysEmpty() {
        #expect(AICommandTranscriptCompletenessPolicy.decision(
            for: TranscriptionStopResult(finalText: "翻訳して", fullText: "翻訳して", timedOut: false)
        ) == .proceed)
        #expect(AICommandTranscriptCompletenessPolicy.decision(for: .empty) == .empty)
    }

    @Test func noticesAreLocalized() {
        for key in [
            AICommandTranscriptCompletenessPolicy.transcriptionTimedOutKey,
            AICommandTranscriptCompletenessPolicy.transcriptionFinalEmptyKey,
        ] {
            #expect(AppLocalizer.text(key, language: .english) != key)
            #expect(AppLocalizer.text(key, language: .japanese) == key)
        }
    }
}

// MARK: - Item 3 / B: re-copy ownership by changeCount delta (QA-18)

@MainActor
@Suite struct TemporaryCopyRevalidationClipboardTests {
    private final class Board {
        var changeCount = 10
        var contents: String? = "A"
        var restores = 0
        /// Writes that land after our Cmd-C, in order (each bumps changeCount by 1).
        let writesAfterCopy: [String?]

        init(writesAfterCopy: [String?]) { self.writesAfterCopy = writesAfterCopy }

        func runtime() -> SelectedTextCapture.TemporaryCopyTestRuntime {
            SelectedTextCapture.TemporaryCopyTestRuntime(
                snapshotIsComplete: true,
                snapshotStillCurrent: { true },
                changeCount: { self.changeCount },
                copiedString: { self.contents },
                postCopy: {
                    for write in self.writesAfterCopy {
                        self.contents = write
                        self.changeCount += 1
                    }
                    return true
                },
                secureInputEnabled: { false },
                targetMatches: { true },
                restoreSnapshot: { expected in
                    guard expected == self.changeCount else { return false }
                    self.restores += 1
                    self.contents = "A"
                    self.changeCount += 1
                    return true
                },
                sleep: { _ in }
            )
        }

        func revalidate() async -> Bool {
            await SelectedTextCapture().debugRevalidateTemporaryCopy(expectedText: "E", runtime: runtime())
        }
    }

    @Test func initialCopyRejectsMultipleWritesBeforeFirstPoll() async {
        for last in [Optional("B"), nil] {
            let board = Board(writesAfterCopy: ["E", last])
            let result = await SelectedTextCapture().debugCaptureTemporaryCopy(runtime: board.runtime())
            guard case .unavailable(.clipboardChanged) = result else {
                Issue.record("Multiple clipboard generations must be rejected")
                continue
            }
            #expect(board.restores == 0)
            #expect(board.contents == last)
        }
    }

    @Test func ourMatchingCopyRestoresAndAllowsReplacement() async {
        let board = Board(writesAfterCopy: ["E\r\n"])
        #expect(await board.revalidate())
        #expect(board.restores == 1 && board.contents == "A")
    }

    @Test func ourMismatchingCopyRestoresButBlocksReplacement() async {
        let board = Board(writesAfterCopy: ["F"])
        #expect(!(await board.revalidate()))
        #expect(board.restores == 1 && board.contents == "A")
    }

    @Test func ourCopyPlusUserCopyKeepsCurrentClipboard() async {
        let board = Board(writesAfterCopy: ["E", "B"])
        #expect(!(await board.revalidate()))
        #expect(board.restores == 0 && board.contents == "B")
    }

    @Test func noCopyBlocksReplacementWithoutRestoring() async {
        let board = Board(writesAfterCopy: [])
        #expect(!(await board.revalidate()))
        #expect(board.restores == 0 && board.contents == "A")
    }

    @Test func nonTextSingleWriteIsAmbiguousAndNotRestored() async {
        let board = Board(writesAfterCopy: [nil])
        #expect(!(await board.revalidate()))
        #expect(board.restores == 0)
    }
}

// MARK: - Explicit insertion without a captured stop-time destination

@Suite struct ExplicitInsertionDestinationTests {
    private func transport(
        state: InsertionDestinationState?,
        pidMatches: Bool,
        requiresUserInputEvent: Bool = false
    ) -> AICommandInsertionTransportPolicy.Transport {
        AICommandInsertionTransportPolicy.transport(
            operation: .explicitTargetInsertion,
            clipboardVariantEnabled: false,
            hasStoppedTarget: true,
            targetMatchesFrontmost: true,
            secureInputEnabled: false,
            destinationIsSecureTextField: false,
            allowExternalCompatibility: true,
            allowScopedClipboardFallback: false,
            hasScopedFallbackTarget: false,
            scopedFallbackTargetMatchesFreshCapture: false,
            destinationState: state,
            destinationMatchesTargetPID: pidMatches,
            destinationRequiresUserInputEvent: requiresUserInputEvent
        )
    }

    @Test func missingStopTimeDestinationNeverTypesOrPastes() {
        // PID match alone is not enough: another field in the same app could be focused.
        #expect(transport(state: nil, pidMatches: true) == .blocked(.targetChanged))
        #expect(transport(state: nil, pidMatches: false) == .blocked(.targetChanged))
    }

    @Test func capturedDestinationKeepsExistingTransports() {
        #expect(transport(state: .editable, pidMatches: true) == .accessibility)
        #expect(transport(state: .unknown, pidMatches: true) == .unicode)
        #expect(transport(state: .nonEditable, pidMatches: true) == .blocked(.nonEditable))
    }
}

// MARK: - Scoped Cmd+V with unknown editability (selection auto-replacement only)

@Suite struct ScopedPasteUnknownEditabilityTests {
    @Test func selectionAutoReplacementAcceptsUnknownOnTheSameElement() {
        let state = ScopedClipboardPasteTargetPolicy.state(
            sameElementEditability: .unknown,
            acceptUnknownEditability: true
        )
        #expect(state == .sameEditableElement)
        #expect(ScopedClipboardPasteGate.blockedResult(
            secureInputEnabled: false, targetMatchesFrontmost: true, elementState: state
        ) == nil)
    }

    @Test func otherCallersStillRequireConfirmedEditability() {
        let state = ScopedClipboardPasteTargetPolicy.state(
            sameElementEditability: .unknown,
            acceptUnknownEditability: false
        )
        #expect(state == .notEditable)
        #expect(ScopedClipboardPasteGate.blockedResult(
            secureInputEnabled: false, targetMatchesFrontmost: true, elementState: state
        ) == .targetChanged)
    }

    @Test func knownNonEditableAndSecureAlwaysBlock() {
        for accept in [true, false] {
            #expect(ScopedClipboardPasteTargetPolicy.state(
                sameElementEditability: .nonEditable, acceptUnknownEditability: accept
            ) == .notEditable)
            #expect(ScopedClipboardPasteTargetPolicy.state(
                sameElementEditability: .secureInput, acceptUnknownEditability: accept
            ) == .secureInput)
            #expect(ScopedClipboardPasteTargetPolicy.state(
                sameElementEditability: .editable, acceptUnknownEditability: accept
            ) == .sameEditableElement)
        }
    }

    @Test func unknownStillNeverUnicodeTypes() {
        #expect(AICommandAccessibilityFallthroughPolicy.step(
            after: .notSupported,
            isAutomaticReplacement: true,
            liveElement: .sameElement(.unknown),
            scopedPasteAvailable: true
        ) == .scopedPasteOnly)
    }
}
