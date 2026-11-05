/// Content-free cancellation recovery accounting, shared with contract tests.
enum CancelRecovery {
    static func failed(outcome: String, hadText: Bool) -> Bool {
        outcome != "ok" || !hadText
    }
}
