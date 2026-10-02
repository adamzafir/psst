import Foundation

/// Only normalize whitespace and terminal sentence punctuation. Internal punctuation,
/// decimal points, operators, signs, and changed words must invalidate speculation.
struct QuestionKey: Equatable {
    let value: String
    init(_ question: String) {
        value = question.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
