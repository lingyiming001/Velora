import AppKit
import Foundation

@MainActor
enum ClipboardDocument {
    static let textSelectionType = NSPasteboard.PasteboardType("com.velora.text-selection")
    static let blocksType = NSPasteboard.PasteboardType("com.velora.blocks")

    static func blocks(from pasteboard: NSPasteboard) -> [TransferBlock]? {
        guard let data = pasteboard.data(forType: blocksType),
              let blocks = try? JSONDecoder().decode([TransferBlock].self, from: data), !blocks.isEmpty else { return nil }
        return blocks
    }

    @discardableResult
    static func copyBlocks(_ blocks: [TransferBlock], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !blocks.isEmpty, let data = try? JSONEncoder().encode(blocks) else { return false }
        let page = TransferPage(title: "", blocks: blocks)
        // Other apps receive readable source; Velora receives exact block semantics.
        let text = blocks.count == 1 && blocks[0].kind == .code ? blocks[0].text
            : (try? DocumentExporter.markdown(page, assetDirectory: nil)) ?? blocks.map(\.text).joined(separator: "\n\n")
        pasteboard.clearContents()
        pasteboard.setData(data, forType: blocksType)
        pasteboard.setString(HTMLTransfer.page(page), forType: .html)
        return pasteboard.setString(text, forType: .string)
    }

    static func inserting(_ blocks: [TransferBlock], into original: String, formatting: [TextStyleRun], selection: NSRange) -> [TransferBlock] {
        let ns = original as NSString
        let start = min(max(0, selection.location), ns.length)
        let end = start + min(max(0, selection.length), ns.length - start)
        func paragraph(_ range: NSRange) -> [TransferBlock] {
            guard range.length > 0 else { return [] }
            let runs = formatting.compactMap { run -> TextStyleRun? in
                guard let valid = run.validRange(in: original) else { return nil }
                let overlap = NSIntersectionRange(valid, range)
                guard overlap.length > 0 else { return nil }
                return TextStyleRun(location: overlap.location - range.location, length: overlap.length, style: run.style)
            }
            return [TransferBlock(.paragraph, ns.substring(with: range), formatting: runs)]
        }
        return paragraph(NSRange(location: 0, length: start)) + blocks
            + paragraph(NSRange(location: end, length: ns.length - end))
    }

