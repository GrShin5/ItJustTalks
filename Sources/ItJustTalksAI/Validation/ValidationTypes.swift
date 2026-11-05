import Foundation

/// Why a result was not accepted as `complete`. Payloads are codes and counts only — never text.
public enum ValidationReason: Sendable, Hashable {
    case generationFailed(AIFailure)
    case truncated
    case refusalPhrase
    case emptyOutput
    case labelOnly
    case preambleOnly
    case leadingPreamble
    case jsonFragment
    case promptLeakage
    case lengthRatioOutOfRange
    case lowContentRetention
    case excessiveNewContent
    case newNumbers(count: Int)
    /// Every number is licensed, but order, multiplicity or a retracted value ("5部、いや3部" → "5部")
    /// does not match the source.
    case numberMismatch
    /// A number of the source is missing from a cleanup / proofread / translation output (a dropped sentence or
    /// fact). Values the speaker retracted are not required. Each distinct value must appear at least once.
    case numbersDropped(count: Int)
    /// Cleanup kept a segment the speaker retracted with a correction cue ("三階、いや四階" → "三階、四階").
    case selfCorrectionKept
    /// Cleanup dropped the verb/ending of a dictated request or question ("…を調べてください" → "…の天気").
    case requestEndingLost
    /// Hands-free cleanup kept a filler that the transcript used as a filler ("えーと、", "あの、", "um").
    case residualFiller
    /// Cleanup dropped or added a negation ("振り込まないで" → "振り込んで", "don't forward" → "forward") that a
    /// self-correction does not explain.
    case negationChanged
    /// A closing remark the source did not contain ("以上です。", "I hope this helps!").
    case trailingPostscript
    /// Cross-language cleanup in hands-free mode: the ADD-04 overlap check cannot run, so it is not sent.
    case overlapUnverifiable
    /// The output introduces a dictionary spelling whose entry matched the transcript only by sound
    /// (`ValidationInput.reviewOnlyTerms`); the replacement may be a homophone, so it is not sent automatically.
    case unverifiedDictionaryReplacement
    /// The validation input itself is unusable (e.g. no protected instructions were supplied).
    case invalidInput
    case translationUnchanged
    case languageMismatch(expected: String, detected: String?)
    case chunkFailed(index: Int)
    case chunkNeedsReview(index: Int)
    case chunkBoundaryGap(index: Int)
    case chunkBoundaryOverlap(index: Int)
    case chunkBoundaryDuplicate(index: Int)
    case crossChunkCorrection(index: Int)

    /// Stable case name only; associated values are deliberately excluded from app diagnostics.
    public var diagnosticName: String {
        switch self {
        case .generationFailed: return "generationFailed"
        case .truncated: return "truncated"
        case .refusalPhrase: return "refusalPhrase"
        case .emptyOutput: return "emptyOutput"
        case .labelOnly: return "labelOnly"
        case .preambleOnly: return "preambleOnly"
        case .leadingPreamble: return "leadingPreamble"
        case .jsonFragment: return "jsonFragment"
        case .promptLeakage: return "promptLeakage"
        case .lengthRatioOutOfRange: return "lengthRatioOutOfRange"
        case .lowContentRetention: return "lowContentRetention"
        case .excessiveNewContent: return "excessiveNewContent"
        case .newNumbers: return "newNumbers"
        case .numberMismatch: return "numberMismatch"
        case .numbersDropped: return "numbersDropped"
        case .selfCorrectionKept: return "selfCorrectionKept"
        case .requestEndingLost: return "requestEndingLost"
        case .residualFiller: return "residualFiller"
        case .negationChanged: return "negationChanged"
        case .trailingPostscript: return "trailingPostscript"
        case .overlapUnverifiable: return "overlapUnverifiable"
        case .unverifiedDictionaryReplacement: return "unverifiedDictionaryReplacement"
        case .invalidInput: return "invalidInput"
        case .translationUnchanged: return "translationUnchanged"
        case .languageMismatch: return "languageMismatch"
        case .chunkFailed: return "chunkFailed"
        case .chunkNeedsReview: return "chunkNeedsReview"
        case .chunkBoundaryGap: return "chunkBoundaryGap"
        case .chunkBoundaryOverlap: return "chunkBoundaryOverlap"
        case .chunkBoundaryDuplicate: return "chunkBoundaryDuplicate"
        case .crossChunkCorrection: return "crossChunkCorrection"
        }
    }
}

