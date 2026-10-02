import AppKit

@main
struct AnswerFormattingTests {
    static func main() {
        let cases: [(String, String)] = [
            (#"\( E = mc^2 \)"#, " E = mc² "),
            (#"\(3 \times 10^8\) m/s"#, "3 × 10⁸ m/s"),
            (#"\[F = \frac{mv^2}{r}\]"#, "F = (mv²)/(r)"),
            (#"\sqrt{x^2 + y^2}"#, "√(x² + y²)"),
            (#"\(x_{12} + 10^{-3}\)"#, "x₁₂ + 10⁻³"),
            ("Costs $5 and $10", "Costs $5 and $10"),
            ("_important_ and snake_case", "_important_ and snake_case"),
            (#"\unknown{x}"#, #"\unknown{x}"#)
        ]
        for (input, expected) in cases {
            precondition(AnswerFormatting.plainMath(input) == expected, "Failed: \(input): \(AnswerFormatting.plainMath(input))")
        }
        let rendered = AnswerFormatting.render("**Energy**\n- \\(E = mc^2\\)\n_Important_ and `code`")
        precondition(rendered.string == "Energy\n• E = mc²\nImportant and code")
        let font = rendered.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        precondition(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        for end in "**Energy** \\(E = mc^2\\)".indices {
            _ = AnswerFormatting.render(String("**Energy** \\(E = mc^2\\)"[..<end]))
        }
        print("PASS: math, Markdown styling, currency, identifiers, and partial streaming formatting")
    }
}
