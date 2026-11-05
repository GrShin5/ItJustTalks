import AppKit
import Carbon.HIToolbox

enum SelectionCaptureFailure: Equatable {
    case accessibilityPermissionMissing
    case secureInput
    case focusedElementUnavailable
    case externalCompatibilityDisabled
    case selectionUnsupported
    case copyDidNotProduceText
    case clipboardChanged
    case clipboardRestoreFailed
}

/// The selected text is captured at AI-command start as immutable model input.
/// Its output target is captured independently when recording stops, so this
/// start-time source never needs to bind an insertion destination.
/// ADD-02: 選択本文をどう取得したか。送出直前の照合方式を決めるためだけに使う。
enum SelectionCaptureMethod: Equatable {
    /// AXの`kAXSelectedText`で読んだ。停止時の束縛と送出直前のAX照合を使う。
    case accessibility
    /// 一時コピー（Cmd-C）で読んだ。送出直前に`revalidateExternalSelection`で取り直す。
    case temporaryCopy
}

@MainActor
struct SelectedTextCaptureContext {
    let text: String
    let captureMethod: SelectionCaptureMethod
}

@MainActor
enum SelectionCaptureResult {
    case selected(SelectedTextCaptureContext)
    case none
    case unavailable(SelectionCaptureFailure)
    case tooLong(actual: Int, maximum: Int)
    case cancelledTemporaryCopy(ClipboardCancellationReceipt)
}

@MainActor
final class ClipboardCancellationReceipt {
    enum Resolution: Equatable {
        case restored
        case preserved
        case clipboardChanged
        case expired
        case revoked
        case alreadyResolved
        case restoreFailed
    }

    nonisolated static let lifetimeSeconds: TimeInterval = 10
    private let expectedChangeCount: Int
    private var currentChangeCount: (() -> Int)?
    private var restoreSnapshot: ((Int) -> Bool)?
    private let now: () -> Date
    private let expiresAt: Date
    private var isValid = true
    private var didResolve = false

    init(
        expectedChangeCount: Int,
        lifetimeSeconds: TimeInterval = ClipboardCancellationReceipt.lifetimeSeconds,
        currentChangeCount: @escaping () -> Int,
        restoreSnapshot: @escaping (Int) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.expectedChangeCount = expectedChangeCount
        self.currentChangeCount = currentChangeCount
        self.restoreSnapshot = restoreSnapshot
        self.now = now
        self.expiresAt = now().addingTimeInterval(min(Self.lifetimeSeconds, max(0, lifetimeSeconds)))
    }

    func resolve(restoreOriginal: Bool) -> Resolution {
        guard !didResolve else { return .alreadyResolved }
        didResolve = true
        guard isValid, let currentChangeCount, let restoreSnapshot else {
            releaseSnapshot()
            return .revoked
        }
        isValid = false
        guard now() < expiresAt else {
            releaseSnapshot()
            return .expired
        }
        guard restoreOriginal else {
            releaseSnapshot()
            return .preserved
        }
        guard currentChangeCount() == expectedChangeCount else {
            releaseSnapshot()
            return .clipboardChanged
        }
        let restored = restoreSnapshot(expectedChangeCount)
        releaseSnapshot()
        return restored ? .restored : .restoreFailed
    }

    func invalidate() {
        isValid = false
        releaseSnapshot()
    }

    func isUsable() -> Bool {
        guard isValid,
              !didResolve,
              now() < expiresAt,
              currentChangeCount?() == expectedChangeCount else {
            invalidate()
            return false
        }
        return true
    }

    private func releaseSnapshot() {
        currentChangeCount = nil
        restoreSnapshot = nil
    }
}

/// Owns one selection-capture completion across cancellation and replacement.
/// A recovery receipt is accepted only for the capture explicitly cancelled by
/// the user's Esc action; all other late completions are inert.
@MainActor
final class AICommandCaptureCompletionGate {
    struct Lease: Equatable {
        let id: UUID
        let generation: UInt64
    }

    enum Completion {
        case current
        case recovery(ClipboardCancellationReceipt)
        case stale
    }