/// Result state (§3.6). Only `complete` may be applied automatically (inserted, replaced or sent).
public enum ValidationOutcome: Sendable, Hashable {
    case complete
    case needsReview([ValidationReason])
    case failed([ValidationReason])

    public var isComplete: Bool { self == .complete }

    public var reasons: [ValidationReason] {
        switch self {
        case .complete: return []
        case .needsReview(let reasons), .failed(let reasons): return reasons
        }
    }

    /// Builds an outcome: any failure reason → failed (all reasons kept), else any review reason → needsReview.
    static func from(failures: [ValidationReason], reviews: [ValidationReason]) -> ValidationOutcome {
        if !failures.isEmpty { return .failed(failures + reviews) }
        if !reviews.isEmpty { return .needsReview(reviews) }
        return .complete
    }
}

/// Measured values behind a decision, for evaluation (afm-eval) and threshold calibration. No text.
public struct ValidationMetrics: Sendable, Hashable {
    public var lengthRatio: Double?
    public var contentRetention: Double?
    public var newContentRatio: Double?
    public var newNumberCount: Int
    public var detectedLanguage: String?

    public init(
        lengthRatio: Double? = nil,
        contentRetention: Double? = nil,
        newContentRatio: Double? = nil,
        newNumberCount: Int = 0,
        detectedLanguage: String? = nil
    ) {
        self.lengthRatio = lengthRatio
        self.contentRetention = contentRetention
        self.newContentRatio = newContentRatio
        self.newNumberCount = newNumberCount
        self.detectedLanguage = detectedLanguage
    }
}

public struct ValidationReport: Sendable, Hashable {
    public var outcome: ValidationOutcome
    public var metrics: ValidationMetrics
}

/// Everything the validator needs for one generated text. Contains user text: never log instances.
///
/// `isTruncated`, `protectedInstructions` and `handsFree` have no defaults on purpose (fail-closed): a
/// forgotten value must not silently disable a check. Empty `protectedInstructions` fails validation.
public struct ValidationInput: Sendable {
    public var task: AITask
    /// Transcript (cleanup) or target text (AI command). Empty for general requests without a target.
    public var source: String
    /// Original transcript for language detection when dictionary spellings changed `source`.
    public var languageSource: String?
    /// Exact preferred spellings removed only for output-language detection.
    public var languageIgnoringTerms: [String]
    public var output: String
    /// From `GenerationResult.isTruncated`.
    public var isTruncated: Bool
    /// Fixed instructions used for this request (prompt-leakage check). Must not be empty.
    public var protectedInstructions: [String]
    /// **This request's spoken instruction only** (AI commands). Text here licenses numbers, refusal phrases,
    /// "JSON" and instruction fragments in the output. Do NOT pass dictionary lines, custom instructions or
    /// style preferences (persistent, possibly optimizer-generated). Ignored for `.cleanup`.
    public var userSuppliedTexts: [String]
    /// Preferred spellings from dictionary hints; not counted as new content, and numbers inside a term
    /// are licensed only where the term itself appears in the output.
    public var allowedNewTerms: [String]
    /// Preferred spellings of dictionary entries that matched the transcript only by sound (hands-free).
    /// They are NOT licensed as new content for automatic use: an output that introduces one (absent from the
    /// source) is at most `needsReview` (`unverifiedDictionaryReplacement`). Only where the whole spelling
    /// appears in the output are its words (and numbers) not counted again as new content, so that output is
    /// shown for review rather than dropped; a part of the spelling alone gets no allowance.
    public var reviewOnlyTerms: [String]
    /// Hands-free only: every dictionary entry passed to the model (preferred spelling and its readings). The
    /// output may contain the spelling, or a word of at least two characters inside it that the transcript
    /// lacks, at most as often as the transcript contains the spelling or a reading literally; more is
    /// `unverifiedDictionaryReplacement` (a homophone such as 砂糖 → 佐藤 may have been rewritten).
    public var selectedDictionary: [DictionaryHint]
    /// BCP-47 language code the output must be in (e.g. "en" for translate-to-English). `nil` skips the check.
    /// For `.cleanup`, a code that differs from the transcript's language marks a cross-language cleanup.
    public var expectedOutputLanguage: String?
    /// Hands-free cleanup uses the stricter overlap thresholds (§3.4).
    public var handsFree: Bool
    /// Cleanup had non-empty style preferences; permits list formatting in normal mode only.
    public var hasStylePreferences: Bool
    /// Cleanup only: self-corrections located in the ORIGINAL transcript (`source`) by stage A of the
    /// two-stage cleanup (`SelfCorrection.apply`). Checked in addition to the validator's own cue rules.
    /// `nil` when stage A did not run.
    public var selfCorrections: [SelfCorrectionSpan]?

