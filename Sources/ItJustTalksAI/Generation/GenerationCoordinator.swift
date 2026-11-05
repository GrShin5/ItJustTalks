import Foundation
import FoundationModels

/// What a pipeline uses to run its model calls and token counts. Implementations apply the coordination
/// policy (deadline, cancellation, retry, spacing); `generator` is used only for model facts
/// (`contextSize`, `variantName`).
public protocol GenerationExecuting: Sendable {
    var generator: any TextGenerating { get }
    func extendOperationDeadlineForLongText() async
    /// Token count under the operation's deadline and cancellation.
    func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int
    func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int
    /// - Parameter inputTokens: tokens of instructions + prompt (+ schema), for the deadline (§6.5).
    func generate(_ request: GenerationRequest, inputTokens: Int) async throws(AIFailure) -> GenerationResult
    func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest,
        generating type: Output.Type,
        inputTokens: Int
    ) async throws(AIFailure) -> StructuredGenerationResult<Output>
}

public extension GenerationExecuting {
    func extendOperationDeadlineForLongText() async {}
}

private final class OperationDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuousClock.Instant
    private var extended = false
    init(_ value: ContinuousClock.Instant) { self.value = value }
    var current: ContinuousClock.Instant { lock.withLock { value } }
    func extend(from requestedAt: ContinuousClock.Instant) {
        lock.withLock {
            guard !extended else { return }
            extended = true
            value = max(value, requestedAt + DeadlineConstants.longTextCap)
        }
    }
}

