import Foundation

@main
struct QuestionKeyTests {
    static func main() {
        precondition(QuestionKey("What is gravity?") == QuestionKey("What is gravity."))
        precondition(QuestionKey("  What  is\ngravity?  ") == QuestionKey("What is gravity"))
        for (partial, corrected) in [
            ("What is 1.2 times 3", "What is 12 times 3"),
            ("What is -5 squared", "What is 5 squared"),
            ("What is 4/2", "What is 4*2"),
            ("What is mitosis", "What is meiosis"),
            ("What is Newton's first law", "What is Newton's second law"),
            ("Is this safe", "Is this not safe")
        ] {
            precondition(QuestionKey(partial) != QuestionKey(corrected), "A corrected question must discard the candidate answer")
        }
        print("PASS: 8 speculative-question matching regressions")
    }
}