    public init(
        task: AITask,
        source: String,
        output: String,
        isTruncated: Bool,
        protectedInstructions: [String],
        userSuppliedTexts: [String] = [],
        allowedNewTerms: [String] = [],
        reviewOnlyTerms: [String] = [],
        selectedDictionary: [DictionaryHint] = [],
        expectedOutputLanguage: String? = nil,
        handsFree: Bool,
        hasStylePreferences: Bool = false,
        selfCorrections: [SelfCorrectionSpan]? = nil,
        languageSource: String? = nil,
        languageIgnoringTerms: [String] = []
    ) {
        self.task = task
        self.source = source
        self.languageSource = languageSource
        self.languageIgnoringTerms = languageIgnoringTerms
        self.output = output
        self.isTruncated = isTruncated
        self.protectedInstructions = protectedInstructions
        self.userSuppliedTexts = userSuppliedTexts
        self.allowedNewTerms = allowedNewTerms
        self.reviewOnlyTerms = reviewOnlyTerms
        self.selectedDictionary = selectedDictionary
        self.expectedOutputLanguage = expectedOutputLanguage
        self.handsFree = handsFree
        self.hasStylePreferences = hasStylePreferences
        self.selfCorrections = selfCorrections
    }
}

/// Overlap thresholds for the "answered instead of cleaned" check (ADD-04).
public struct OverlapThresholds: Sendable, Hashable {
    /// Minimum share of source content words kept in the output.
    public var minimumRetention: Double
    /// Maximum share of output content words absent from the source.
    public var maximumNewContentRatio: Double
    /// Skip the retention/new-ratio check when the source has fewer content words than this.
    public var minimumSourceContentWords: Int
    /// Cleanup only: a source with at most this many content words may gain **no** new content word
    /// ("明日の天気は" → "明日の天気は晴れです。" fails). 0 disables the rule.
    public var shortSourceContentWords: Int
    /// Cleanup only: maximum share of new content words within any single output sentence (an appended
    /// answer sentence is mostly new words). 1.0 disables the rule.
    public var maximumSentenceNewContentRatio: Double

    public init(
        minimumRetention: Double,
        maximumNewContentRatio: Double,
        minimumSourceContentWords: Int,
        shortSourceContentWords: Int = 0,
        maximumSentenceNewContentRatio: Double = 1.0
    ) {
        self.minimumRetention = minimumRetention
        self.maximumNewContentRatio = maximumNewContentRatio
        self.minimumSourceContentWords = minimumSourceContentWords
        self.shortSourceContentWords = shortSourceContentWords
        self.maximumSentenceNewContentRatio = maximumSentenceNewContentRatio
    }
}

