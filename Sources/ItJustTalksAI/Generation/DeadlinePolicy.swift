import Foundation

/// Per-request deadline (§6.5, STATE-07):
///
/// ```text
/// deadline = min(cap, fixedWait + inputTokens / readRate + reservedOutput / generationRate × safetyFactor)
/// ```
///
/// Measured on the monotonic `ContinuousClock`. The operation's `cap` runs from the moment the operation is
/// requested, and every model call's deadline is also clipped to it; a retry reuses the call's deadline and
/// never extends it.
public struct DeadlinePolicy: Sendable, Hashable {
    public var cap: Duration
    public var fixedWait: Duration
    public var readTokensPerSecond: Double
    public var generationTokensPerSecond: Double
    public var safetyFactor: Double
    /// Output reservation assumed when a request leaves `maximumResponseTokens` unset.
    public var defaultReservedOutputTokens: Int

    public init(
        cap: Duration,
        fixedWait: Duration = DeadlineConstants.fixedWait,
        readTokensPerSecond: Double = DeadlineConstants.readTokensPerSecond,
        generationTokensPerSecond: Double = DeadlineConstants.generationTokensPerSecond,
        safetyFactor: Double = DeadlineConstants.safetyFactor,
        defaultReservedOutputTokens: Int = DeadlineConstants.defaultReservedOutputTokens
    ) {
        self.cap = cap
        self.fixedWait = fixedWait
        self.readTokensPerSecond = readTokensPerSecond
        self.generationTokensPerSecond = generationTokensPerSecond
        self.safetyFactor = safetyFactor
        self.defaultReservedOutputTokens = defaultReservedOutputTokens
    }

    /// Time allowed for one model call. Invalid rates fall back to the cap (fail-safe: never zero).
    public func allowance(inputTokens: Int, reservedOutputTokens: Int) -> Duration {
        guard readTokensPerSecond > 0, generationTokensPerSecond > 0, safetyFactor.isFinite, safetyFactor > 0 else {
            return cap
        }
        let seconds = fixedWait.seconds
            + Double(max(0, inputTokens)) / readTokensPerSecond
            + Double(max(0, reservedOutputTokens)) / generationTokensPerSecond * safetyFactor
        guard seconds.isFinite, seconds < cap.seconds else { return cap }
        return .seconds(seconds)
    }

    /// Normal cleanup (§6.5: 60 s cap).
    public static let cleanup = DeadlinePolicy(cap: DeadlineConstants.cleanupCap)
    /// AI command (§6.5: 90 s cap).
    public static let aiCommand = DeadlinePolicy(cap: DeadlineConstants.aiCommandCap)
}

/// Conservative constants behind `DeadlinePolicy` (provisional until per-model percentiles exist, §6.5).
///
/// Source: P1 on-device report, generation ≈ 60–70 tokens/s. The plan asks for the low side of the measured
/// distribution; until a 5th percentile is measured per device/variant, rates are set to about half the
/// measured median, and cold-start/session creation is covered by `fixedWait` (P1 cold first calls ≈ 0.4–1 s).
public enum DeadlineConstants {
    /// Output generation rate used for deadlines (P1 median ≈ 60–70 tok/s; ~½ for a conservative bound).
    public static let generationTokensPerSecond: Double = 30
    /// Prompt reading (prefill) rate. Prefill is much faster than generation; 300 tok/s is a low bound.
    public static let readTokensPerSecond: Double = 300
    /// Session creation, model load and scheduling (cold start included).
    public static let fixedWait: Duration = .seconds(3)
    /// Multiplier on the output term.
    public static let safetyFactor: Double = 1.5
    /// Reservation assumed when `maximumResponseTokens` is unset.
    public static let defaultReservedOutputTokens = 1024
    public static let cleanupCap: Duration = .seconds(60)
    public static let aiCommandCap: Duration = .seconds(90)
    public static let longTextCap: Duration = .seconds(300)
}

extension Duration {
    /// Seconds as a floating-point value.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Milliseconds, same arithmetic as the evaluation harness.
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
