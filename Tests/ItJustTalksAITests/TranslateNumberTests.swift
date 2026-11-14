import Testing
@testable import ItJustTalksAI

// Synthetic fixtures only. Number reasons are checked separately from language/length heuristics.
@Suite("Translation number validation")
struct TranslateNumberTests {
    private func input(_ source: String, _ output: String, task: AITask = .translate) -> ValidationInput {
        ValidationInput(task: task, source: source, output: output, isTruncated: false,
                        protectedInstructions: ["Synthetic validation instruction"], handsFree: false)
    }

    private func reasons(_ source: String, _ output: String, task: AITask = .translate) -> [ValidationReason] {
        ResultValidator().joinedNumberReasons(input(source, output, task: task))
    }

    private func dropped(_ source: String, _ output: String) -> Int {
        let value = input(source, output)
        return ResultValidator().droppedNumberCount(input: value, output: output)
    }

    @Test func impersonalOneBeforeAModal() {
        for output in ["After a long day, one may feel tired.", "One should rest.", "One can never be sure.",
                       "Work makes one feel tired.", "One might say so."] {
            #expect(reasons("疲れたら休むべきです。", output).isEmpty)
        }
    }

    @Test func countingOneIsNeverHidden() {
        // A licensed 1 is matched first; a pronoun is excused only as a surplus 1.
        #expect(reasons("1つだけ残っています。", "Only one is left.").isEmpty)
        #expect(reasons("残り1つです。", "There is one left.").isEmpty)
        #expect(!reasons("3つ出荷しました。届きました。", "Three shipped. One was lost.").isEmpty)
        #expect(!reasons("2週間かかります。", "It takes from one to two weeks.").isEmpty)
        #expect(!reasons("2週間かかります。", "It takes one to two weeks.").isEmpty)
        #expect(!reasons("2人で行きます。", "Only one can go, and two will stay.").isEmpty)
        // A real date after "one may" is not touched by the modal rule.
        #expect(NumberExtractor.translationPronounOnes("We start on May 1.").modalMay.isEmpty)
    }

    @Test func countedOneAllowsSingularArticles() {
        for source in ["りんご1個", "りんご一個"] {
            for output in ["an apple", "a single apple", "a whole apple", "one apple"] {
                #expect(reasons(source, output).isEmpty)
            }
        }
        for counter in ["袋", "個", "つ", "人", "回", "本", "枚", "杯", "台", "匹", "冊", "件", "日", "週", "年", "ヶ月", "か月"] {
            #expect(dropped("1" + counter, "a unit") == 0)
        }
    }

    @Test func eachArticleCoversOneCountedQuantity() {
        #expect(dropped("りんご1個とパン1袋", "an apple and bread") == 1)
        #expect(dropped("りんご1個とパン1袋", "an apple and a bag of bread") == 0)
        #expect(dropped("りんご1個と3人", "an apple for the people") == 1)
    }

    @Test func quantifierPhrasesAreNotASingleItem() {
        for output in ["Please give me a few apples.", "a couple of apples", "a lot of apples", "half an apple",
                       "quite a few apples", "a dozen apples"] {
            #expect(dropped("りんごを1個ください", output) > 0)
        }
    }

    @Test func datesAndOrdinalsAreNotCounts() {
        for (source, output) in [("11月1日に会議があります", "There is a meeting in November."),
                                 ("1つ目の問題です", "This is a problem."), ("第1回の会議", "a meeting"),
                                 ("1年生です", "I am a student."), ("1日おきに通います", "I go every other day, a habit.")] {
            #expect(dropped(source, output) > 0)
        }
    }

    @Test func articlesNeverLicenseOtherValuesOrBareOne() {
        for source in ["りんご2個", "3人", "10個", "11個", "21個", "-1個", "1.1個", "1"] {
            #expect(dropped(source, "an apple") > 0)
        }
        #expect(ResultValidator().numberCheck(input: input("3人", "one person"), output: "one person", crossLanguage: false).newCount > 0)
    }

    @Test func changedAndNewNumbersStillFail() {
        for output in ["an apple and 9 bags", "one apple and two bags"] {
            #expect(ResultValidator().numberCheck(input: input("りんご1個", output), output: output, crossLanguage: false).newCount > 0)
        }
        #expect(reasons("10", "ten").isEmpty)
        #expect(ResultValidator().numberCheck(input: input("10", "eleven"), output: "eleven", crossLanguage: false).newCount > 0)
    }

    @Test func otherTasksUnchanged() {
        let validator = ResultValidator()
        let value = input("りんご1個", "an apple", task: .cleanup)
        #expect(validator.droppedNumberCount(input: value, output: value.output) == 1)
        let pronoun = input("休んでください", "One should rest.", task: .proofreadRewrite)
        #expect(validator.numberCheck(input: pronoun, output: pronoun.output, crossLanguage: false).newCount == 1)
    }
}