/// Validator thresholds. **Every default below is PROVISIONAL** — to be set from the P1 evaluation set,
/// including the check that legitimate self-corrections (5部→3部) are not rejected (19.4).
public struct ValidationThresholds: Sendable, Hashable {
    /// Allowed output/source length ratio (characters, whitespace excluded) per task. Missing task = no check.
    public var lengthRatio: [AITask: ClosedRange<Double>]
    /// Skip the length-ratio check for sources shorter than this (short inputs vary too much).
    public var lengthRatioMinimumSourceCharacters: Int
    public var cleanupOverlap: OverlapThresholds
    public var cleanupOverlapHandsFree: OverlapThresholds
    /// Optional overlap check for proofread/rewrite (needsReview only). `nil` disables it.
    public var rewriteOverlap: OverlapThresholds?
    /// Window length (normalized characters) for verbatim instruction-leak detection.
    public var leakageWindowCharacters: Int
    /// Skip the language check for outputs shorter than this.
    public var languageCheckMinimumCharacters: Int
    /// Ignore boundary duplicates shorter than this (normalized characters).
    public var chunkDuplicateMinimumCharacters: Int
    /// Correction cue words detected in later chunks (§3.6 cross-chunk correction).
    public var crossChunkCorrectionCues: [String]
    /// Max characters between a number, a self-correction cue and the corrected number ("5部、いや3部") for the
    /// first number to count as retracted when both carry the same unit.
    public var numberRetractionWindowCharacters: Int

    public init(
        lengthRatio: [AITask: ClosedRange<Double>],
        lengthRatioMinimumSourceCharacters: Int,
        cleanupOverlap: OverlapThresholds,
        cleanupOverlapHandsFree: OverlapThresholds,
        rewriteOverlap: OverlapThresholds?,
        leakageWindowCharacters: Int,
        languageCheckMinimumCharacters: Int,
        chunkDuplicateMinimumCharacters: Int,
        crossChunkCorrectionCues: [String],
        numberRetractionWindowCharacters: Int = 12
    ) {
        self.lengthRatio = lengthRatio
        self.lengthRatioMinimumSourceCharacters = lengthRatioMinimumSourceCharacters
        self.cleanupOverlap = cleanupOverlap
        self.cleanupOverlapHandsFree = cleanupOverlapHandsFree
        self.rewriteOverlap = rewriteOverlap
        self.leakageWindowCharacters = leakageWindowCharacters
        self.languageCheckMinimumCharacters = languageCheckMinimumCharacters
        self.chunkDuplicateMinimumCharacters = chunkDuplicateMinimumCharacters
        self.crossChunkCorrectionCues = crossChunkCorrectionCues
        self.numberRetractionWindowCharacters = numberRetractionWindowCharacters
    }

    /// PROVISIONAL defaults (uncalibrated starting points).
    public static let provisionalDefault = ValidationThresholds(
        lengthRatio: [
            .cleanup: 0.35...1.6,
            .proofreadRewrite: 0.4...2.0,
            .translate: 0.2...4.0,
            .transform: 0.1...3.0,
            .summarize: 0.01...1.0,
            .extract: 0.005...1.2,
        ],
        lengthRatioMinimumSourceCharacters: 20,
        cleanupOverlap: OverlapThresholds(
            minimumRetention: 0.5, maximumNewContentRatio: 0.3, minimumSourceContentWords: 1,
            shortSourceContentWords: 3, maximumSentenceNewContentRatio: 0.5
        ),
        cleanupOverlapHandsFree: OverlapThresholds(
            minimumRetention: 0.65, maximumNewContentRatio: 0.2, minimumSourceContentWords: 1,
            shortSourceContentWords: 3, maximumSentenceNewContentRatio: 0.5
        ),
        rewriteOverlap: OverlapThresholds(
            minimumRetention: 0.3, maximumNewContentRatio: 0.7, minimumSourceContentWords: 3
        ),
        leakageWindowCharacters: 20,
        languageCheckMinimumCharacters: 8,
        chunkDuplicateMinimumCharacters: 8,
        // Retraction words only: common local cues (いや, ではなく, actually…) also occur inside ordinary words and
        // sentences ("使いやすい"); a later chunk is checked for those only in its first sentence (`SelfCorrection`).
        crossChunkCorrectionCues: [
            "取り消し", "取消し", "取り消す", "訂正", "前言撤回", "今のなし", "言い直し", "撤回", "なしにして", "取りやめ",
            "scratch that", "i meant", "earlier i said", "take that back", "never mind",
        ]
    )
}
