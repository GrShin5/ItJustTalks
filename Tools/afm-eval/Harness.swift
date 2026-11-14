import Foundation
import FoundationModels
import ItJustTalksAI

/// Aggregated model-call measurements of one case.
struct CallAccumulator: Sendable {
    var calls = 0
    var latencyMs = 0.0
    var inputTokens = 0
    var outputTokens = 0
    var sawUsage = false
    var truncated = false
    /// Cold = the case's first call was the first generation of the process.
    var cold: Bool?

    mutating func add(latencyMs: Double, usage: TokenUsage?, truncated: Bool, cold: Bool) {
        if calls == 0 { self.cold = cold }
        calls += 1
        self.latencyMs += latencyMs
        if let usage {
            sawUsage = true
            inputTokens += usage.inputTokens
            outputTokens += usage.outputTokens
        }
        self.truncated = self.truncated || truncated
    }
}

/// Reply a fake generator should give (only used with `--fake`).
enum FakeReplyPlan: Sendable {
    case text(String)
    /// JSON for the requested `Generable` type.
    case json(String)
}

enum BudgetResult: Sendable {
    case fits(maximumResponseTokens: Int, measures: [String: Double])
    case needsChunking(maxBodyTokens: Int, measures: [String: Double])
    case impossible(String, measures: [String: Double])
    case tokenCountFailed(AIFailure)
}

/// Wraps the generator: cold/warm tracking, budget decisions and fake-reply scripting.
final class Harness: @unchecked Sendable {
    let generator: any TextGenerating
    let fake: FakeGenerator?
    let options: RunOptions
    let settings: SettingsRecord
    let model: ModelRecord
    let budgeter = ContextBudgeter()

    private let lock = NSLock()
    private var generationCount = 0
    private var instructionTokenCache: [String: Int] = [:]
    private var schemaTokenCache: [String: Int] = [:]

    /// Every n-th fake generation fails with a refusal, to exercise failure accounting.
    private static let fakeFailureEvery = 7