/// Interactive operations (cleanup, AI command) preempt optimization-priority ones (§6.2, STATE-06).
public enum GenerationPriority: Int, Sendable, Hashable, CaseIterable, Comparable {
    case optimization = 0
    case interactive = 1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identity of one request: the operation it belongs to and a coordinator-wide generation number.
public struct GenerationTicket: Sendable, Hashable {
    public let operationID: UUID
    public let generation: UInt64
    public let priority: GenerationPriority
}

/// Why a request's result was not delivered.
public enum GenerationCancellation: String, Sendable, Hashable, CaseIterable {
    /// `cancel(operation:)` or the caller's task was cancelled.
    case cancelled
    /// A newer request for the same operation replaced it.
    case superseded
    /// An interactive request preempted this optimization request.
    case preempted
}

public enum CoordinatedOutcome<Value: Sendable>: Sendable {
    case delivered(Value)
    case cancelled(GenerationCancellation)
}

/// Serializes on-device generation (§6.2–6.5).
///
/// - One operation runs at a time (PAR-12); interactive requests run before optimization ones and cancel
///   them (they end `.cancelled(.preempted)`).
/// - Every request gets a ticket (operation ID + generation). `cancel(operation:)` cancels the `Task` and
///   invalidates the generation in the same actor step; the result of an invalidated generation is never
///   delivered, even if the work finishes later (STATE-08). A newer request for the same operation
///   supersedes the older one.
/// - Model calls keep a minimum spacing, run under a monotonic deadline (`DeadlinePolicy`), and are retried
///   once on `rateLimited` within that deadline. Nothing else is retried (§6.4).
/// - Work abandoned by a cancel or timeout is awaited before the next model call starts, so the model never
///   runs two requests at once. If it does not stop within `cancelDrainLimit` (or the new call's deadline,
///   whichever comes first), the new call fails with `.timeout` instead of overlapping (single flight first).
/// - A `cancel(operation:)` that arrives before the operation's request is registered still cancels it.
/// - Never logs request or result content.
public actor GenerationCoordinator {
    public struct Configuration: Sendable, Hashable {
        /// Minimum time between the end of one model call and the start of the next (provisional, V-01).
        public var minimumRequestSpacing: Duration
        /// Wait before the single `rateLimited` retry when the framework gives no reset date.
        public var rateLimitDefaultWait: Duration
        /// Longest wait for cancelled/timed-out work to stop before a new model call. If the work is still
        /// running then (or at the new call's deadline, if earlier), the new call fails with `.timeout`; it
        /// never starts alongside the old one.
        public var cancelDrainLimit: Duration

        public init(
            minimumRequestSpacing: Duration = .milliseconds(100),
            rateLimitDefaultWait: Duration = .seconds(1),
            cancelDrainLimit: Duration = .seconds(5)
        ) {
            self.minimumRequestSpacing = minimumRequestSpacing
            self.rateLimitDefaultWait = rateLimitDefaultWait
            self.cancelDrainLimit = cancelDrainLimit
        }

        public static let `default` = Configuration()
    }

    private final class Entry {
        let ticket: GenerationTicket
        var cause: GenerationCancellation?
        var waiter: CheckedContinuation<Bool, Never>?
        var cancelWork: (@Sendable () -> Void)?

        init(ticket: GenerationTicket) { self.ticket = ticket }
    }

    public nonisolated let generator: any TextGenerating
    public nonisolated let configuration: Configuration
    private let clock = ContinuousClock()

    private var nextGeneration: UInt64 = 0
    private var entries: [UInt64: Entry] = [:]
    private var waiting: [Entry] = []
    private var running: UInt64?
    /// Latest generation issued per operation, and the lowest generation still valid (for `isCurrent`).
    private var latest: [UUID: UInt64] = [:]
    private var validFrom: [UUID: UInt64] = [:]
    private var recentOperations: [UUID] = []
    private static let rememberedOperations = 64
    /// Operations cancelled recently (bounded), so a request registered after its cancel is cancelled too.
    private var cancelledOperations: [UUID] = []

    private var lastCallEnd: ContinuousClock.Instant?
    private var abandoned: [Task<Void, Never>] = []
    private var prewarmed: (operation: UUID, session: any PrewarmedSession)?

    public init(generator: any TextGenerating, configuration: Configuration = .default) {
        self.generator = generator
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Runs `body` as one operation once the coordinator grants it the model. The result is delivered only
    /// if the request's generation is still valid when `body` returns.
    public func perform<Value: Sendable>(
        operation: UUID,
        priority: GenerationPriority,
        deadline policy: DeadlinePolicy,
        _ body: @escaping @Sendable (GenerationContext) async -> Value
    ) async -> CoordinatedOutcome<Value> {
        let requestedAt = clock.now
        let entry = register(operation: operation, priority: priority)
        let generation = entry.ticket.generation
        return await withTaskCancellationHandler {
            await run(entry, requestedAt: requestedAt, operationDeadline: requestedAt + policy.cap, policy: policy, body)
        } onCancel: {
            Task { await self.cancel(generation: generation) }
        }
    }

    /// Cancels every request of `operation` (running or waiting) and invalidates its generations. Also
    /// discards the operation's prewarmed session.
    public func cancel(operation: UUID) {
        for entry in entries.values where entry.ticket.operationID == operation {
            invalidate(entry, .cancelled)
        }
        validFrom[operation] = nextGeneration + 1
        if prewarmed?.operation == operation { prewarmed = nil }
        if !cancelledOperations.contains(operation) {
            cancelledOperations.append(operation)
            if cancelledOperations.count > Self.rememberedOperations { cancelledOperations.removeFirst() }
        }
    }

    /// Whether `ticket` is still the operation's newest valid generation (check right before applying a result).
    public func isCurrent(_ ticket: GenerationTicket) -> Bool {
        latest[ticket.operationID] == ticket.generation && ticket.generation >= validFrom[ticket.operationID, default: 0]
    }

    /// Prewarm hook (§6.2): at recording start, creates the session with the operation's static instructions.
    /// It answers the operation's first plain-text request with matching instructions, and is discarded on
    /// cancel, when the operation finishes without using it, or when another operation prewarms.
    public func prewarm(operation: UUID, instructions: String, guardrails: GuardrailsMode) {
        prewarmed = nil
        guard !cancelledOperations.contains(operation) else { return }
        guard let generator = generator as? any SessionPrewarming else { return }
        prewarmed = (operation, generator.makePrewarmedSession(instructions: instructions, guardrails: guardrails))
    }

    /// Whether a prewarmed session is currently held (diagnostics/tests).
    public var hasPrewarmedSession: Bool { prewarmed != nil }

    // MARK: - Scheduling

    private func register(operation: UUID, priority: GenerationPriority) -> Entry {
        nextGeneration += 1
        let ticket = GenerationTicket(operationID: operation, generation: nextGeneration, priority: priority)
        let entry = Entry(ticket: ticket)
        for other in entries.values {
            if other.ticket.operationID == operation {
                invalidate(other, .superseded)
            } else if priority == .interactive, other.ticket.priority == .optimization {
                invalidate(other, .preempted)
            }
        }
        entries[ticket.generation] = entry
        latest[operation] = ticket.generation
        remember(operation)
        if cancelledOperations.contains(operation) { invalidate(entry, .cancelled) }
        return entry
    }

    private func remember(_ operation: UUID) {
        recentOperations.removeAll { $0 == operation }
        recentOperations.append(operation)
        while recentOperations.count > Self.rememberedOperations {
            let old = recentOperations.removeFirst()
            if !entries.values.contains(where: { $0.ticket.operationID == old }) {
                latest[old] = nil
                validFrom[old] = nil
            }
        }
    }

    private func run<Value: Sendable>(
        _ entry: Entry,
        requestedAt: ContinuousClock.Instant,
        operationDeadline: ContinuousClock.Instant,
        policy: DeadlinePolicy,
        _ body: @escaping @Sendable (GenerationContext) async -> Value
    ) async -> CoordinatedOutcome<Value> {
        if Task.isCancelled { invalidate(entry, .cancelled) }
        guard entry.cause == nil, await acquire(entry) else {
            finish(entry, holdsSlot: false)
            return .cancelled(entry.cause ?? .cancelled)
        }
        let context = GenerationContext(
            ticket: entry.ticket, generator: generator, coordinator: self,
            requestedAt: requestedAt, operationDeadline: operationDeadline, policy: policy, configuration: configuration
        )
        let work = Task { await body(context) }
        entry.cancelWork = { work.cancel() }
        if entry.cause != nil { work.cancel() }
        let value = await work.value
        finish(entry, holdsSlot: true)
        if let cause = entry.cause { return .cancelled(cause) }
        if Task.isCancelled { return .cancelled(.cancelled) }
        return .delivered(value)
    }

    /// Waits for the single slot. Returns false when the entry was cancelled while waiting.
    private func acquire(_ entry: Entry) async -> Bool {
        if running == nil {
            running = entry.ticket.generation
            return true
        }
        return await withCheckedContinuation { continuation in
            entry.waiter = continuation
            waiting.append(entry)
        }
    }

    private func finish(_ entry: Entry, holdsSlot: Bool) {
        entries[entry.ticket.generation] = nil
        entry.cancelWork = nil
        if prewarmed?.operation == entry.ticket.operationID,
           !entries.values.contains(where: { $0.ticket.operationID == entry.ticket.operationID }) {
            prewarmed = nil
        }
        guard holdsSlot, running == entry.ticket.generation else { return }
        running = nil
        grantNext()
    }

    private func grantNext() {
        guard running == nil, !waiting.isEmpty else { return }
        // Highest priority first, then oldest generation.
        var bestIndex = 0
        for index in waiting.indices.dropFirst() {
            let candidate = waiting[index].ticket, best = waiting[bestIndex].ticket
            if candidate.priority > best.priority
                || (candidate.priority == best.priority && candidate.generation < best.generation) {
                bestIndex = index
            }
        }
        let next = waiting.remove(at: bestIndex)
        running = next.ticket.generation
        let waiter = next.waiter
        next.waiter = nil
        waiter?.resume(returning: true)
    }

    private func invalidate(_ entry: Entry, _ cause: GenerationCancellation) {
        guard entry.cause == nil else { return }
        entry.cause = cause
        let operation = entry.ticket.operationID
        validFrom[operation] = max(validFrom[operation, default: 0], entry.ticket.generation + 1)
        entry.cancelWork?()
        if let waiter = entry.waiter {
            entry.waiter = nil
            waiting.removeAll { $0 === entry }
            waiter.resume(returning: false)
        }
    }

    private func cancel(generation: UInt64) {
        if let entry = entries[generation] { invalidate(entry, .cancelled) }
    }

    // MARK: - Model calls (used by GenerationContext)

    fileprivate func isValid(_ ticket: GenerationTicket) -> Bool {
        guard let entry = entries[ticket.generation] else { return false }
        return entry.cause == nil
    }

    /// Before each model call: validity, draining of abandoned work, minimum spacing.
    fileprivate func beginCall(_ ticket: GenerationTicket, deadline: ContinuousClock.Instant) async throws(AIFailure) {
        guard isValid(ticket), !Task.isCancelled else { throw .cancelled }
        if !abandoned.isEmpty {
            let pending = abandoned
            abandoned = []
            let limit = min(deadline, clock.now + configuration.cancelDrainLimit)
            var stillRunning: [Task<Void, Never>] = []
            for task in pending {
                let (_, unfinished) = await DeadlineRace.run(until: limit) { () async throws(AIFailure) in await task.value }
                if unfinished != nil { stillRunning.append(task) }
            }
            // Work that has not stopped stays tracked; the new call must not overlap it.
            abandoned = stillRunning + abandoned
            if !stillRunning.isEmpty {
                guard isValid(ticket), !Task.isCancelled else { throw .cancelled }
                throw .timeout
            }
        }
        guard isValid(ticket), !Task.isCancelled else { throw .cancelled }
        if let last = lastCallEnd {
            let earliest = last + configuration.minimumRequestSpacing
            if earliest > clock.now {
                guard earliest < deadline else { throw .timeout }
                do {
                    try await Task.sleep(until: earliest, clock: clock)
                } catch {
                    throw .cancelled
                }
            }
        }
        guard isValid(ticket), !Task.isCancelled else { throw .cancelled }
    }

    fileprivate func endCall(abandoned task: Task<Void, Never>?) {
        lastCallEnd = clock.now
        if let task { abandoned.append(task) }
    }

    fileprivate func takePrewarmed(_ ticket: GenerationTicket, for request: GenerationRequest) -> (any PrewarmedSession)? {
        guard let held = prewarmed, held.operation == ticket.operationID,
              held.session.instructions == request.instructions, held.session.guardrails == request.guardrails else {
            return nil
        }
        prewarmed = nil
        return held.session
    }
}

/// Handed to an operation's body: runs its model calls under the coordinator's policy.
public struct GenerationContext: GenerationExecuting {
    public let ticket: GenerationTicket
    public let generator: any TextGenerating
    /// Monotonic end of the operation (`requested + cap`); no call or retry goes past it.
    public var operationDeadline: ContinuousClock.Instant { deadlineBox.current }
    public let requestedAt: ContinuousClock.Instant
    private let deadlineBox: OperationDeadline
    let coordinator: GenerationCoordinator
    let policy: DeadlinePolicy
    let configuration: GenerationCoordinator.Configuration

    init(
        ticket: GenerationTicket, generator: any TextGenerating, coordinator: GenerationCoordinator,
        requestedAt: ContinuousClock.Instant, operationDeadline: ContinuousClock.Instant, policy: DeadlinePolicy,
        configuration: GenerationCoordinator.Configuration
    ) {
        self.ticket = ticket
        self.generator = generator
        self.coordinator = coordinator
        self.requestedAt = requestedAt
        self.deadlineBox = OperationDeadline(operationDeadline)
        self.policy = policy
        self.configuration = configuration
    }

    public func extendOperationDeadlineForLongText() async { deadlineBox.extend(from: requestedAt) }

    /// Token counting is not a generation (no spacing, no single-flight slot), but it runs under the
    /// operation deadline and cancellation, so a count that never returns cannot hold the operation.
    public func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int {
        let generator = self.generator
        return try await bounded { () async throws(AIFailure) in try await generator.tokenCount(for: subject) }
    }

    public func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int {
        let generator = self.generator
        return try await bounded { () async throws(AIFailure) in try await generator.schemaTokenCount(for: type) }
    }

    private func bounded<T: Sendable>(_ work: @escaping @Sendable () async throws(AIFailure) -> T) async throws(AIFailure) -> T {
        guard !Task.isCancelled else { throw .cancelled }
        let (result, _) = await DeadlineRace.run(until: operationDeadline, work)
        return try result.get()
    }

    public func generate(_ request: GenerationRequest, inputTokens: Int) async throws(AIFailure) -> GenerationResult {
        let generator = self.generator
        let coordinator = self.coordinator
        let ticket = self.ticket
        return try await execute(request, inputTokens: inputTokens) { () async throws(AIFailure) -> GenerationResult in
            if let prewarming = generator as? any SessionPrewarming,
               let session = await coordinator.takePrewarmed(ticket, for: request) {
                return try await prewarming.generate(request, prewarmed: session)
            }
            return try await generator.generate(request)
        }
    }

    public func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest,
        generating type: Output.Type,
        inputTokens: Int
    ) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        let generator = self.generator
        return try await execute(request, inputTokens: inputTokens) { () async throws(AIFailure) in
            try await generator.generate(request, generating: type)
        }
    }

