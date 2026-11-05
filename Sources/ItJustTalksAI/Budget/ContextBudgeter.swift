import Foundation

/// Output reservation `O = f(task, bodyTokens)` (§5.1): `clamp(coefficient × body + constant, minimum…maximum)`.
///
/// All coefficients are configuration values to be calibrated per OS build / variant in P1 (ADD-11),
/// not hard truths.
public struct OutputReservationPolicy: Sendable, Hashable {
    public var coefficient: Double
    public var constant: Int
    public var minimum: Int
    public var maximum: Int?

    public init(coefficient: Double, constant: Int, minimum: Int = 0, maximum: Int? = nil) {
        self.coefficient = coefficient
        self.constant = constant
        self.minimum = minimum
        self.maximum = maximum
    }

    /// Upper bound for any token quantity handled here; larger values are treated as invalid.
    static let tokenLimit = 1 << 40

    /// Usable policy: finite non-negative coefficient, non-negative constant/minimum and
    /// `maximum ≥ max(1, minimum)` when set. (A zero reservation for a given body is rejected by `decide`.)
    public var isValid: Bool {
        coefficient.isFinite && coefficient >= 0 && coefficient < 1_000
            && (0...Self.tokenLimit).contains(constant) && (0...Self.tokenLimit).contains(minimum)
            && (maximum.map { $0 >= max(1, minimum) && $0 <= Self.tokenLimit } ?? true)
    }

    public func reservation(forBodyTokens body: Int) -> Int {
        // Subtract a tiny epsilon so binary-float noise (1.1 × 1000 = 1100.0000000000002) does not round up.
        let scaled = (coefficient * Double(min(max(0, body), Self.tokenLimit)) - 1e-9).rounded(.up)
        // Saturate instead of trapping on NaN / huge values; `decide` rejects such configurations anyway.
        let product = scaled.isFinite ? Int(min(max(scaled, 0), Double(Self.tokenLimit))) : Self.tokenLimit
        var value = product + min(max(constant, 0), Self.tokenLimit)
        value = max(value, minimum)
        if let maximum { value = min(value, maximum) }
        return max(0, value)
    }
}

/// Per-task budgeting profile.
public struct BudgetTaskProfile: Sendable, Hashable {
    public var reservation: OutputReservationPolicy
    /// Whether the body may be split into chunks when a single request does not fit (§5.2).
    public var allowsChunking: Bool

    public init(reservation: OutputReservationPolicy, allowsChunking: Bool) {
        self.reservation = reservation
        self.allowsChunking = allowsChunking
    }
}

/// Budgeting configuration. **Provisional defaults** — calibrate in P1 and record values with evaluations.
public struct BudgetConfiguration: Sendable, Hashable {
    public var profiles: [AITask: BudgetTaskProfile]
    /// Measured hidden overhead `usage.input − Σ tokenCount` (framework framing, role tags…). Provisional.
    public var hiddenOverheadTokens: Int
    /// Safety margin as a fraction of `C`. Provisional.
    public var marginRatio: Double
    /// Smallest body chunk worth sending; below this the request is reported as impossible (CUSTOM-06).
    public var minimumChunkBodyTokens: Int

    /// Ranges every `decide` relies on: `H ≥ 0`, finite margin in [0, 1), valid reservation policies.
    public var isValid: Bool {
        (0...OutputReservationPolicy.tokenLimit).contains(hiddenOverheadTokens)
            && marginRatio.isFinite && marginRatio >= 0 && marginRatio < 1
            && (1...OutputReservationPolicy.tokenLimit).contains(minimumChunkBodyTokens)
            && profiles.values.allSatisfy { $0.reservation.isValid }
    }

    public init(
        profiles: [AITask: BudgetTaskProfile],
        hiddenOverheadTokens: Int,
        marginRatio: Double,
        minimumChunkBodyTokens: Int
    ) {
        self.profiles = profiles
        self.hiddenOverheadTokens = hiddenOverheadTokens
        self.marginRatio = marginRatio
        self.minimumChunkBodyTokens = minimumChunkBodyTokens
    }

