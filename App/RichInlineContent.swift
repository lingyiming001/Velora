import Foundation

enum RichInlineContent {
    /// Literal UTF-16 replacement. New text inherits the first matched
    /// character's inline style; text outside the matches keeps its own style.
    static func replacing(_ text: String, runs: [TextStyleRun], ranges: [NSRange], with replacement: String) -> (text: String, runs: [TextStyleRun]) {
        var text = text, runs = runs
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            let source = text as NSString
            guard range.location >= 0, range.length > 0, range.location <= source.length,
                  range.length <= source.length - range.location else { continue }
            let insertedLength = replacement.utf16.count
            let delta = insertedLength - range.length
            let inherited = runs.last { $0.location <= range.location && $0.location + $0.length > range.location }?.style
            var adjusted: [TextStyleRun] = []
            for run in runs {
                guard let valid = run.validRange(in: text) else { continue }
                let leftEnd = min(NSMaxRange(valid), range.location)
                if valid.location < leftEnd {
                    adjusted.append(TextStyleRun(location: valid.location, length: leftEnd - valid.location, style: run.style))
                }
                let rightStart = max(valid.location, NSMaxRange(range))
                if rightStart < NSMaxRange(valid) {
                    adjusted.append(TextStyleRun(location: rightStart + delta, length: NSMaxRange(valid) - rightStart, style: run.style))
                }
            }
            if let inherited, !inherited.isEmpty, insertedLength > 0 {
                adjusted.append(TextStyleRun(location: range.location, length: insertedLength, style: inherited))
            }
            text = source.replacingCharacters(in: range, with: replacement)
            runs = adjusted.sorted { $0.location < $1.location }
        }
        return (text, runs)
    }

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
            if style.code { value = "<code>" + value + "</code>" }
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
            if let link = style.link.flatMap(HTMLTransfer.safeLink) { value = "<a href=\"" + HTMLTransfer.escape(link) + "\">" + value + "</a>" }
            return value
        }.joined()
    }
    static func markdown(_ text: String, runs: [TextStyleRun]) -> String {
        segments(text, runs: runs).map { segment in
            var value = segment.text
            if segment.style.code {
                let fence = String(repeating: "`", count: max(1, (value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1))
                value = fence + " " + value + " " + fence
            }
            if segment.style.bold == true { value = "**" + value + "**" }
            if segment.style.italic == true { value = "*" + value + "*" }
            if segment.style.strikethrough { value = "~~" + value + "~~" }
            if segment.style.underline { value = "<u>" + value + "</u>" }
            if let link = segment.style.link.flatMap(HTMLTransfer.safeLink) { value = "[" + value + "](<" + link.replacingOccurrences(of: ">", with: "%3E") + ">)" }
            return value
        }.joined()
    }
    static func parseMarkdown(_ text: String) -> (text: String, runs: [TextStyleRun]) {
        guard let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return (text, []) }
        var runs: [TextStyleRun] = []; var offset = 0
        for run in attributed.runs {
            let value = String(attributed[run.range].characters)
            var style = InlineTextStyle()
            style.link = run.link?.absoluteString
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { style.bold = true }
                if intent.contains(.emphasized) { style.italic = true }
                if intent.contains(.strikethrough) { style.strikethrough = true }
                if intent.contains(.code) { style.fontFamily = "Menlo"; style.code = true }
            }
            if !style.isEmpty { runs.append(TextStyleRun(location: offset, length: value.utf16.count, style: style)) }
            offset += value.utf16.count
        }
        return (String(attributed.characters), runs)
    }
}

/// Native table cells edit visible text. Old tables may still contain the
/// full-cell code fences generated by HTML/Markdown clipboard conversion.
enum TableCellContent {
    static func visible(_ source: String, layout: TableLayout) -> String {
        guard !layout.cellsArePlain, source.first == "`", source.last == "`" else { return source }
        let parsed = RichInlineContent.parseMarkdown(source)
        guard !parsed.text.isEmpty, parsed.text != source,
              RichInlineContent.segments(parsed.text, runs: parsed.runs).allSatisfy({ $0.style.code }) else { return source }
        return parsed.text
    }
    static func markdown(_ source: String, layout: TableLayout) -> String {
        let text = visible(source, layout: layout)
        return text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "~", with: "\\~")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