    private var generation: UInt64 = 0
    private(set) var activeCaptureID: UUID?
    private var recoveryAuthorizedCaptureID: UUID?

    func begin(id: UUID = UUID()) -> Lease {
        generation &+= 1
        activeCaptureID = id
        recoveryAuthorizedCaptureID = nil
        return Lease(id: id, generation: generation)
    }

    func authorizeUserCancellation() {
        recoveryAuthorizedCaptureID = activeCaptureID
        activeCaptureID = nil
    }

    func revokeAll() {
        activeCaptureID = nil
        recoveryAuthorizedCaptureID = nil
    }

    func revokeActive(id: UUID) {
        guard activeCaptureID == id else { return }
        activeCaptureID = nil
        recoveryAuthorizedCaptureID = nil
    }

    func finishIfCurrent(_ lease: Lease) {
        guard owns(lease) else { return }
        activeCaptureID = nil
    }

    func classify(
        _ result: SelectionCaptureResult,
        lease: Lease,
        appIsIdle: Bool
    ) -> Completion {
        if case .cancelledTemporaryCopy(let receipt) = result {
            guard lease.generation == generation,
                  recoveryAuthorizedCaptureID == lease.id,
                  activeCaptureID == nil,
                  appIsIdle else {
                receipt.invalidate()
                return .stale
            }
            recoveryAuthorizedCaptureID = nil
            return .recovery(receipt)
        }
        guard owns(lease) else { return .stale }
        return .current
    }

    private func owns(_ lease: Lease) -> Bool {
        lease.generation == generation && activeCaptureID == lease.id
    }
}

/// Captures the selection at recording start. AX is authoritative; Cmd-C is a
/// consent-gated fallback that restores the user's pasteboard before recording
/// begins whenever ownership can still be proven.
@MainActor
final class SelectedTextCapture {
    static let maximumCharacters = 12_000
    private let copyPollNanoseconds: UInt64 = 25_000_000
    private let copyPollAttempts = 13

    struct TemporaryCopyTestRuntime {
        let snapshotIsComplete: Bool
        let snapshotStillCurrent: () -> Bool
        let changeCount: () -> Int
        let copiedString: () -> String?
        let postCopy: () -> Bool
        let secureInputEnabled: () -> Bool
        let targetMatches: () -> Bool
        let restoreSnapshot: (Int) -> Bool
        var sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
        var receiptLifetimeSeconds: TimeInterval = ClipboardCancellationReceipt.lifetimeSeconds
        var now: () -> Date = Date.init
    }

    @MainActor
    private enum CaptureTarget {
        case exact(processIdentifier: pid_t, focusedElement: AXUIElement)
        case appOnly(NormalPasteTarget)

