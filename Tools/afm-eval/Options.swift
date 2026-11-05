import Foundation
import ItJustTalksAI

enum EvalCategory: String, CaseIterable, Sendable, Codable {
    case cleanup, routing, generation, optimization, long
}

enum GenerationPath: String, Sendable, Codable { case oracle, e2e }

enum CommandMethod: String, Sendable, Codable {
    case separated, unified
}

/// Self-correction handling for cleanup (P1 round 2). `spans`: stage A lists {retracted, replacement}
/// pairs (product design); `sentence`: stage A returns the corrected transcript, from which the same
/// verifier derives the spans (comparison only); `off`: single-stage cleanup.
enum CorrectionMethod: String, Sendable, Codable {
    case spans, sentence, off
}

/// `auto` follows the library's per-task decision (`AITask.guardrails`, G1); the others force one mode.
enum GuardrailChoice: String, Sendable, Codable {
    case auto, `default`, permissive

    func mode(for task: AITask) -> GuardrailsMode {
        switch self {
        case .auto: return task.guardrails
        case .default: return .default
        case .permissive: return .permissiveContentTransformations
        }
    }
}

/// `auto` mirrors the app (G1: prompt language follows the STT language): a case's `lang` stands in for the
/// STT setting — `en` → English prompts, `ja` and `mixed` → Japanese prompts.
enum PromptLanguageChoice: String, Sendable, Codable {
    case auto, ja, en

    func resolve(caseLang: String) -> PromptLanguage {
        switch self {
        case .auto: return PromptLanguage(sttLanguage: caseLang == "en" ? "en" : "ja")
        case .ja: return .ja
        case .en: return .en
        }
    }
}

struct RunOptions: Sendable {
    var contextLimit: Int?
    var chunkContext: ChunkContextChoice = .none
    var casesDirectory: URL
    var outDirectory: URL
    var categories: [EvalCategory] = EvalCategory.allCases
    var promptLanguage: PromptLanguageChoice = .auto
    var guardrails: GuardrailChoice = .auto
    var commandMethod: CommandMethod = .separated
    var generationPath: GenerationPath = .oracle
    var correctionMethod: CorrectionMethod = .spans
    /// `--category all`: categories without a case file are skipped (Evaluation/holdout has only some).
    var allCategories = true
    var dictionaryMemo = true
    var repeatCount = 1
    var limit: Int?
    var fake = false
}

enum ChunkContextChoice: String, Sendable {
    case none
    case previousSentence = "previous-sentence"

    var referenceContext: ChunkReferenceContext { self == .none ? .none : .previousSentence }
}

struct CancelTestOptions: Sendable {
    var count = 5
    var cancelAfterMs = 1500
    var outDirectory: URL
    var promptLanguage: PromptLanguage = .ja
    var fake = false
}

enum Command: Sendable {
    case run(RunOptions)
    case rescore(RunOptions, URL)
    case cancelTest(CancelTestOptions)
}

enum OptionError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

enum OptionParser {
    static let usage = """
    usage:
      afm-eval --cases <Evaluation/cases dir> --out <dir> [--category cleanup|routing|generation|optimization|long|all]
               [--prompt-lang auto|ja|en] [--guardrails auto|default|permissive] [--command-method separated|unified]
               [--correction-method spans|sentence|off] [--generation-path oracle|e2e]
               [--context-limit N (>=1024)] [--chunk-context none|previous-sentence]
               [--dictionary-memo on|off] [--repeat N] [--limit N] [--fake]
      afm-eval rescore --records-dir <old run dir> --cases <cases dir> --out <new dir> [--category all|category] [--repeat N]
      afm-eval cancel-test --count N --cancel-after-ms M --out <dir> [--prompt-lang ja|en] [--fake]
    """

    static func parse(_ arguments: [String]) throws -> Command {
        var args = arguments
        if args.first == "rescore" {
            args.removeFirst()
            guard let index = args.firstIndex(of: "--records-dir"), index + 1 < args.count else {
                throw OptionError.message("rescore requires --records-dir")
            }
            let input = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
            args.removeSubrange(index...index + 1)
            return .rescore(try parseRun(args), input)
        }
        if args.first == "cancel-test" {
            args.removeFirst()
            return .cancelTest(try parseCancelTest(args))
        }
        return .run(try parseRun(args))
    }

