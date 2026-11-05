import Foundation

extension CleanupPipeline {
    /// Text to insert when AI cleanup could not produce a result (validation failure, unavailable model,
    /// refusal, timeout …): the raw transcript with literal dictionary substitution only. Nothing validates
    /// this text, so it never removes words (RestartCollapser stays on the validated AI path).
    /// Pure; never logs text. Callers keep the raw transcript separately for restore-original.
    public func deterministicFallbackText(for input: CleanupInput) -> String {
        guard !Task.isCancelled else { return input.transcript }
        let selection = DictionarySelector().select(
            entries: input.dictionaryEntries, text: input.transcript,
            options: DictionarySelectionOptions(
                includeMemo: configuration.includeDictionaryMemo, promptLanguage: input.promptLanguage
            )
        )
        guard !Task.isCancelled else { return input.transcript }
        return DictionaryLiteralSubstitution(selection: selection, entries: input.dictionaryEntries)
            .apply(to: input.transcript).text
    }
}
