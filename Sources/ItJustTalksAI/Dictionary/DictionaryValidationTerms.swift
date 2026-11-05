import Foundation

/// What the validator needs to know about the dictionary entries handed to one generation. Shared by every
/// pipeline that selects dictionary entries (cleanup, AI command and optimizer), so the dictionary →
/// validation rules live in one place.
public struct DictionaryValidationTerms: Sendable, Hashable {
    /// `ValidationInput.allowedNewTerms`.
    public var allowedNewTerms: [String]
    /// `ValidationInput.reviewOnlyTerms`.
    public var reviewOnlyTerms: [String]
    /// `ValidationInput.selectedDictionary`.
    public var selectedDictionary: [DictionaryHint]

    /// Hands-free: an entry found only by sound may be a homophone ("今度" for "近藤"), so its spelling is never
    /// licensed for automatic use (review only), and every passed entry is checked against the transcript's
    /// evidence. Otherwise every selected spelling is licensed as new content.
    public init(_ selection: DictionarySelection, handsFree: Bool) {
        allowedNewTerms = selection.selected.filter { !handsFree || $0.matchKind != .phonetic }.map(\.hint.preferred)
        reviewOnlyTerms = handsFree ? selection.selected.filter { $0.matchKind == .phonetic }.map(\.hint.preferred) : []
        selectedDictionary = handsFree ? selection.hints : []
    }
}
