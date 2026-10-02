import AppKit

/// Lightweight, offline presentation for the model's Markdown and common LaTeX.
/// Unknown math commands remain readable rather than being silently discarded.
enum AnswerFormatting {
    static func plainMath(_ source: String) -> String {
        var text = source
        for delimiter in [#"\("#, #"\)"#, #"\["#, #"\]"#, "$$"] {
            text = text.replacingOccurrences(of: delimiter, with: "")
        }
        func replace(_ pattern: String, _ transform: (NSTextCheckingResult, NSString) -> String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let original = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
                text = (text as NSString).replacingCharacters(in: match.range, with: transform(match, original))
            }
        }
        replace(#"\$([^\s$](?:[^$\n]*[^\s$])?)\$"#) { m, s in s.substring(with: m.range(at: 1)) }
        for _ in 0..<8 {
            let before = text
            replace(#"\\(?:dfrac|tfrac|frac)\{([^{}]*)\}\{([^{}]*)\}"#) { m, s in
                let a = s.substring(with: m.range(at: 1)), b = s.substring(with: m.range(at: 2))
                return "(\(a))/(\(b))"
            }
            replace(#"\\sqrt\{([^{}]*)\}"#) { m, s in "√(" + s.substring(with: m.range(at: 1)) + ")" }
            replace(#"\\(?:text|mathrm|mathbf|operatorname)\{([^{}]*)\}"#) { m, s in s.substring(with: m.range(at: 1)) }
            if text == before { break }
        }
        let symbols = ["times": "×", "cdot": "·", "div": "÷", "pm": "±", "approx": "≈", "neq": "≠", "leq": "≤", "geq": "≥", "infty": "∞", "pi": "π", "theta": "θ", "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "Delta": "Δ", "lambda": "λ", "mu": "μ", "sigma": "σ", "omega": "ω", "Omega": "Ω", "sum": "∑", "int": "∫", "rightarrow": "→", "left": "", "right": ""]
        replace(#"\\([A-Za-z]+)\b"#) { m, s in
            let command = s.substring(with: m.range(at: 1))
            return symbols[command] ?? s.substring(with: m.range)
        }
        for (marker, normal, elevated) in [("^", "0123456789+-=()n", "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿ"), ("_", "0123456789+-=()", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎")] {
            let mapping = Dictionary(uniqueKeysWithValues: zip(normal, elevated))
            replace((marker == "_" ? #"(?<=[A-Za-z0-9)])(?<![A-Za-z]{2})"# : "") + NSRegularExpression.escapedPattern(for: marker) + #"(?:\{([^{}]+)\}|([0-9]+|[A-Za-z]))"#) { m, s in
                let content = s.substring(with: m.range(at: m.range(at: 1).location == NSNotFound ? 2 : 1))
                return content.allSatisfy { mapping[$0] != nil } ? String(content.map { mapping[$0]! }) : marker + "(" + content + ")"
            }
        }
        for command in [#"\,"#, #"\;"#, #"\!"#, #"\ "#] { text = text.replacingOccurrences(of: command, with: " ") }
        return text
    }

    static func render(_ source: String) -> NSAttributedString {
        let normalized = plainMath(source).split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var line = String(line)
            if let range = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) { line.replaceSubrange(range, with: "• ") }
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { line.removeSubrange(range); line = "**" + line + "**" }
            return line
        }.joined(separator: "\n")
        let parsed = (try? AttributedString(markdown: normalized, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(normalized)
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) : NSFont.systemFont(ofSize: 15, weight: intent.contains(.stronglyEmphasized) ? .bold : .medium)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]))
        }
        return result
    }
}