    /// Deadline, spacing and the §6.4 retry rule around one model call. Only `rateLimited` is retried, once,
    /// and only when the wait still fits the call's deadline; the retry never extends that deadline.
    private func execute<T: Sendable>(
        _ request: GenerationRequest,
        inputTokens: Int,
        _ call: @escaping @Sendable () async throws(AIFailure) -> T
    ) async throws(AIFailure) -> T {
        let clock = ContinuousClock()
        let reserved = request.maximumResponseTokens ?? policy.defaultReservedOutputTokens
        let deadline = min(operationDeadline, clock.now + policy.allowance(inputTokens: inputTokens, reservedOutputTokens: reserved))
        var retried = false
        while true {
            try await coordinator.beginCall(ticket, deadline: deadline)
            let (result, abandonedTask) = await DeadlineRace.run(until: deadline, call)
            await coordinator.endCall(abandoned: abandonedTask)
            switch result {
            case .success(let value):
                return value
            case .failure(.rateLimited(let resetDate)) where !retried && !Task.isCancelled:
                let wait = resetDate.map { Duration.seconds(max(0, $0.timeIntervalSinceNow)) } ?? configuration.rateLimitDefaultWait
                let resume = clock.now + wait
                guard resume < deadline else { throw .rateLimited(resetDate: resetDate) }
                retried = true
                do {
                    try await Task.sleep(until: resume, clock: clock)
                } catch {
                    throw .cancelled
                }
            case .failure(let failure):
                throw failure
            }
        }
    }
}