    static func isStructured(_ plain: String?, html: String?) -> Bool {
        if let plain, mermaidMarkdown(plain) != nil { return true }
        if let text = plain, DocumentTransfer.firstMatch(#"(?m)(^\s{0,3}(#{1,6}\s|```|~~~|[-*+]\s|\d+[.)]\s|>\s|\$\$|\\\[)|\*\*[^*]+\*\*|`[^`\n]+`|\[[^\]]+\]\(https?://|\\\(.+?\\\)|\$[^\n$]+\$|^\|.+\|)"#, text) != nil { return true }
        if let html, DocumentTransfer.firstMatch(#"(?i)data-mermaid-source|language-mermaid|<(?:h[1-6]|table|pre|ul|ol|blockquote|strong|b|em|math)\b|class=["'][^"']*katex"#, html) != nil { return true }
        return false
    }
    static func markdown(plain: String?, html: String?) async throws -> String {
        if let plain, let diagram = mermaidMarkdown(plain) { return diagram }
        // Prefer HTML when it carries a Mermaid language marker absent from plain text.
        if let html, DocumentTransfer.firstMatch(#"(?i)(language-mermaid|data-language=["']mermaid|class=["']mermaid|data-mermaid-source)"#, html) != nil,
           plain.flatMap({ DocumentTransfer.firstMatch(#"(?im)^\s*(`{3,}|~{3,})mermaid\s*$"#, $0) }) == nil {
            return try await DocumentRenderSession.markdown(fromHTML: html)
        }
        // ChatGPT's visible clipboard text can contain presentation-only Unicode
        // around TeX backslashes. Its KaTeX annotation contains the exact source.
        if let html, DocumentTransfer.firstMatch(#"(?i)class=[\"'][^\"']*katex|annotation\b[^>]*application/x-tex"#, html) != nil {
            return try await DocumentRenderSession.markdown(fromHTML: html)
        }
        if let plain, isStructured(plain, html: nil) { return sanitizedMathPaste(plain) }
        if let html, !html.isEmpty { return try await DocumentRenderSession.markdown(fromHTML: html) }
        return sanitizedMathPaste(plain ?? "")
    }

    /// Returns one formula for a native equation block, preferring KaTeX's
    /// source annotation over the visually copied text.
    static func equationPaste(plain: String?, html: String?) -> String {
        if let html,
           let encoded = DocumentTransfer.firstMatch(#"(?is)<annotation\b[^>]*encoding\s*=\s*[\"']application/x-tex[\"'][^>]*>(.*?)</annotation>"#, html)?[1],
           let attributed = try? NSAttributedString(data: Data(encoded.utf8), options: [
               .documentType: NSAttributedString.DocumentType.html,
               .characterEncoding: String.Encoding.utf8.rawValue
           ], documentAttributes: nil) {
            return sanitizedMathPaste(attributed.string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return DocumentTransfer.equationSource(sanitizedMathPaste(plain ?? ""))
    }

    /// Removes clipboard presentation artifacts without changing valid TeX
    /// commands or the `\\\\` row separator used by matrices and aligned math.
    static func sanitizedMathPaste(_ input: String) -> String {
        var result = input
            .replacingOccurrences(of: #"(?<=\\)[\p{M}\p{Cf}\uFFFD]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\u200B-\u200F\u202A-\u202E\u2060\uFEFF\uFFFD]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?<!\\)\\\s*(?=(?:\$|\\\]|\\\)|$))"#,
            with: "",
            options: .regularExpression
        )
        return result
    }
    /// ChatGPT's code-copy button supplies raw diagram source without Markdown fences.
    static func mermaidMarkdown(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("mermaid\n") { text = String(text.dropFirst(8)) }
        let header = #"(?i)^(?:(?:flowchart|graph)\s+(?:TB|TD|BT|RL|LR)\b|(?:sequenceDiagram|classDiagram|stateDiagram(?:-v2)?|erDiagram|gantt|pie|journey|mindmap|timeline|gitGraph|quadrantChart|requirementDiagram|xychart(?:-beta)?|block(?:-beta)?|packet(?:-beta)?|architecture(?:-beta)?|kanban|C4Context|C4Container|C4Component|C4Dynamic|C4Deployment)(?:\s|$))"#
        guard text.contains("\n"), DocumentTransfer.firstMatch(header, text) != nil else { return nil }
        return fencedMermaid(text)
    }
    static func fencedMermaid(_ text: String) -> String {
        let regex = try! NSRegularExpression(pattern: "`+")
        let longest = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range.length).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "mermaid\n" + text + "\n" + fence
    }

    static func replacing(_ original: String, formatting: [TextStyleRun], selection: NSRange, with markdown: String) -> String {
        let ns = original as NSString
        let start = min(max(0, selection.location), ns.length)
        let end = min(ns.length, start + max(0, min(selection.length, ns.length - start)))
        func slice(_ range: NSRange) -> String {
            let text = ns.substring(with: range)
            let runs = formatting.compactMap { run -> TextStyleRun? in
                guard let valid = run.validRange(in: original) else { return nil }
                let overlap = NSIntersectionRange(valid, range)
                guard overlap.length > 0 else { return nil }
                return TextStyleRun(location: overlap.location - range.location, length: overlap.length, style: run.style)
            }
            return RichInlineContent.markdown(text, runs: runs)
        }
        let before = slice(NSRange(location: 0, length: start))
        let after = slice(NSRange(location: end, length: ns.length - end))
        if !markdown.contains("\n"), DocumentTransfer.firstMatch(#"^\s*(#{1,6}\s|[-*+]\s|[0-9]+[.)]\s|>\s|\$\$|\\\[|```|~~~)"#, markdown) == nil {
            return before + markdown + after
        }
        return [before, markdown, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
