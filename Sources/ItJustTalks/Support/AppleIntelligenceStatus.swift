import Foundation
import ItJustTalksAI

/// Apple Intelligence（オンデバイスAI）の利用可否を、設定画面とセットアップに見せるための表示モデル。
///
/// 値は `ItJustTalksAI.OnDeviceGenerator().availability` だけから決める。生成は行わず、
/// 文章・プロンプトにも触れない。モデルのダウンロード状況は時間とともに変わるため、
/// 呼び出し側は画面表示のたびに `current()` を呼び直す。
enum AppleIntelligenceStatus: Equatable {
    case available
    /// システム設定でApple Intelligenceがオフ。
    case appleIntelligenceOff
    /// このMacがApple Intelligenceに対応していない。
    case deviceNotEligible
    /// モデルの準備中（ダウンロード中を含む）。
    case modelNotReady
    /// 上記以外（未知の理由、またはこのmacOSでは確認できない）。
    case unavailable

    static func current() -> AppleIntelligenceStatus {
        guard #available(macOS 27, *) else { return .unavailable }
        return AppleIntelligenceStatus(OnDeviceGenerator().availability)
    }

    init(_ availability: ModelAvailability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: self = .appleIntelligenceOff
            case .deviceNotEligible: self = .deviceNotEligible
            case .modelNotReady, .assetsUnavailable: self = .modelNotReady
            case .unknown: self = .unavailable
            }
        }
    }

    var isAvailable: Bool { self == .available }

    static let rowTitle = "Apple Intelligence（オンデバイスAI）"

    /// 翻訳キー（日本語）。表示時に `AppLocalizer` を通す。
    var labelKey: String {
        switch self {
        case .available: return "利用できます"
        case .appleIntelligenceOff: return "Apple Intelligenceがオフです"
        case .deviceNotEligible: return "このMacは対応していません"
        case .modelNotReady: return "モデルを準備中です"
        case .unavailable: return "利用できません"
        }
    }

    /// 翻訳キー（日本語）。
    var detailKey: String {
        switch self {
        case .available:
            return "文章の整形や最適化に使うオンデバイスAIを利用できます。データはこのMacの外へ送られません。"
        case .appleIntelligenceOff:
            return "システム設定の「Apple IntelligenceとSiri」でApple Intelligenceをオンにすると、AI機能を利用できます。MacとSiriの言語が違うと、この項目が表示されないことがあります。"
        case .deviceNotEligible:
            return "このMacはApple Intelligenceに対応していないため、AI機能は利用できません。音声入力と文字起こしは使えます。"
        case .modelNotReady:
            return "AIモデルをダウンロード中または準備中です。MacとSiriの言語が同じか確認し、しばらくしてから状態を更新してください。"
        case .unavailable:
            return "オンデバイスAIの状態を確認できないか、このmacOSでは利用できません。音声入力と文字起こしは使えます。"
        }
    }

    func label(language: AppLanguage) -> String {
        AppLocalizer.text(labelKey, language: language)
    }

    func detail(language: AppLanguage) -> String {
        AppLocalizer.text(detailKey, language: language)
    }
}

/// Presentation decisions accept supplied values; previews never need a live model.
enum OnboardingAIReadinessPolicy {
    static func status(isPreview: Bool, current: () -> AppleIntelligenceStatus) -> AppleIntelligenceStatus {
        isPreview ? .available : current()
    }

    static func showsCore3Notice(isPreview: Bool, isCore3: Bool) -> Bool {
        !isPreview && isCore3
    }
}