    /// PROVISIONAL defaults (uncalibrated). Cleanup ≈ 1.1 × body + constant (§5.1).
    public static let provisionalDefault = BudgetConfiguration(
        profiles: [
            .cleanup: .init(reservation: .init(coefficient: 1.1, constant: 32, minimum: 64), allowsChunking: true),
            .proofreadRewrite: .init(reservation: .init(coefficient: 1.2, constant: 32, minimum: 64), allowsChunking: true),
            // Translation ratio depends on the language pair; measure per pair (§5.1).
            .translate: .init(reservation: .init(coefficient: 1.6, constant: 32, minimum: 64), allowsChunking: true),
            .transform: .init(reservation: .init(coefficient: 1.2, constant: 32, minimum: 64), allowsChunking: true),
            .summarize: .init(reservation: .init(coefficient: 0.4, constant: 64, minimum: 128, maximum: 1024), allowsChunking: true),
            .extract: .init(reservation: .init(coefficient: 0.5, constant: 64, minimum: 128, maximum: 1024), allowsChunking: true),
            .explainAnalyze: .init(reservation: .init(coefficient: 0.3, constant: 256, minimum: 256, maximum: 1024), allowsChunking: true),
            .answerQuestion: .init(reservation: .init(coefficient: 0.2, constant: 256, minimum: 256, maximum: 1024), allowsChunking: false),
            .composeReply: .init(reservation: .init(coefficient: 0.3, constant: 256, minimum: 256, maximum: 1024), allowsChunking: false),
            .taskClassification: .init(reservation: .init(coefficient: 0, constant: 48), allowsChunking: false),
            .unifiedCommand: .init(reservation: .init(coefficient: 1.2, constant: 64, minimum: 128), allowsChunking: false),
            .instructionOptimization: .init(reservation: .init(coefficient: 0, constant: 320), allowsChunking: true),
            // Stage A lists short transcript spans; it is skipped (single-stage cleanup) when it does not fit.
            .selfCorrection: .init(reservation: .init(coefficient: 0.6, constant: 64, minimum: 96, maximum: 512), allowsChunking: false),
        ],
        hiddenOverheadTokens: 32,
        marginRatio: 0.03,
        minimumChunkBodyTokens: 64
    )
}

/// Inputs to one budget decision (§5.1). All values are token counts.
public struct BudgetInput: Sendable, Hashable {
    public var task: AITask
    /// `C`: runtime context size.
    public var contextSize: Int
    /// `Tf`: tokenCount of the fixed instructions.
    public var fixedInstructionTokens: Int
    /// `Td`: tokenCount of the final prompt (body + dictionary + custom instructions + output language).
    public var promptTokens: Int
    /// The share of `Td` that is the splittable body (transcript or target text).
    public var bodyTokens: Int
    /// `Ts`: tokenCount of the generation schema (structured generation only).
    public var schemaTokens: Int

    public init(
        task: AITask,
        contextSize: Int,
        fixedInstructionTokens: Int,
        promptTokens: Int,
        bodyTokens: Int,
        schemaTokens: Int = 0
    ) {
        self.task = task
        self.contextSize = contextSize
        self.fixedInstructionTokens = fixedInstructionTokens
        self.promptTokens = promptTokens
        self.bodyTokens = bodyTokens
        self.schemaTokens = schemaTokens
    }
}

public enum BudgetImpossibleReason: Sendable, Hashable {
    case invalidInput
    /// Instructions + non-body prompt (e.g. long custom instructions) leave no room for a minimal chunk.
    case fixedOverheadTooLarge
    case customInstructionTooLong
    /// Does not fit and the task cannot be split.
    case chunkingNotAllowed
    case unknownTask
}

public enum BudgetDecision: Sendable, Hashable {
    /// Single request fits. Use this as `maximumResponseTokens`.
    case fits(maximumResponseTokens: Int)
    /// Split the body into chunks of at most this many tokens (each chunk re-budgeted before sending).
    case needsChunking(maxBodyTokens: Int)
    /// Explicit error — never silently drop text (CTX-05/06).
    case impossible(BudgetImpossibleReason)
}

/// Pure budget calculator: `Tf + Td + Ts + O + H ≤ C`, `maximumResponseTokens = O`.
public struct ContextBudgeter: Sendable {
    public var configuration: BudgetConfiguration

    public init(configuration: BudgetConfiguration = .provisionalDefault) {
        self.configuration = configuration
    }

