import AppKit

/// ADD-09（後半）：派生元アプリ（Koedex）が同時に起動しているかを検出し、案内文を返す。
///
/// - 情報提供だけを行い、起動・録音・挿入は妨げない。
/// - 既定ホットキーはここで変更しない（ユーザー判断待ち。既定値は `HotkeyBinding` と
///   `SettingsStore` の既存の定義箇所にある）。
/// - このファイルは派生元のバンドルIDを意図的に名指しするため、
///   `scripts/identifier_allowlist.txt` の許可対象になっている。
enum UpstreamAppCoexistence {
    /// 派生元アプリが使っていた既知のバンドルID（本番版・初回セットアップDebug版）。
    static let upstreamBundleIdentifiers: Set<String> = [
        "com.koedex.app",
        "com.koedex.onboarding-debug",
    ]

    /// 結果パネルの見出し。`Localizable.strings` で英訳する。
    static let noticeTitle = "同時起動の確認"

    /// 起動中アプリのバンドルID一覧に、派生元アプリが含まれるかを判定する純粋関数。
    static func isUpstreamAppRunning(runningBundleIdentifiers: [String?]) -> Bool {
        runningBundleIdentifiers.contains { identifier in
            guard let identifier else { return false }
            return upstreamBundleIdentifiers.contains(identifier)
        }
    }

    /// `NSWorkspace.didLaunchApplicationNotification` が運んできたアプリが派生元アプリかを判定する。
    static func isUpstreamAppLaunch(_ notification: Notification) -> Bool {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return isUpstreamAppRunning(runningBundleIdentifiers: [app?.bundleIdentifier])
    }

    static func isUpstreamAppRunning() -> Bool {
        isUpstreamAppRunning(
            runningBundleIdentifiers: NSWorkspace.shared.runningApplications.map(\.bundleIdentifier)
        )
    }

    static func noticeMessage(language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return "Koedexが起動中です。ItJustTalksとKoedexで同じショートカットキーを使っていると、1回のキー操作で両方のアプリが録音・入力することがあります。どちらかのアプリを終了するか、ItJustTalksの設定でショートカットキーを変更してください。"
        case .english:
            return "Koedex is running. If ItJustTalks and Koedex use the same shortcut keys, a single key press may make both apps record and insert text. Quit one of the apps, or change the shortcut keys in ItJustTalks settings."
        }
    }
}
