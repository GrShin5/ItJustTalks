import AppKit
import Carbon.HIToolbox

/// 一般の互換入力とは別に、Unicodeイベントを受け取れないことを実機で確認した二つの
/// 本文欄だけで使う、明示同意済みのCmd-V経路。
enum ScopedClipboardFallbackTarget: Equatable {
    case mailComposeBody
    case chromeGoogleDocsBody
}

enum ScopedClipboardTextTransportResult: Equatable {
    case submitted
    case unavailable
    case secureInputBlocked
    case targetChanged
    case installationFailed(mayHaveLostClipboard: Bool)
    case eventCreationFailed
}

/// RV-27: 停止時に捕捉した入力要素の、貼り付け直前の状態。
enum ScopedClipboardPasteTargetState: Equatable {
    case sameEditableElement
    case elementChanged
    case notEditable
    case secureInput
}

/// RV-27: 同一要素（PID＋AX要素一致、Secure Inputでない）と確認できた後の、編集可否の扱い。
/// 既定は編集可能と確認できた時だけ。`acceptUnknownEditability`は「AIに指示」の選択文章の
/// 自動置換（送出直前のADD-02照合に合格済み）だけが渡し、AXが編集可否を答えない欄でも
/// 同じ要素への限定Cmd-Vを許す。編集不可と分かっている欄は常に止める。Unicode入力には使わない。
enum ScopedClipboardPasteTargetPolicy {
    static func state(
        sameElementEditability: InsertionDestinationState,
        acceptUnknownEditability: Bool
    ) -> ScopedClipboardPasteTargetState {
        switch sameElementEditability {
        case .editable:
            return .sameEditableElement
        case .unknown:
            return acceptUnknownEditability ? .sameEditableElement : .notEditable
        case .nonEditable, .changed:
            return .notEditable
        case .secureInput:
            return .secureInput
        }
    }
}

/// RV-27: Cmd-Vを送ってよいかの純粋な判定。`nil`は送出可。要素が変わった・
/// 編集不可・Secure Inputのいずれでも貼り付けず、呼び出し側は結果ウィンドウへ退避する。
enum ScopedClipboardPasteGate {
    static func blockedResult(
        secureInputEnabled: Bool,
        targetMatchesFrontmost: Bool,
        elementState: ScopedClipboardPasteTargetState
    ) -> ScopedClipboardTextTransportResult? {
        guard !secureInputEnabled else { return .secureInputBlocked }
        guard targetMatchesFrontmost else { return .targetChanged }
        switch elementState {
        case .sameEditableElement:
            return nil
        case .secureInput:
            return .secureInputBlocked
        case .elementChanged, .notEditable:
            return .targetChanged
        }
    }
}

@MainActor
final class ScopedClipboardTextTransport {
    private static let restorationDelayNanoseconds: UInt64 = 1_000_000_000

    private var activeTransaction: PasteboardPasteTransaction?
    private var restorationTask: Task<Void, Never>?

    /// 通常の音声処理Taskとは独立しているが、アプリ終了だけは明示的に所有中の
    /// 一時clipboardを復元する。後発コピーがあれば所有権判定で何もしない。
    func restorePendingClipboardIfOwned() {
        restorationTask?.cancel()
        restorationTask = nil
        _ = activeTransaction?.restoreIfOwned()
        activeTransaction = nil
    }

    /// RV-27: 送出直前の判定に使う事実を差し替え可能にし、実UIなしで検証できるようにする。
    struct Runtime {
        var secureInputEnabled: () -> Bool
        var targetMatchesFrontmost: () -> Bool
        /// 停止時に捕捉した入力要素の現在の状態。要素が無い場合は`.elementChanged`。
        var capturedElementState: () -> ScopedClipboardPasteTargetState
        var install: (String) -> PasteboardPasteTransactionInstallation
        var postCommandV: () -> Bool
    }

    /// 直前の限定貼り付けだけを直列化する。通常のUnicode入力はこの待機に巻き込まない。
    /// `destination`は録音停止時に捕捉した入力要素。無ければ貼り付けない（RV-27）。
    func submit(
        _ text: String,
        to target: NormalPasteTarget,
        destination: InsertionDestination?,
        acceptUnknownEditability: Bool = false
    ) -> ScopedClipboardTextTransportResult {
        submit(text, runtime: Runtime(
            secureInputEnabled: { IsSecureEventInputEnabled() },
            targetMatchesFrontmost: { target.matchesCurrentFrontmostApplication() },
            capturedElementState: {
                destination?.scopedPasteTargetState(acceptUnknownEditability: acceptUnknownEditability)
                    ?? .elementChanged
            },
            install: { PasteboardPasteTransaction.install(text: $0) },
            postCommandV: { [weak self] in self?.postCommandV() ?? false }
        ))
    }

    func submit(_ text: String, runtime: Runtime) -> ScopedClipboardTextTransportResult {
        if let blocked = ScopedClipboardPasteGate.blockedResult(
            secureInputEnabled: runtime.secureInputEnabled(),
            targetMatchesFrontmost: runtime.targetMatchesFrontmost(),
            elementState: runtime.capturedElementState()
        ) {
            return blocked
        }

        restorePendingClipboardIfOwned()

        let installation = runtime.install(text)
        let transaction: PasteboardPasteTransaction
        switch installation {
        case .installed(let installed):
            transaction = installed
        case .snapshotIncomplete:
            return .installationFailed(mayHaveLostClipboard: false)
        case .writeFailed(let mayHaveLostClipboard):
            return .installationFailed(mayHaveLostClipboard: mayHaveLostClipboard)
        }
        // Cmd-Vの直前にもう一度、前面アプリ・Secure Input・停止時の要素を照合する。
        if let blocked = ScopedClipboardPasteGate.blockedResult(
            secureInputEnabled: runtime.secureInputEnabled(),
            targetMatchesFrontmost: runtime.targetMatchesFrontmost(),
            elementState: runtime.capturedElementState()
        ) {
            _ = transaction.restoreIfOwned()
            return blocked
        }
        guard runtime.postCommandV() else {
            _ = transaction.restoreIfOwned()
            return .eventCreationFailed
        }

        activeTransaction = transaction
        restorationTask = Task { [weak self, weak transaction] in
            try? await Task.sleep(nanoseconds: Self.restorationDelayNanoseconds)
            guard !Task.isCancelled, let self, let transaction else { return }
            _ = transaction.restoreIfOwned()
            if self.activeTransaction === transaction {
                self.activeTransaction = nil
                self.restorationTask = nil
            }
        }
        return .submitted
    }

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: false
              ) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        SyntheticInputEventTag.markScopedClipboardPaste(keyDown)
        SyntheticInputEventTag.markScopedClipboardPaste(keyUp)
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }
}
