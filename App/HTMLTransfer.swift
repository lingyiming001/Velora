import AppKit
import Foundation

enum HTMLTransfer {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func replacing(_ pattern: String, in input: String, transform: (String) throws -> String) rethrows -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return input }
        var result = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            if let range = Range(match.range, in: input), let outputRange = Range(match.range, in: result) {
                result.replaceSubrange(outputRange, with: try transform(String(input[range])))
            }
        }
        return result
    }
    static func plain(_ html: String) -> String {
        let text = html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        var result = text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
        result = replacing("&#(?:x[0-9a-f]+|[0-9]+);", in: result) { entity in
            let value = String(entity.dropFirst(2).dropLast())
            let number = value.lowercased().hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
            return number.flatMap(UnicodeScalar.init).map(String.init) ?? entity
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
    static func safeLink(_ value: String) -> String? {
        guard let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url.absoluteString
    }
    static func importDocument(_ input: String, title: String, directory: URL? = nil) throws -> TransferDocument {
        let documentTitle = DocumentTransfer.firstMatch("(?i)<title[^>]*>(.*?)</title>", input).map { plain($0[1]) } ?? title
        var tokens: [String: TransferBlock] = [:]
        func token(_ block: TransferBlock) -> String {
            let id = "VELORABLOCK" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            tokens[id] = block; return "<p>" + id + "</p>"
        }
        var html = input.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        html = replacing("<(script|style|iframe|object|embed|svg|head)\\b[^>]*>.*?</\\1\\s*>", in: html) { _ in "" }
        html = try replacing("<img\\b[^>]*>", in: html) { tag in
            guard let match = DocumentTransfer.firstMatch("(?i)\\bsrc\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", tag),
                  let source = match.dropFirst().first(where: { !$0.isEmpty }) else { return "" }
            return token(TransferBlock(.image, try DocumentTransfer.importImage(plain(source), directory: directory)))
        }
        html = replacing("<pre\\b[^>]*>(.*?)</pre>", in: html) { fragment in
            let contents = DocumentTransfer.firstMatch("(?i)<pre[^>]*>(.*?)</pre>", fragment)?[1] ?? ""
            return token(TransferBlock(.code, plain(contents).trimmingCharacters(in: .newlines)))
        }
        html = replacing("<table\\b[^>]*>.*?</table>", in: html) { table in
            var rows: [[String]] = []
            _ = replacing("<tr\\b[^>]*>.*?</tr>", in: table) { row in
                var cells: [String] = []
                _ = replacing("<t[dh]\\b[^>]*>(.*?)</t[dh]>", in: row) { cell in
                    cells.insert(plain(cell).trimmingCharacters(in: .whitespacesAndNewlines), at: 0); return ""
                }
                if !cells.isEmpty { rows.insert(cells, at: 0) }; return ""
            }
            guard let count = rows.map(\.count).max(), count > 0 else { return "" }
            rows = rows.map { $0 + Array(repeating: "", count: count - $0.count) }
            return token(TransferBlock(.table, String(decoding: (try? JSONEncoder().encode(rows)) ?? Data(), as: UTF8.self)))
        }
        html = replacing("<a\\b[^>]*>(.*?)</a>", in: html) { tag in
            let label = DocumentTransfer.firstMatch("(?i)<a[^>]*>(.*?)</a>", tag)?[1] ?? ""
            let link = DocumentTransfer.firstMatch("(?i)\\bhref\\s*=\\s*[\"']([^\"']*)[\"']", tag)?[1]
            return label + (link.flatMap { safeLink(plain($0)) }.map { " (" + escape($0) + ")" } ?? "")
        }
        // Keep formatting tags but remove every attribute and external resource reference.
        let allowed: Set<String> = ["html", "body", "p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "b", "strong", "i", "em", "u", "s", "ul", "ol", "li", "blockquote", "hr", "span", "code", "details", "summary"]
        html = replacing("<[^>]*>", in: html) { tag in
            guard let name = DocumentTransfer.firstMatch("^<\\s*/?\\s*([a-zA-Z0-9]+)", tag)?[1].lowercased(), allowed.contains(name) else { return "" }
            return "<" + (tag.hasPrefix("</") ? "/" : "") + name + ">"
        }
        let attributed = try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        var document = DocumentTransfer.fromAttributed(attributed, title: documentTitle)
        document.pages[0].blocks = document.pages[0].blocks.map { tokens[$0.text] ?? $0 }
        return document
    }

    static func page(_ page: TransferPage) -> String {
        let body = page.blocks.map { block -> String in
            let text = RichInlineContent.html(block.text, runs: block.formatting)
            switch block.kind {
            case .heading: return "<h1>\(text)</h1>"
            case .heading2: return "<h2>\(text)</h2>"
            case .heading3: return "<h3>\(text)</h3>"
            case .bullet: return "<ul><li>\(text)</li></ul>"
            case .numbered: return "<ol><li>\(text)</li></ol>"
            case .todo: return "<p>\(block.checked ? "☑" : "☐") \(text)</p>"
            case .quote: return "<blockquote>\(text)</blockquote>"
            case .callout: return "<aside>\(text)</aside>"
            case .toggle: return "<details\(block.collapsed ? "" : " open")><summary>折叠内容</summary><p>\(text)</p></details>"
            case .divider: return "<hr />"
            case .code: return "<pre><code>\(escape(block.text))</code></pre>"
            case .table:
                guard let data = block.text.data(using: .utf8), let rows = try? JSONDecoder().decode([[String]].self, from: data) else { return "<p>\(text)</p>" }
                return "<table>" + rows.enumerated().map { index, cells in "<tr>" + cells.map { let tag = index == 0 ? "th" : "td"; return "<\(tag)>\(escape($0))</\(tag)>" }.joined() + "</tr>" }.joined() + "</table>"
            case .image:
                guard let source = try? ImageSource.validated(block.text) else { return "<p>[图片无法导出]</p>" }
                return "<p><img src=\"\(escape(source))\" alt=\"图片\" /></p>"
            case .audio, .video, .file, .bookmark:
                guard let link = safeLink(block.text) else { return "<p>\(text)</p>" }
                return "<p><a href=\"\(escape(link))\">\(escape(block.kind.label))</a></p>"
            case .tableOfContents: return "<p>页面目录</p>"
            default: return "<p>\(text)</p>"
            }
        }.joined(separator: "\n")
        return "<article><h1>\(escape(page.title))</h1>\n\(body)</article>"
    }
    static func document(_ document: TransferDocument) throws -> String {
        let body = try document.orderedPages().map { "<nav>" + escape(document.path(for: $0)) + "</nav>" + page($0) }.joined(separator: "\n<hr />\n")
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>\(escape(document.name))</title>
        <style>body{font:16px/1.7 -apple-system,BlinkMacSystemFont,sans-serif;color:#222;max-width:850px;margin:48px auto;padding:0 28px}img{max-width:100%;height:auto}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f5f5f7;padding:16px;border-radius:8px}blockquote,aside{border-left:3px solid #ccc;margin-left:0;padding-left:18px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ddd;padding:8px;text-align:left}nav{font-size:13px;color:#777}article{break-after:page}a{overflow-wrap:anywhere}</style></head><body>\(body)</body></html>
        """
    }
}
