import Foundation

enum RichInlineContent {
    struct Segment { let text: String; let style: InlineTextStyle }
    static func segments(_ text: String, runs: [TextStyleRun]) -> [Segment] {
        let ns = text as NSString
        let valid = runs.filter { $0.validRange(in: text) != nil }
        let points = Set([0, ns.length] + valid.flatMap { [$0.location, $0.location + $0.length] }).sorted()
        return zip(points, points.dropFirst()).compactMap { start, end in
            guard end > start else { return nil }
            let style = valid.last { $0.location <= start && $0.location + $0.length >= end }?.style ?? InlineTextStyle()
            return Segment(text: ns.substring(with: NSRange(location: start, length: end - start)), style: style)
        }
    }
    static func html(_ text: String, runs: [TextStyleRun]) -> String {
        segments(text, runs: runs).map { segment in
            var value = HTMLTransfer.escape(segment.text).replacingOccurrences(of: "\n", with: "<br />")
            let style = segment.style
            if style.bold == true { value = "<strong>" + value + "</strong>" }
            if style.italic == true { value = "<em>" + value + "</em>" }
            if style.underline { value = "<u>" + value + "</u>" }
            if style.strikethrough { value = "<s>" + value + "</s>" }
            var css: [String] = []
            if let color = style.color, color.count == 6, UInt32(color, radix: 16) != nil { css.append("color:#" + color) }
            if let color = style.highlight, color.count == 6, UInt32(color, radix: 16) != nil { css.append("background-color:#" + color) }
            if let size = style.fontSize { css.append("font-size:\(min(96, max(8, size)))pt") }
            if let family = style.fontFamily { css.append("font-family:'" + family.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: ";", with: "") + "'") }
            if !css.isEmpty { value = "<span style=\"" + HTMLTransfer.escape(css.joined(separator: ";")) + "\">" + value + "</span>" }
            return value
        }.joined()
    }
    static func markdown(_ text: String, runs: [TextStyleRun]) -> String {
        segments(text, runs: runs).map { segment in
            var value = segment.text
            if segment.style.bold == true { value = "**" + value + "**" }
            if segment.style.italic == true { value = "*" + value + "*" }
            if segment.style.strikethrough { value = "~~" + value + "~~" }
            if segment.style.underline { value = "<u>" + value + "</u>" }
            return value
        }.joined()
    }
    static func parseMarkdown(_ text: String) -> (text: String, runs: [TextStyleRun]) {
        guard let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return (text, []) }
        var runs: [TextStyleRun] = []; var offset = 0
        for run in attributed.runs {
            let value = String(attributed[run.range].characters)
            var style = InlineTextStyle()
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { style.bold = true }
                if intent.contains(.emphasized) { style.italic = true }
                if intent.contains(.strikethrough) { style.strikethrough = true }
                if intent.contains(.code) { style.fontFamily = "Menlo" }
            }
            if !style.isEmpty { runs.append(TextStyleRun(location: offset, length: value.utf16.count, style: style)) }
            offset += value.utf16.count
        }
        return (String(attributed.characters), runs)
    }
}
