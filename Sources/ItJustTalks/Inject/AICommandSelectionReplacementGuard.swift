import Foundation

/// ADD-02 / RV-04: 選択文章が入力元の自動置換を、AIが読んだ本文に結び付ける。
///
/// 送出（AX書込み・Unicode入力・限定貼付け）の直前に呼ぶ。照合方式は取得方法で分ける。
/// - AXで取得した選択: 録音停止時に`bindsSelectedText`で束縛でき、送出直前の
///   AX再読取りでも一致した場合だけ許可する。
/// - 一時コピーで取得した選択: 停止時に捕捉した入力要素が送出直前も同じ要素で
///   編集不可でないこと（取り直しの前後）と、`revalidateExternalSelection`で取り直した
///   本文の一致を両方要求する（一時コピーの同意が現在も有効な場合に限る）。
/// 不一致・未確認・非編集は、他の入力経路へ進まず結果ウィンドウへ退避する。
/// クリップボードが入力元の場合と明示挿入は対象外（RV-27の要素照合で守る）。
enum AICommandSelectionReplacementGuard {
    enum Decision: Equatable {
        case proceed
        case routeToResultWindow(AICommandSelectionVerification)
    }

    @MainActor
    static func decide(
        operation: AICommandInsertionOperation,
        selectedText: String?,
        captureMethod: SelectionCaptureMethod?,
        boundAtRecordingStop: Bool?,
        temporaryCopyAllowedNow: Bool,
        verifyAccessibilitySelection: (String) -> AICommandSelectionVerification,
        checkTemporaryCopyDestination: () -> AICommandDestinationElementCheck,
        revalidateTemporaryCopySelection: (String) async -> Bool
    ) async -> Decision {
        guard case .automaticSourceReplacement(let inputSource, let hasActualSource) = operation,
              inputSource == .selection,
              hasActualSource else {
            return .proceed
        }
        guard let selectedText, let captureMethod else {
            return .routeToResultWindow(.unverifiable)
        }
        switch captureMethod {
        case .accessibility:
            switch boundAtRecordingStop {
            case .some(true):
                break
            case .some(false):
                return .routeToResultWindow(.mismatched)
            case .none:
                return .routeToResultWindow(.unverifiable)
            }
            let verification = verifyAccessibilitySelection(selectedText)
            return verification == .matched ? .proceed : .routeToResultWindow(verification)
        case .temporaryCopy:
            guard temporaryCopyAllowedNow else { return .routeToResultWindow(.unverifiable) }
            // 本文の一致だけでは許可しない。停止時に捕捉した入力要素が、取り直しの前後とも
            // 同じ要素・編集不可でない・Secure Inputでないことを確認する。取り直しは
            // Cmd-Cを送るため、要素が変わっていれば送る前に止める。
            let before = AICommandSelectionVerificationPolicy.temporaryCopyElementDecision(
                checkTemporaryCopyDestination()
            )
            guard before == .matched else { return .routeToResultWindow(before) }
            guard await revalidateTemporaryCopySelection(selectedText) else {
                return .routeToResultWindow(.unverifiable)
            }
            let after = AICommandSelectionVerificationPolicy.temporaryCopyElementDecision(
                checkTemporaryCopyDestination()
            )
            return after == .matched ? .proceed : .routeToResultWindow(after)
        }
    }

    /// 録音停止時の束縛（ADD-02①）。AX取得の選択だけが対象で、それ以外は`nil`。
    static func bindingAtRecordingStop(
        inputSource: AICommandInputSource,
        selectedText: String?,
        captureMethod: SelectionCaptureMethod?,
        stoppedDestinationSelectedTextMatches: (String) -> Bool?
    ) -> Bool? {
        guard inputSource == .selection,
              let selectedText,
              captureMethod == .accessibility else {
            return nil
        }
        return stoppedDestinationSelectedTextMatches(selectedText) ?? false
    }
}