        func matchesCurrentTarget() -> Bool {
            switch self {
            case .appOnly(let target):
                return target.matchesCurrentFrontmostApplication()
            case .exact(let processIdentifier, let focusedElement):
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
                    return false
                }
                let application = AXUIElementCreateApplication(processIdentifier)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    application,
                    kAXFocusedUIElementAttribute as CFString,
                    &value
                ) == .success, let value else {
                    return false
                }
                return CFEqual(unsafeBitCast(value, to: AXUIElement.self), focusedElement)
            }
        }

    }

    func capture(allowingExternalCompatibility: Bool = false) async -> SelectionCaptureResult {
        guard AXIsProcessTrusted() else { return .unavailable(.accessibilityPermissionMissing) }
        guard !IsSecureEventInputEnabled() else { return .unavailable(.secureInput) }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            // テキスト入力先がなくても、選択なしのAIへの質問は実行できる。
            return .none
        }

        let appOnlyTarget = NormalPasteTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier
        )
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedElementAvailable = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success && focusedValue != nil

        guard let focusedValue else {
            let decision = SelectionCapturePolicy.decision(
                bundleIdentifier: app.bundleIdentifier,
                focusedElementAvailable: false,
                selectedText: .unavailable,
                selectedTextRange: .unavailable,
                allowsTemporaryCopy: allowingExternalCompatibility
            )
            return await result(for: decision, target: .appOnly(appOnlyTarget))
        }

        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        let decision = SelectionCapturePolicy.decision(
            bundleIdentifier: app.bundleIdentifier,
            focusedElementAvailable: focusedElementAvailable,
            selectedText: selectedTextRead(of: focused),
            selectedTextRange: selectedTextRangeState(of: focused),
            allowsTemporaryCopy: allowingExternalCompatibility
        )
        // WebKitは同一入力欄でもAXプロキシを返し直すことがある。直接読めた選択は
        // 現在の要素で確認するが、Cmd-Cを送る互換経路だけは同一前面アプリの確認へ
        // 狭め、proxy同一性だけでSafariの選択取得を失敗させない。
        let target: CaptureTarget
        if case .temporaryCopy = decision {
            target = .appOnly(appOnlyTarget)
        } else {
            target = .exact(processIdentifier: app.processIdentifier, focusedElement: focused)
        }
        return await result(for: decision, target: target)
    }

    /// Before an explicitly enabled AX-less AI replacement, recapture the
    /// current selection once and require exactly the text that started the
    /// request. This narrows, but cannot eliminate, same-app copy races.
    func revalidateExternalSelection(
        expectedText: String,
        target: NormalPasteTarget
    ) async -> Bool {
        guard !IsSecureEventInputEnabled(), target.matchesCurrentFrontmostApplication() else {
            return false
        }
        let result = await captureByTemporaryCopy(target: .appOnly(target), expectedText: expectedText)
        guard Self.revalidationMatches(result, expectedText: expectedText),
              target.matchesCurrentFrontmostApplication(),
              !IsSecureEventInputEnabled() else {
            return false
        }
        return true
    }

    /// ADD-02: 取り直した選択がAIの読んだ本文と一致するか。正規化は改行コードと
    /// 末尾空白だけ（`SelectionDestinationBindingPolicy`）。
    static func revalidationMatches(_ result: SelectionCaptureResult, expectedText: String) -> Bool {
        guard case .selected(let context) = result else { return false }
        return SelectionDestinationBindingPolicy.matches(
            selectedText: expectedText,
            destinationSelectedText: context.text
        )
    }

    private func validated(
        _ text: String,
        method: SelectionCaptureMethod
    ) -> SelectionCaptureResult {
        guard !text.isEmpty else { return .none }
        guard text.count <= Self.maximumCharacters else {
            return .tooLong(actual: text.count, maximum: Self.maximumCharacters)
        }
        return .selected(SelectedTextCaptureContext(text: text, captureMethod: method))
    }

    private func result(
        for decision: SelectionCapturePolicy.Decision,
        target: CaptureTarget
    ) async -> SelectionCaptureResult {
        switch decision {
        case .selectedText(let text):
            guard target.matchesCurrentTarget() else {
                return .unavailable(.focusedElementUnavailable)
            }
            return validated(text, method: .accessibility)
        case .noSelection:
            return .none
        case .temporaryCopy:
            return await captureByTemporaryCopy(target: target)
        case .unavailable(let failure):
            return .unavailable(failure)
        }
    }

    /// `expectedText`は送出直前の取り直し（ADD-02②）だけで渡す。所有はchangeCountの差で
    /// 判定し、差が1でない・本文でない書込みは開始前の内容で上書き復元しない
    /// （取り直し中の利用者のコピーを守る、QA-18）。
    private func captureByTemporaryCopy(
        target: CaptureTarget,
        expectedText: String? = nil
    ) async -> SelectionCaptureResult {
        guard target.matchesCurrentTarget() else {
            return .unavailable(.focusedElementUnavailable)
        }
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        let runtime = TemporaryCopyTestRuntime(
            snapshotIsComplete: snapshot.isComplete,
            snapshotStillCurrent: { snapshot.stillRepresentsCurrentContents(of: pasteboard) },
            changeCount: { pasteboard.changeCount },
            copiedString: { pasteboard.string(forType: .string) },
            postCopy: postCommandC,
            secureInputEnabled: IsSecureEventInputEnabled,
            targetMatches: target.matchesCurrentTarget,
            restoreSnapshot: { snapshot.restore(to: pasteboard, ifChangeCountIs: $0) }
        )
        return await captureByTemporaryCopy(runtime: runtime, expectedText: expectedText)
    }

    func debugCaptureTemporaryCopy(runtime: TemporaryCopyTestRuntime) async -> SelectionCaptureResult {
        await captureByTemporaryCopy(runtime: runtime)
    }

    /// 送出直前の取り直しを、実クリップボードなしで検証するための入口。
    func debugRevalidateTemporaryCopy(
        expectedText: String,
        runtime: TemporaryCopyTestRuntime
    ) async -> Bool {
        let result = await captureByTemporaryCopy(runtime: runtime, expectedText: expectedText)
        return Self.revalidationMatches(result, expectedText: expectedText)
    }

    private func captureByTemporaryCopy(
        runtime: TemporaryCopyTestRuntime,
        expectedText: String? = nil
    ) async -> SelectionCaptureResult {
        guard runtime.targetMatches() else {
            return .unavailable(.focusedElementUnavailable)
        }
        guard runtime.snapshotIsComplete else {
            return .unavailable(.clipboardRestoreFailed)
        }
        guard runtime.snapshotStillCurrent() else {
            AppLog.shared.info("[Telemetry] selection_capture clipboardChanged=true")
            return .unavailable(.clipboardChanged)
        }
        let before = runtime.changeCount()
        guard runtime.postCopy() else { return .unavailable(.selectionUnsupported) }

        var copiedChangeCount: Int?
        var copiedText: String?
        for attempt in 0..<copyPollAttempts {
            let currentChangeCount = runtime.changeCount()
            if currentChangeCount != before {
                guard currentChangeCount == before + 1 else {
                    AppLog.shared.info("[Telemetry] selection_capture clipboardChanged=true")
                    return .unavailable(.clipboardChanged)
                }
                copiedChangeCount = currentChangeCount
            }

            if Task.isCancelled {
                return await cancelledTemporaryCopyResult(
                    runtime: runtime,
                    beforeChangeCount: before,
                    copiedChangeCount: copiedChangeCount,
                    remainingPolls: copyPollAttempts - attempt - 1
                )
            }
            if runtime.secureInputEnabled() {
                return finishTemporaryCopyFailure(
                    .secureInput,
                    runtime: runtime,
                    copiedChangeCount: copiedChangeCount,
                    restoreAllowed: false
                )
            }
            guard runtime.targetMatches() else {
                return finishTemporaryCopyFailure(
                    .focusedElementUnavailable,
                    runtime: runtime,
                    copiedChangeCount: copiedChangeCount,
                    restoreAllowed: false
                )
            }

            if copiedChangeCount != nil {
                copiedText = runtime.copiedString()
                if copiedText != nil { break }
            }
            guard attempt + 1 < copyPollAttempts else { break }
            await runtime.sleep(copyPollNanoseconds)
        }

        guard let copiedChangeCount else {
            // No clipboard change is ambiguous. The UI must offer an explicit
            // "選択なしで質問する" action rather than guessing a general query.
            return .unavailable(.copyDidNotProduceText)
        }
        // 送出直前の取り直し（ADD-02②）では、Cmd-C直前からのchangeCountの差を所有の
        // 根拠にする。差がちょうど1なら自分のCmd-Cの1回の書込みとみなし、本文が一致しても
        // しなくても開始前の内容へ復元する（不一致の判定は呼び出し側、自動置換はしない）。
        // 差が2以上は利用者・他アプリの書込みが混ざった可能性があるため、復元も置換もしない。
        // 残余リスク: 自分のCmd-Cの書込みの「代わりに」同じ間隔で利用者が1回だけコピーした
        // 場合は差が1になり、区別できない（その場合は利用者の内容を復元で上書きしうる）。
        guard let copiedText else {
            // 取り直しでは、本文の無い変化を自分のCmd-Cの結果と証明できない。
            return finishTemporaryCopyFailure(
                .copyDidNotProduceText,
                runtime: runtime,
                copiedChangeCount: copiedChangeCount,
                restoreAllowed: expectedText == nil
            )
        }

        if Task.isCancelled {
            return await cancelledTemporaryCopyResult(
                runtime: runtime,
                beforeChangeCount: before,
                copiedChangeCount: copiedChangeCount,
                remainingPolls: 0
            )
        }
        if runtime.secureInputEnabled() {
            return finishTemporaryCopyFailure(
                .secureInput,
                runtime: runtime,
                copiedChangeCount: copiedChangeCount,
                restoreAllowed: false
            )
        }
        guard runtime.targetMatches() else {
            return finishTemporaryCopyFailure(
                .focusedElementUnavailable,
                runtime: runtime,
                copiedChangeCount: copiedChangeCount,
                restoreAllowed: false
            )
        }
        guard runtime.changeCount() == copiedChangeCount else {
            AppLog.shared.info("[Telemetry] selection_capture clipboardChanged=true")
            return .unavailable(.clipboardChanged)
        }
        guard runtime.restoreSnapshot(copiedChangeCount) else {
            if runtime.changeCount() != copiedChangeCount {
                AppLog.shared.info("[Telemetry] selection_capture clipboardChanged=true")
                return .unavailable(.clipboardChanged)
            }
            return .unavailable(.clipboardRestoreFailed)
        }
        return validated(copiedText, method: .temporaryCopy)
    }

    private func finishTemporaryCopyFailure(
        _ failure: SelectionCaptureFailure,
        runtime: TemporaryCopyTestRuntime,
        copiedChangeCount: Int?,
        restoreAllowed: Bool
    ) -> SelectionCaptureResult {
        guard restoreAllowed, let copiedChangeCount else {
            return .unavailable(failure)
        }
        guard runtime.changeCount() == copiedChangeCount else {
            AppLog.shared.info("[Telemetry] selection_capture clipboardChanged=true")
            return .unavailable(.clipboardChanged)
        }
        guard runtime.restoreSnapshot(copiedChangeCount) else {
            return .unavailable(.clipboardRestoreFailed)
        }
        return .unavailable(failure)
    }

    private func cancelledTemporaryCopyResult(
        runtime: TemporaryCopyTestRuntime,
        beforeChangeCount: Int,
        copiedChangeCount initialCopiedChangeCount: Int?,
        remainingPolls: Int
    ) async -> SelectionCaptureResult {
        var copiedChangeCount = initialCopiedChangeCount
        if let copiedChangeCount, copiedChangeCount != beforeChangeCount + 1 {
            AppLog.shared.info("[Telemetry] selection_capture clipboardChanged=true")
            return .unavailable(.clipboardChanged)
        }
        for _ in 0..<max(0, remainingPolls) {
            await Task.detached { await runtime.sleep(self.copyPollNanoseconds) }.value
            let current = runtime.changeCount()
            if current == beforeChangeCount { continue }
            guard current == beforeChangeCount + 1 else {
                AppLog.shared.info("[Telemetry] selection_capture clipboardChanged=true")
                return .unavailable(.clipboardChanged)
            }
            if let copiedChangeCount, copiedChangeCount != current {
                AppLog.shared.info("[Telemetry] selection_capture clipboardChanged=true")
                return .unavailable(.clipboardChanged)
            }
            copiedChangeCount = current
        }
        guard let copiedChangeCount else { return .unavailable(.selectionUnsupported) }
        return .cancelledTemporaryCopy(ClipboardCancellationReceipt(
            expectedChangeCount: copiedChangeCount,
            lifetimeSeconds: runtime.receiptLifetimeSeconds,
            currentChangeCount: runtime.changeCount,
            restoreSnapshot: runtime.restoreSnapshot,
            now: runtime.now
        ))
    }

    private func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func selectedTextRead(of element: AXUIElement) -> SelectionCapturePolicy.SelectedTextRead {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) {
        case .success:
            return .text(value as? String ?? "")
        case .noValue:
            return .noValue
        default:
            return .unavailable
        }
    }

    private func selectedTextRangeState(of element: AXUIElement) -> SelectionCapturePolicy.SelectedTextRange {
        guard let range = selectedTextRange(of: element) else { return .unavailable }
        return range.length > 0 && range.location != kCFNotFound
            ? .nonzeroLength
            : .zeroLength
    }

    private func postCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        SyntheticInputEventTag.markSelectionCapture(down)
        SyntheticInputEventTag.markSelectionCapture(up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