    init(options: RunOptions) throws {
        self.options = options
        if options.fake {
            let fake = FakeGenerator(contextSize: 4096, variantName: "fake")
            self.fake = fake
            self.generator = fake
        } else if #available(macOS 27, *) {
            self.fake = nil
            self.generator = OnDeviceGenerator()
        } else {
            throw OptionError.message("macOS 27 or later is required (use --fake for a smoke test)")
        }
        self.settings = SettingsRecord(
            contextLimit: options.contextLimit,
            chunkContext: options.chunkContext.rawValue,
            projection: options.projection.rawValue,
            promptLang: options.promptLanguage.rawValue,
            guardrails: options.guardrails.rawValue,
            commandMethod: options.commandMethod.rawValue,
            correctionMethod: options.correctionMethod.rawValue,
            dictionaryMemo: options.dictionaryMemo,
            fake: options.fake
        )
        self.model = ModelRecord(
            variant: generator.variantName,
            contextSize: generator.contextSize,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: Self.sysctlString("hw.model"),
            memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        )
    }

    var availability: ModelAvailability { generator.availability }

    // MARK: - Token counts and budget

    func instructionTokens(_ text: String) async -> Result<Int, AIFailure> {
        if let cached = lock.withLock({ instructionTokenCache[text] }) { return .success(cached) }
        do {
            let count = try await generator.tokenCount(for: .instructions(text))
            lock.withLock { instructionTokenCache[text] = count }
            return .success(count)
        } catch {
            return .failure(error)
        }
    }

    func schemaTokens<Output: Generable>(_ type: Output.Type) async -> Result<Int, AIFailure> {
        let key = String(describing: type)
        if let cached = lock.withLock({ schemaTokenCache[key] }) { return .success(cached) }
        do {
            let count = try await generator.schemaTokenCount(for: type)
            lock.withLock { schemaTokenCache[key] = count }
            return .success(count)
        } catch {
            return .failure(error)
        }
    }

    func budget(
        task: AITask,
        instructions: String,
        prompt: String,
        body: String,
        schemaTokens: Int = 0
    ) async -> BudgetResult {
        let fixed: Int
        let promptTokens: Int
        let bodyTokens: Int
        switch await instructionTokens(instructions) {
        case .success(let value): fixed = value
        case .failure(let failure): return .tokenCountFailed(failure)
        }
        do {
            promptTokens = try await generator.tokenCount(for: .prompt(prompt))
            bodyTokens = body.isEmpty ? 0 : min(try await generator.tokenCount(for: .prompt(body)), promptTokens)
        } catch {
            return .tokenCountFailed(error)
        }
        let input = BudgetInput(
            task: task, contextSize: generator.contextSize, fixedInstructionTokens: fixed,
            promptTokens: promptTokens, bodyTokens: bodyTokens, schemaTokens: schemaTokens
        )
        var measures: [String: Double] = [
            "budget.contextSize": Double(generator.contextSize),
            "budget.fixedInstructionTokens": Double(fixed),
            "budget.promptTokens": Double(promptTokens),
            "budget.bodyTokens": Double(bodyTokens),
            "budget.schemaTokens": Double(schemaTokens),
        ]
        switch budgeter.decide(input) {
        case .fits(let maximum):
            measures["budget.maxResponseTokens"] = Double(maximum)
            return .fits(maximumResponseTokens: maximum, measures: measures)
        case .needsChunking(let maxBody):
            measures["budget.maxBodyTokens"] = Double(maxBody)
            return .needsChunking(maxBodyTokens: maxBody, measures: measures)
        case .impossible(let reason):
            return .impossible(String(describing: reason), measures: measures)
        }
    }

    // MARK: - Generation

    func makeRequest(task: AITask, instructions: String, prompt: String, maximumResponseTokens: Int?) -> GenerationRequest {
        GenerationRequest(
            instructions: instructions, prompt: prompt, maximumResponseTokens: maximumResponseTokens,
            greedy: true, guardrails: options.guardrails.mode(for: task)
        )
    }

    func text(
        _ request: GenerationRequest,
        fake plan: @autoclosure @escaping () -> FakeReplyPlan,
        into accumulator: inout CallAccumulator
    ) async -> Result<GenerationResult, AIFailure> {
        let cold = beginGeneration(fakePlan: plan)
        let start = ContinuousClock.now
        do {
            let result = try await generator.generate(request)
            accumulator.add(
                latencyMs: milliseconds(result.latency), usage: result.usage, truncated: result.isTruncated, cold: cold
            )
            return .success(result)
        } catch {
            accumulator.add(latencyMs: milliseconds(ContinuousClock.now - start), usage: nil, truncated: false, cold: cold)
            return .failure(error)
        }
    }

    func structured<Output: Generable & Sendable>(
        _ request: GenerationRequest,
        as type: Output.Type,
        fake plan: @autoclosure @escaping () -> FakeReplyPlan,
        into accumulator: inout CallAccumulator
    ) async -> Result<StructuredGenerationResult<Output>, AIFailure> {
        let cold = beginGeneration(fakePlan: plan)
        let start = ContinuousClock.now
        do {
            let result = try await generator.generate(request, generating: type)
            accumulator.add(
                latencyMs: milliseconds(result.latency), usage: result.usage, truncated: result.isTruncated, cold: cold
            )
            return .success(result)
        } catch {
            accumulator.add(latencyMs: milliseconds(ContinuousClock.now - start), usage: nil, truncated: false, cold: cold)
            return .failure(error)
        }
    }

    /// Counts the generation, reports whether it is the first one, and scripts the fake reply.
    func beginGeneration(fakePlan: () -> FakeReplyPlan) -> Bool {
        let number: Int = lock.withLock {
            generationCount += 1
            return generationCount
        }
        if let fake {
            if number % Self.fakeFailureEvery == 0 {
                fake.enqueue(.init(.failure(.refusal)))
            } else {
                switch fakePlan() {
                case .text(let text), .json(let text):
                    fake.enqueue(.init(.text(text, usage: TokenUsage(inputTokens: max(1, text.count / 2) + 40, outputTokens: max(1, text.count / 2)))))
                }
            }
        }
        return number == 1
    }

    // MARK: - Helpers

    func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
