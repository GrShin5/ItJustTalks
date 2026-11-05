import Foundation

/// Warning only: never used to cap, truncate or reject saved instructions.
public struct CustomInstructionLength: Sendable, Equatable {
    public enum Level: Sendable { case appropriate, long, unprocessable }
    // Provisional context ratios. The warning starts well below the optimizer's single-call
    // input capacity (after fixed/schema/output overhead); larger drafts are losslessly chunked.
    public static let longRatio = 0.10
    public static let unprocessableRatio = 0.25
    public let tokens: Int
    public let contextSize: Int
    public let estimated: Bool

    public init(tokens: Int, contextSize: Int, estimated: Bool = false) {
        self.tokens = tokens
        self.contextSize = max(1, contextSize)
        self.estimated = estimated
    }

    public var level: Level {
        let ratio = Double(tokens) / Double(contextSize)
        if ratio >= Self.unprocessableRatio { return .unprocessable }
        if ratio >= Self.longRatio { return .long }
        return .appropriate
    }

    /// Runs off the UI actor. No sessions, generation, persistence or content logging.
    public static func measure(_ text: String, using generator: some TextGenerating) async -> Self {
        if case .available = generator.availability,
           let tokens = try? await generator.tokenCount(for: .prompt(text)) {
            return Self(tokens: tokens, contextSize: generator.contextSize)
        }
        return Self(tokens: text.isEmpty ? 0 : DictionarySelector.estimatedTokens(text), contextSize: generator.contextSize, estimated: true)
    }
}