    /// `H` = measured hidden overhead + margin ratio × C. Saturates for invalid configurations
    /// (`decide` rejects those before using it).
    public func overhead(contextSize: Int) -> Int {
        let limit = OutputReservationPolicy.tokenLimit
        let margin = (configuration.marginRatio * Double(min(max(0, contextSize), limit))).rounded(.up)
        let marginTokens = margin.isFinite ? Int(min(max(margin, 0), Double(limit))) : limit
        return min(max(configuration.hiddenOverheadTokens, 0), limit) + marginTokens
    }

    public func decide(_ input: BudgetInput) -> BudgetDecision {
        let limit = OutputReservationPolicy.tokenLimit
        guard configuration.isValid,
              (1...limit).contains(input.contextSize),
              (0...limit).contains(input.fixedInstructionTokens), (0...limit).contains(input.promptTokens),
              (0...limit).contains(input.schemaTokens),
              input.bodyTokens >= 0, input.bodyTokens <= input.promptTokens else {
            return .impossible(.invalidInput)
        }
        guard let profile = configuration.profiles[input.task] else {
            return .impossible(.unknownTask)
        }
        let policy = profile.reservation
        let h = overhead(contextSize: input.contextSize)
        let o = policy.reservation(forBodyTokens: input.bodyTokens)
        // A zero reservation would disable truncation detection (`maximumResponseTokens` must be > 0).
        guard o >= 1 else { return .impossible(.invalidInput) }
        // All terms are ≤ 2^40, so the sum cannot overflow; checked anyway.
        var total = 0
        for term in [input.fixedInstructionTokens, input.promptTokens, input.schemaTokens, o, h] {
            let (sum, overflow) = total.addingReportingOverflow(term)
            if overflow { return .impossible(.invalidInput) }
            total = sum
        }
        if total <= input.contextSize {
            return .fits(maximumResponseTokens: o)
        }

        guard profile.allowsChunking, input.bodyTokens > 0 else {
            return .impossible(input.bodyTokens > 0 ? .chunkingNotAllowed : .fixedOverheadTooLarge)
        }

        // Everything except the body and its reservation stays in each chunk request.
        let nonBody = input.fixedInstructionTokens + (input.promptTokens - input.bodyTokens) + input.schemaTokens + h
        let available = input.contextSize - nonBody
        let maxBody = Self.largestBody(available: available, below: input.bodyTokens, policy: policy)
        guard maxBody >= configuration.minimumChunkBodyTokens else {
            return .impossible(.fixedOverheadTooLarge)
        }
        return .needsChunking(maxBodyTokens: maxBody)
    }

    /// Counterfactual for CUSTOM-06: only attribute failure to the instruction if removing it
    /// restores room for the minimum body and its output. All reservation numbers stay unchanged.
    public func customInstructionPreventsMinimumBody(_ input: BudgetInput, promptTokensWithoutInstruction: Int) -> Bool {
        let limit = OutputReservationPolicy.tokenLimit
        guard configuration.isValid, let profile = configuration.profiles[input.task],
              (1...limit).contains(input.contextSize),
              (0...limit).contains(input.fixedInstructionTokens),
              (0...limit).contains(input.schemaTokens),
              (0...limit).contains(input.promptTokens),
              input.bodyTokens >= 0, input.promptTokens >= input.bodyTokens,
              promptTokensWithoutInstruction >= input.bodyTokens,
              promptTokensWithoutInstruction < input.promptTokens else { return false }
        let minimumBody = min(input.bodyTokens, configuration.minimumChunkBodyTokens)
        let other = input.fixedInstructionTokens + input.schemaTokens + overhead(contextSize: input.contextSize)
            + minimumBody + profile.reservation.reservation(forBodyTokens: minimumBody)
        return other + input.promptTokens - input.bodyTokens > input.contextSize
            && other + promptTokensWithoutInstruction - input.bodyTokens <= input.contextSize
    }

    /// Largest `b < limit` with `b + O(b) ≤ available` (binary search; `b + O(b)` is non-decreasing).
    static func largestBody(available: Int, below limit: Int, policy: OutputReservationPolicy) -> Int {
        guard available > 0 else { return 0 }
        var low = 0
        var high = max(0, min(limit - 1, available))
        guard low + policy.reservation(forBodyTokens: low) <= available else { return 0 }
        while low < high {
            let mid = (low + high + 1) / 2
            if mid + policy.reservation(forBodyTokens: mid) <= available {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}
