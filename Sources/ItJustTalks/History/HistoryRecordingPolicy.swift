import Foundation

/// Records only a completed output event; guidance and pre-output cancellation have no body.
enum HistoryRecordingPolicy {
    enum Situation: Equatable {
        case inserted
        case shownInWindow
        case insertionFailedShown
        case reviewShown
        case insertButtonSucceeded
        case guidance
        case sendWordOnly
        case cancelled
        case customInstructionOptimization
    }

    struct Decision: Equatable {
        let kind: String
        let status: String
        let marks: [String]
    }

    static func decision(mode: String, output: String, situation: Situation,
                         cleanupEnabled: Bool = false, cleanupDidFail: Bool = false) -> Decision? {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let status: String
        switch situation {
        case .inserted: status = InputHistoryInsertStatus.inserted
        case .shownInWindow, .reviewShown: status = InputHistoryInsertStatus.shownInWindow
        case .insertionFailedShown: status = InputHistoryInsertStatus.failed
        case .insertButtonSucceeded, .guidance, .sendWordOnly, .cancelled, .customInstructionOptimization:
            return nil
        }
        var marks: [String] = []
        if cleanupDidFail { marks.append(InputHistoryFlag.cleanupFailed) }
        if situation == .reviewShown { marks.append(InputHistoryFlag.needsReview) }
        if situation == .insertionFailedShown { marks.append(InputHistoryFlag.insertFailed) }
        let kind = situation == .reviewShown ? InputHistoryStoredTextKind.reviewText
            : mode == InputHistoryMode.aiCommand ? InputHistoryStoredTextKind.aiCommandOutput
            : cleanupEnabled && !cleanupDidFail ? InputHistoryStoredTextKind.aiAssistedOutput
            : InputHistoryStoredTextKind.rawTranscriptOutput
        return Decision(kind: kind, status: status, marks: marks)
    }

    // Insertion-only adapter; window display is a separate output event.
    static func shouldRecord(_ result: TextInjectorResult) -> Bool {
        switch result {
        case .inserted, .unicodeSubmitted, .scopedClipboardFallbackSubmitted:
            return true
        case .externalCompatibilityDisabled, .manualFallbackRequired,
             .clipboardMayHaveBeenLost, .insertionUnconfirmed, .secureInputBlocked, .failed,
             .clipboardVariantPasteConfirmed, .clipboardVariantPasteSubmittedUnverified,
             .clipboardVariantPasteMayHaveLostClipboard:
            return false
        }
    }

    static func shouldStoreText(
        historyEnabled: Bool,
        cleanupEnabled: Bool,
        cleanupDidFail: Bool,
        output: String,
        result: TextInjectorResult
    ) -> Bool {
        guard historyEnabled,
              shouldRecord(result),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return decision(mode: InputHistoryMode.voiceInput, output: output, situation: .inserted,
                        cleanupEnabled: cleanupEnabled, cleanupDidFail: cleanupDidFail) != nil
    }

    static func storedTextKind(cleanupEnabled: Bool) -> String {
        cleanupEnabled
            ? InputHistoryStoredTextKind.aiAssistedOutput
            : InputHistoryStoredTextKind.rawTranscriptOutput
    }
}

// Preserve the existing privacy-test API while sharing one recording policy.
typealias NormalInputHistoryPolicy = HistoryRecordingPolicy