    private static func parseRun(_ args: [String]) throws -> RunOptions {
        var cases: String?
        var out: String?
        var options = RunOptions(casesDirectory: URL(fileURLWithPath: "/"), outDirectory: URL(fileURLWithPath: "/"))
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw OptionError.message("missing value for \(flag)") }
            return args[index]
        }
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--cases": cases = try value(flag)
            case "--out": out = try value(flag)
            case "--category":
                let text = try value(flag)
                if text == "all" {
                    options.categories = EvalCategory.allCases
                    options.allCategories = true
                } else if let category = EvalCategory(rawValue: text) {
                    options.categories = [category]
                    options.allCategories = false
                } else {
                    throw OptionError.message("invalid --category \(text)")
                }
            case "--prompt-lang":
                guard let language = PromptLanguageChoice(rawValue: try value(flag)) else { throw OptionError.message("invalid --prompt-lang") }
                options.promptLanguage = language
            case "--guardrails":
                guard let choice = GuardrailChoice(rawValue: try value(flag)) else { throw OptionError.message("invalid --guardrails") }
                options.guardrails = choice
            case "--command-method":
                guard let method = CommandMethod(rawValue: try value(flag)) else { throw OptionError.message("invalid --command-method") }
                options.commandMethod = method
            case "--generation-path":
                guard let path = GenerationPath(rawValue: try value(flag)) else { throw OptionError.message("invalid --generation-path") }
                options.generationPath = path
            case "--correction-method":
                guard let method = CorrectionMethod(rawValue: try value(flag)) else { throw OptionError.message("invalid --correction-method") }
                options.correctionMethod = method
            case "--dictionary-memo":
                switch try value(flag) {
                case "on": options.dictionaryMemo = true
                case "off": options.dictionaryMemo = false
                default: throw OptionError.message("invalid --dictionary-memo")
                }
            case "--repeat":
                guard let number = Int(try value(flag)), number >= 1 else { throw OptionError.message("invalid --repeat") }
                options.repeatCount = number
            case "--limit":
                guard let number = Int(try value(flag)), number >= 1 else { throw OptionError.message("invalid --limit") }
                options.limit = number
            case "--fake": options.fake = true
            case "--context-limit":
                guard let number = Int(try value(flag)), number >= 1024 else { throw OptionError.message("invalid --context-limit") }
                options.contextLimit = number
            case "--chunk-context":
                guard let choice = ChunkContextChoice(rawValue: try value(flag)) else { throw OptionError.message("invalid --chunk-context") }
                options.chunkContext = choice
            case "--help", "-h": throw OptionError.message(usage)
            default: throw OptionError.message("unknown argument \(flag)")
            }
            index += 1
        }
        guard let cases else { throw OptionError.message("missing --cases") }
        guard let out else { throw OptionError.message("missing --out") }
        options.casesDirectory = URL(fileURLWithPath: cases).standardizedFileURL
        options.outDirectory = URL(fileURLWithPath: out).standardizedFileURL
        return options
    }

    private static func parseCancelTest(_ args: [String]) throws -> CancelTestOptions {
        var options = CancelTestOptions(outDirectory: URL(fileURLWithPath: "/"))
        var out: String?
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw OptionError.message("missing value for \(flag)") }
            return args[index]
        }
        while index < args.count {
            let flag = args[index]
            switch flag {
            case "--count":
                guard let number = Int(try value(flag)), number >= 1 else { throw OptionError.message("invalid --count") }
                options.count = number
            case "--cancel-after-ms":
                guard let number = Int(try value(flag)), number >= 0 else { throw OptionError.message("invalid --cancel-after-ms") }
                options.cancelAfterMs = number
            case "--out": out = try value(flag)
            case "--prompt-lang":
                guard let language = PromptLanguage(rawValue: try value(flag)) else { throw OptionError.message("invalid --prompt-lang") }
                options.promptLanguage = language
            case "--fake": options.fake = true
            default: throw OptionError.message("unknown argument \(flag)")
            }
            index += 1
        }
        guard let out else { throw OptionError.message("missing --out") }
        options.outDirectory = URL(fileURLWithPath: out).standardizedFileURL
        return options
    }
}