/// Races a unit of work against a deadline and the current task's cancellation without waiting for the work
/// to stop (the work runs in its own task, which is cancelled and handed back as `abandoned`).
enum DeadlineRace {
    private final class OneShot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<T, AIFailure>, Never>?
        private var pending: Result<T, AIFailure>?
        private var done = false
        private(set) var workWon = false

        func install(_ continuation: CheckedContinuation<Result<T, AIFailure>, Never>) {
            let ready: Result<T, AIFailure>? = lock.withLock {
                if let pending { return pending }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }

        /// First resolution wins. Returns whether this call resolved the race.
        @discardableResult
        func resolve(_ result: Result<T, AIFailure>, byWork: Bool) -> Bool {
            let target: CheckedContinuation<Result<T, AIFailure>, Never>?? = lock.withLock {
                guard !done else { return .none }
                done = true
                workWon = byWork
                if let continuation {
                    self.continuation = nil
                    return .some(continuation)
                }
                pending = result
                return .some(nil)
            }
            guard case .some(let continuation) = target else { return false }
            continuation?.resume(returning: result)
            return true
        }

        var isWorkWinner: Bool { lock.withLock { workWon } }
    }

    static func run<T: Sendable>(
        until deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable () async throws(AIFailure) -> T
    ) async -> (Result<T, AIFailure>, abandoned: Task<Void, Never>?) {
        let shot = OneShot<T>()
        let work = Task<Void, Never> {
            let result: Result<T, AIFailure>
            do throws(AIFailure) {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            shot.resolve(result, byWork: true)
        }
        let timer = Task<Void, Never> {
            do {
                try await Task.sleep(until: deadline, clock: ContinuousClock())
            } catch {
                return
            }
            if shot.resolve(.failure(.timeout), byWork: false) { work.cancel() }
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in shot.install(continuation) }
        } onCancel: {
            if shot.resolve(.failure(.cancelled), byWork: false) { work.cancel() }
        }
        timer.cancel()
        return (result, shot.isWorkWinner ? nil : work)
    }
}
