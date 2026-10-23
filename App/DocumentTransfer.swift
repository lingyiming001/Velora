import Foundation
import AppKit
import PDFKit
import Vision
import UniformTypeIdentifiers

enum TransferFormat: String, CaseIterable, Identifiable {
    case markdown, text, html, json, pdf, word
    var id: String { rawValue }
    var label: String {
        switch self {
        case .markdown: "Markdown"
        case .text: L10n.text("纯文本 TXT")
        case .html: L10n.text("网页 HTML")
        case .json: "Velora JSON"
        case .pdf: "PDF"
        case .word: "Word DOCX"
        }
    }
    var ext: String {
        switch self { case .markdown: "md"; case .text: "txt"; case .word: "docx"; default: rawValue }
    }
    var type: UTType { UTType(filenameExtension: ext) ?? .data }
    static func detect(_ url: URL) -> Self? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": .markdown
        case "txt", "text": .text
        case "html", "htm": .html
        case "json": .json
        case "pdf": .pdf
        case "docx", "doc", "rtf": .word
        default: nil
        }
    }
}

struct TransferBlock: Codable, Equatable {
    var kind: BlockKind
    var text: String
    var checked = false
    var language = "Plain Text"
    var collapsed = false
    var formatting: [TextStyleRun] = []
    var tableLayout = TableLayout()
    init(_ kind: BlockKind, _ text: String = "", checked: Bool = false, language: String = "Plain Text", collapsed: Bool = false, formatting: [TextStyleRun] = [], tableLayout: TableLayout = TableLayout()) {
        self.formatting = formatting; self.tableLayout = tableLayout
        self.kind = kind; self.text = text; self.checked = checked; self.language = language; self.collapsed = collapsed
    }
    init(_ block: Block) { self.init(block.kind, block.text, checked: block.checked, language: block.language, collapsed: block.collapsed, formatting: block.formatting, tableLayout: block.tableLayout) }
    enum CodingKeys: String, CodingKey { case kind, text, checked, language, collapsed, formatting, tableLayout }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(BlockKind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        checked = try container.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "Plain Text"
        collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        formatting = try container.decodeIfPresent([TextStyleRun].self, forKey: .formatting) ?? []
        tableLayout = try container.decodeIfPresent(TableLayout.self, forKey: .tableLayout) ?? TableLayout()
    }
}

struct TransferPage: Codable, Identifiable {
    var id = UUID()
    var parentID: UUID?
    var title: String
    var archived = false
    var blocks: [TransferBlock]
}

struct TransferDocument: Codable {
    var version = 1
    var name: String
    var pages: [TransferPage]

    func orderedPages() throws -> [TransferPage] {
        guard version == 1 else { throw AppError.message("不支持此 JSON 版本") }
        guard !pages.isEmpty, pages.count <= 10000, pages.reduce(0, { $0 + $1.blocks.count }) <= 100000 else {
            throw AppError.message("文件为空，或超过 10,000 页面 / 100,000 块的导入限制")
        }
        let ids = Set(pages.map(\.id))
        guard ids.count == pages.count, pages.allSatisfy({ $0.parentID == nil || ids.contains($0.parentID!) }) else {
            throw AppError.message("JSON 包含重复页面 ID 或缺失的父页面")
        }
        let children = Dictionary(grouping: pages.filter { $0.parentID != nil }, by: { $0.parentID! })
        var ordered = pages.filter { $0.parentID == nil }; var index = 0
        while index < ordered.count {
            ordered.append(contentsOf: children[ordered[index].id] ?? []); index += 1
        }
        guard ordered.count == pages.count else { throw AppError.message("页面层级存在循环，未导入") }
        return ordered
    }
    func path(for page: TransferPage) -> String {
        let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        var names = [page.title]; var parent = page.parentID; var visited: Set<UUID> = [page.id]
        while let id = parent, visited.insert(id).inserted, let item = byID[id] {
            names.insert(item.title, at: 0); parent = item.parentID
        }
        return names.joined(separator: " / ")
    }
}

enum DocumentTransfer {
    static let maximumFileSize = 100 * 1024 * 1024
    static let acceptedTypes: [UTType] = ["md", "markdown", "txt", "html", "htm", "json", "pdf", "docx", "doc", "rtf"].map { UTType(filenameExtension: $0) ?? .data }

    @MainActor
    static func load(_ url: URL) async throws -> TransferDocument {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let format = TransferFormat.detect(url) else { throw AppError.message("不支持的文件格式：" + url.lastPathComponent) }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumFileSize else { throw AppError.message("单个导入文件不能超过 100 MB") }
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        guard data.count <= maximumFileSize else { throw AppError.message("文件超过 100 MB") }
        let name = url.deletingPathExtension().lastPathComponent
        if format == .json {
            let document = try JSONDecoder().decode(TransferDocument.self, from: data)
            _ = try document.orderedPages(); return document
        }
        if format == .pdf {
            return try await Task.detached(priority: .userInitiated) {
                try parsedPDF(data, title: name)
            }.value
        }
        if format == .word {
            if url.pathExtension.lowercased() == "docx" { return try DOCXTransfer.decode(data, title: name) }
            let type: NSAttributedString.DocumentType = url.pathExtension.lowercased() == "rtf" ? .rtf : url.pathExtension.lowercased() == "doc" ? .docFormat : .officeOpenXML
            let attributed = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil)
            return fromAttributed(attributed, title: name)
        }
        let text = try decodeText(data)
        switch format {
        case .markdown: return try markdownDocument(text, title: name, directory: url.deletingLastPathComponent())
        case .html:
            if let original = HTMLTransfer.embeddedDocument(text) { return original }
            let markdown = try await DocumentRenderSession.markdown(fromHTML: text)
            return try markdownDocument(markdown, title: name, directory: url.deletingLastPathComponent())
        default: return plainText(text, title: name)
        }
    }

    /// PDFKit and Vision stay on the worker task: large imports must not block
    /// sidebar clicks or editor input. Each PDF page contributes ordered blocks.
    static func parsedPDF(_ data: Data, title: String) throws -> TransferDocument {
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else {
            throw AppError.message("PDF 无法读取或需要密码")
        }
        guard pdf.pageCount <= 500 else { throw AppError.message("PDF 自动解析一次最多支持 500 页") }
        var blocks: [TransferBlock] = []
        var bytes = 0
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            let parsed: [TransferBlock] = try autoreleasepool {
                guard let page = pdf.page(at: index) else { throw AppError.message("PDF 页面无法读取") }
                if let text = page.attributedString,
                   !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return pdfTextBlocks(page, attributed: text)
                }
                // A scan has no text layer. Keep its visual content as an image
                // block and add independently editable OCR lines when available.
                let image = page.thumbnail(of: NSSize(width: 1600, height: 2200), for: .cropBox)
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw AppError.message("PDF 页面渲染失败")
                }
                var result = [TransferBlock(.image, try ImageSource.embedded(png))]
                if let cgImage = bitmap.cgImage {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = true
                    // OCR is best effort; an unreadable scan still retains its image.
                    if (try? VNImageRequestHandler(cgImage: cgImage).perform([request])) != nil {
                        let observations = (request.results ?? []).sorted {
                            $0.boundingBox.midY == $1.boundingBox.midY
                                ? $0.boundingBox.minX < $1.boundingBox.minX
                                : $0.boundingBox.midY > $1.boundingBox.midY
                        }
                        result += observations.compactMap { observation in
                            guard let text = observation.topCandidates(1).first?.string,
                                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                            return TransferBlock(.paragraph, text)
                        }
                    }
                }
                return result
            }
            bytes += parsed.reduce(0) { $0 + $1.text.utf8.count }
            guard bytes <= maximumFileSize else { throw AppError.message("PDF 解析后的内容超过 100 MB，请拆分文件后导入") }
            blocks.append(contentsOf: parsed)
        }
        return TransferDocument(name: title, pages: [TransferPage(title: title, blocks: blocks)])
    }

    private struct PDFTextLine {
        let attributed: NSAttributedString
        let bounds: CGRect
        let font: NSFont
        let monospaced: Bool
        let spaceWidth: CGFloat
        var text: String { attributed.string }
    }

    private static func isCodeFont(_ font: NSFont) -> Bool {
        let name = font.fontName.lowercased()
        return font.isFixedPitch || ["mono", "courier", "consolas", "menlo", "sourcecode"].contains { name.contains($0) }
    }

    /// Use line geometry and font traits before interpreting text. PDF does not
    /// carry Markdown semantics: running its code through Markdown destroys
    /// indentation, operators, literal backticks and comment/list-like prefixes.
    static func pdfTextBlocks(_ page: PDFPage, attributed: NSAttributedString) -> [TransferBlock] {
        let selections = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))?.selectionsByLine() ?? []
        let lines: [PDFTextLine] = selections.compactMap { selection in
            guard let raw = selection.attributedString else { return nil }
            let ns = raw.string as NSString
            var length = ns.length
            while length > 0, [10, 13, 0x2028, 0x2029].contains(ns.character(at: length - 1)) { length -= 1 }
            guard length > 0, !raw.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let value = raw.attributedSubstring(from: NSRange(location: 0, length: length))
            var codeCharacters = 0, fontWeights: [String: (NSFont, Int)] = [:]
            value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) { attribute, range, _ in
                guard let font = attribute as? NSFont else { return }
                if isCodeFont(font) { codeCharacters += range.length }
                let key = font.fontName + String(Double(font.pointSize))
                fontWeights[key] = (font, (fontWeights[key]?.1 ?? 0) + range.length)
            }
            let font = fontWeights.values.max { $0.1 < $1.1 }?.0 ?? .systemFont(ofSize: 12)
            // Selection geometry survives font substitution. Use its average
            // character advance to compare neighboring code lines below.
            let advance = selection.bounds(for: page).width / CGFloat(max(1, value.length))
            return PDFTextLine(attributed: value, bounds: selection.bounds(for: page), font: font,
                               monospaced: codeCharacters * 5 >= value.length * 4,
                               spaceWidth: max(1, advance))
        }
        guard !lines.isEmpty else {
            return fromAttributed(attributed, title: "", consumeLeadingTitle: false).pages[0].blocks
        }
        var sizes: [Int: Int] = [:]
        for line in lines where !line.monospaced { sizes[Int(line.font.pointSize.rounded()), default: 0] += line.attributed.length }
        let base = CGFloat(sizes.max { $0.value < $1.value }?.key ?? 12)
        let bodyLeft = lines.filter { !$0.monospaced && abs($0.font.pointSize - base) < 1.5 }.map { $0.bounds.minX }.min()
            ?? lines.map { $0.bounds.minX }.min() ?? 0
        var result: [TransferBlock] = [], index = 0
        func adjacent(_ previous: PDFTextLine, _ next: PDFTextLine, extraGap: CGFloat = 0) -> Bool {
            let gap = previous.bounds.minY - next.bounds.maxY
            return next.bounds.midY < previous.bounds.midY && gap >= -2 && gap <= max(previous.font.pointSize, next.font.pointSize) * 0.9 + extraGap
        }
        func codeLike(_ source: String) -> Bool {
            firstMatch(#"^\s*(?:(?:def|func|function|class|struct|enum|import|from|let|var|const|return|break|continue|pass|throw)\b|(?:if|for|while|else|try|catch)\b.*[:{]\s*$|[{}]\s*;?\s*$|//|#|[A-Za-z_][\w.]*\s*(?:=(?!=)|\([^)]*\)\s*;?\s*$))"#, source) != nil
        }
        func kind(_ line: PDFTextLine) -> BlockKind {
            let value = line.text.trimmingCharacters(in: .whitespaces)
            let ratio = line.font.pointSize / max(1, base)
            if value.count < 180, ratio >= 1.15 { return ratio >= 1.6 ? .heading : ratio >= 1.3 ? .heading2 : .heading3 }
            if value.hasPrefix("> ") { return .quote }
            if firstMatch(#"^(?:[•●▪◦]\s+|[-*+]\s+)"#, value) != nil { return .bullet }
            if firstMatch(#"^[0-9]+[.)]\s+"#, value) != nil { return .numbered }
            // Indentation is a layout hint, not a universal quote detector. Only
            // use it when the page also establishes an ordinary body margin.
            if line.bounds.minX - bodyLeft >= base * 1.25,
               line.bounds.width < page.bounds(for: .cropBox).width * 0.82 { return .quote }
            return .paragraph
        }
        while index < lines.count {
            let first = lines[index]
            if first.monospaced || codeLike(first.text) {
                var end = index + 1
                while end < lines.count,
                      lines[end].monospaced || codeLike(lines[end].text) || abs(lines[end].spaceWidth - first.spaceWidth) < first.spaceWidth * 0.04,
                      adjacent(lines[end - 1], lines[end], extraGap: first.font.pointSize * 1.5),
                      abs(lines[end].bounds.minX - first.bounds.minX) < page.bounds(for: .cropBox).width * 0.45 { end += 1 }
                if end - index > 1 || codeLike(first.text) {
                    let group = Array(lines[index..<end])
                    let origin = group.map { $0.bounds.minX }.min() ?? first.bounds.minX
                    let space = max(1, first.spaceWidth)
                    var source: [String] = []
                    for (offset, line) in group.enumerated() {
                        if offset > 0, group[offset - 1].bounds.minY - line.bounds.maxY > first.font.pointSize * 1.25 { source.append("") }
                        // PDFKit sometimes omits whitespace glyphs. Restore their
                        // relative indentation from positions only when absent.
                        let existing = line.text.prefix { $0 == " " }.count
                        let count = min(120, max(0, Int(((line.bounds.minX - origin) / space).rounded())))
                        let missing = line.text.hasPrefix("\t") ? 0 : max(0, count - existing)
                        source.append(String(repeating: " ", count: missing) + line.text)
                    }
                    result.append(TransferBlock(.code, source.joined(separator: "\n")))
                    index = end; continue
                }
            }
            let blockKind = kind(first)
            let combined = NSMutableAttributedString(string: "")
            var end = index
            repeat {
                let line = lines[end]
                let value = line.attributed
                let ns = value.string as NSString
                var range = NSRange(location: 0, length: ns.length)
                if [.quote, .bullet, .numbered].contains(blockKind) {
                    let pattern = blockKind == .quote ? #"^\s*>\s?"# : blockKind == .bullet ? #"^\s*(?:[•●▪◦]|[-*+])\s+"# : #"^\s*[0-9]+[.)]\s+"#
                    if let marker = firstMatch(pattern, value.string)?.first { range.location = marker.utf16.count; range.length -= range.location }
                }
                if combined.length > 0 {
                    combined.append(NSAttributedString(string: blockKind == .quote ? "\n" : " "))
                }
                combined.append(value.attributedSubstring(from: range))
                end += 1
            } while end < lines.count && [.paragraph, .quote].contains(blockKind) && !lines[end].monospaced
                && kind(lines[end]) == blockKind && abs(lines[end].bounds.minX - first.bounds.minX) < base * 0.5
                && adjacent(lines[end - 1], lines[end])
            let plain = combined.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                let range = (combined.string as NSString).range(of: plain)
                let clean = combined.attributedSubstring(from: range)
                result.append(TransferBlock(blockKind, plain, formatting: RichTextFormatting.runs(clean, base: .systemFont(ofSize: base))))
            }
            index = end
        }
        return result
    }

    static func decodeText(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text.replacingOccurrences(of: "\u{FEFF}", with: "") }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
        throw AppError.message("文本编码不受支持，请另存为 UTF-8 或带 BOM 的 UTF-16")
    }
    static func plainText(_ text: String, title: String) -> TransferDocument {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { TransferBlock(.paragraph, $0) }
        return TransferDocument(name: title, pages: [TransferPage(title: title, blocks: blocks)])
    }
    static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    /// Import document content as independently editable native blocks.
    static func markdownDocument(_ input: String, title: String, directory: URL? = nil) throws -> TransferDocument {
        var source = input.replacingOccurrences(of: "\r\n", with: "\n")
        var pageTitle = title
        if let match = firstMatch(#"^\s*# ([^\n]+)\n(?:\n|$)"#, source) {
            pageTitle = match[1].trimmingCharacters(in: .whitespaces)
            source = String(source.dropFirst(match[0].count))
        }
        if let directory {
            source = try HTMLTransfer.replacing(#"!\[[^\]]*\]\((?:<[^>]+>|[^)]+)\)"#, in: source) { image in
                guard let parts = firstMatch(#"^(!\[[^\]]*\]\()(.+)(\))$"#, image) else { return image }
                let path = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                if path.hasPrefix("https://") || path.hasPrefix("http://") || path.hasPrefix("data:") { return image }
                return parts[1] + "<" + (try importImage(path, directory: directory)) + ">" + parts[3]
            }
        }
        return try markdown(source, title: pageTitle, directory: directory, consumeLeadingTitle: false)
    }

    static func equationSource(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for (left, right) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)")] {
            if trimmed.hasPrefix(left), trimmed.hasSuffix(right), trimmed.count >= left.count + right.count {
                return String(trimmed.dropFirst(left.count).dropLast(right.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    static func markdown(_ input: String, title: String, directory: URL? = nil, consumeLeadingTitle: Bool = true) throws -> TransferDocument {
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var blocks: [TransferBlock] = []; var paragraph: [String] = []; var pageTitle = title; var index = 0; var consumedTitle = false
        func flush() { if !paragraph.isEmpty { blocks.append(TransferBlock(.paragraph, paragraph.joined(separator: "\n"))); paragraph = [] } }
        while index < lines.count {
            let line = lines[index]; let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            if !line.hasPrefix("    "), !line.hasPrefix("\t"),
               firstMatch(#"^\s*(?:[-*+]\s+|[0-9]+[.)]\s+)"#, line) != nil {
                var end = index + 1
                var nested = false
                while end < lines.count {
                    let current = lines[end]
                    if current.trimmingCharacters(in: .whitespaces).isEmpty {
                        guard end + 1 < lines.count,
                              lines[end + 1].hasPrefix("  ") || lines[end + 1].hasPrefix("\t") else { break }
                    } else if current.hasPrefix("  ") || current.hasPrefix("\t") { nested = true }
                    else if firstMatch(#"^(?:[-*+]\s+|[0-9]+[.)]\s+)"#, current) == nil { break }
                    end += 1
                }
                if nested {
                    flush(); blocks.append(TransferBlock(.markdown, lines[index..<end].joined(separator: "\n")))
                    index = end; continue
                }
            }
            if paragraph.isEmpty, line.hasPrefix("    ") || line.hasPrefix("\t") {
                flush(); var code: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    if current.hasPrefix("\t") { code.append(String(current.dropFirst())) }
                    else if current.hasPrefix("    ") { code.append(String(current.dropFirst(4))) }
                    else if current.trimmingCharacters(in: .whitespaces).isEmpty,
                            index + 1 < lines.count,
                            lines[index + 1].hasPrefix("    ") || lines[index + 1].hasPrefix("\t") { code.append("") }
                    else { break }
                    index += 1
                }
                blocks.append(TransferBlock(.code, code.joined(separator: "\n"))); continue
            }
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                flush()
                let closing = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                var source = [line]
                if !(trimmed.count > 2 && trimmed.hasSuffix(closing)) {
                    while index + 1 < lines.count {
                        index += 1; source.append(lines[index])
                        if lines[index].trimmingCharacters(in: .whitespaces).hasSuffix(closing) { break }
                    }
                }
                blocks.append(TransferBlock(.equation, equationSource(source.joined(separator: "\n"))))
            } else if trimmed == "> [!WARNING]" || trimmed == "> [!TIP]" {
                flush(); let kind: BlockKind = trimmed == "> [!WARNING]" ? .warning : .success
                var content: [String] = []
                while index + 1 < lines.count && lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    index += 1
                    content.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                }
                blocks.append(TransferBlock(kind, content.joined(separator: "\n")))
            } else if let match = firstMatch("^(`{3,}|~{3,})(.*)$", trimmed) {
                flush(); let fence = match[1]; var code: [String] = []; index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    if next.count >= fence.count && next.allSatisfy({ $0 == fence.first! }) { break }
                    code.append(lines[index]); index += 1
                }
                blocks.append(TransferBlock(.code, code.joined(separator: "\n"), language: match[2].trimmingCharacters(in: .whitespaces).isEmpty ? "Plain Text" : match[2].trimmingCharacters(in: .whitespaces)))
            } else if let heading = firstMatch("^(#{1,6})\\s+(.+?)\\s*#*\\s*$", trimmed) {
                flush()
                if consumeLeadingTitle && blocks.isEmpty && !consumedTitle && heading[1] == "#" { pageTitle = heading[2]; consumedTitle = true }
                else { blocks.append(TransferBlock(heading[1].count == 1 ? .heading : heading[1].count == 2 ? .heading2 : .heading3, heading[2])) }
            } else if let todo = firstMatch("^[-*+]\\s+\\[([ xX])\\]\\s*(.*)$", trimmed) {
                flush(); blocks.append(TransferBlock(.todo, todo[2], checked: todo[1].lowercased() == "x"))
            } else if let bullet = firstMatch("^[-*+]\\s+(.+)$", trimmed) {
                flush(); blocks.append(TransferBlock(.bullet, bullet[1]))
            } else if let number = firstMatch("^[0-9]+[.)]\\s+(.+)$", trimmed) {
                flush(); blocks.append(TransferBlock(.numbered, number[1]))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush(); blocks.append(TransferBlock(.divider))
            } else if trimmed.hasPrefix(">") {
                flush(); var quoted: [String] = []; var original: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    var content = String(current.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoted.append(content); original.append(lines[index]); index += 1
                }
                // Native quote blocks contain inline text. Preserve a nested
                // quote/list/fenced-code subtree as its own Markdown block.
                let complex = quoted.contains { firstMatch(#"^\s*(?:>|`{3,}|~{3,}|#{1,6}\s|[-*+]\s|[0-9]+[.)]\s)"#, $0) != nil }
                let content = complex ? original.joined(separator: "\n") : quoted.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                blocks.append(TransferBlock(complex ? .markdown : .quote, content))
                continue
            } else if let image = firstMatch("^!\\[.*?\\]\\((.+)\\)$", trimmed) {
                flush(); let source = image[1].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                blocks.append(TransferBlock(.image, try importImage(source, directory: directory)))
            } else if index + 1 < lines.count, trimmed.contains("|"), firstMatch("^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)+\\|?\\s*$", lines[index + 1]) != nil {
                flush(); var rows = [tableCells(trimmed)]; index += 2
                while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index])); index += 1
                }
                let columns = rows.map(\.count).max() ?? 1
                rows = rows.map { row in
                    row.map { RichInlineContent.parseMarkdown($0).text } + Array(repeating: "", count: columns - row.count)
                }
                blocks.append(TransferBlock(.table, String(decoding: try JSONEncoder().encode(rows), as: UTF8.self),
                                            tableLayout: TableLayout(cellsArePlain: true))); continue
            } else { paragraph.append(line) }
            index += 1
        }
        flush()
        for index in blocks.indices where ![.equation, .markdown, .code, .image, .audio, .video, .table, .divider, .tableOfContents, .file, .bookmark].contains(blocks[index].kind) {
            if blocks[index].kind == .paragraph,
               firstMatch(#"\$[^\n$]+\$|\\\(.+?\\\)"#, blocks[index].text) != nil {
                blocks[index].kind = .markdown
                continue
            }
            let parsed = RichInlineContent.parseMarkdown(blocks[index].text)
            blocks[index].text = parsed.text; blocks[index].formatting = parsed.runs
        }
        return TransferDocument(name: pageTitle, pages: [TransferPage(title: pageTitle, blocks: blocks)])
    }
    static func tableCells(_ line: String) -> [String] {
        let value = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        return value.replacingOccurrences(of: "\\|", with: "\u{001F}").components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{001F}", with: "|") }
    }
    static func importImage(_ source: String, directory: URL?) throws -> String {
        if let valid = try? ImageSource.validated(source) { return valid }
        guard let directory, let relative = source.removingPercentEncoding else { throw AppError.message("图片路径无效：" + String(source.prefix(120))) }
        let base = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = URL(fileURLWithPath: relative, relativeTo: base).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/"), !relative.hasPrefix("/"), !relative.contains("://") else {
            throw AppError.message("图片路径超出所选文档目录，未读取：" + String(source.prefix(120)))
        }
        return try ImageSource.load(file)
    }

    static func fromAttributed(_ text: NSAttributedString, title: String, consumeLeadingTitle: Bool = true, bodyFontSize: CGFloat? = nil) -> TransferDocument {
        var blocks: [TransferBlock] = []; let ns = text.string as NSString
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let paragraph = text.attributedSubstring(from: range)
            var codeLength = 0
            paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, range, _ in
                if let font = value as? NSFont, isCodeFont(font) { codeLength += range.length }
            }
            let code = codeLength * 5 >= paragraph.length * 4
            let plain = paragraph.string.replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: code ? .newlines : .whitespacesAndNewlines)
            if code || !plain.isEmpty {
                let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                let size = font?.pointSize ?? 12
                let cleaned = NSMutableAttributedString(attributedString: paragraph)
                for index in stride(from: cleaned.length - 1, through: 0, by: -1) where (cleaned.string as NSString).character(at: index) == 0xFFFC {
                    cleaned.deleteCharacters(in: NSRange(location: index, length: 1))
                }
                let range = (cleaned.string as NSString).range(of: plain)
                let attributed = range.location != NSNotFound ? cleaned.attributedSubstring(from: range) : NSAttributedString(string: plain)
                let runs = RichTextFormatting.runs(attributed, base: .systemFont(ofSize: size))
                let kind: BlockKind
                let paragraphStyle = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                if code { kind = .code }
                else if let paragraphStyle, paragraphStyle.headIndent >= 12, paragraphStyle.firstLineHeadIndent >= 12 { kind = .quote }
                else if let base = bodyFontSize {
                    let ratio = size / max(1, base)
                    kind = plain.count < 180 ? (ratio >= 1.6 ? .heading : ratio >= 1.3 ? .heading2 : ratio >= 1.15 ? .heading3 : .paragraph) : .paragraph
                } else { kind = size >= 24 ? .heading : size >= 20 ? .heading2 : size >= 17 ? .heading3 : .paragraph }
                if kind == .code, let last = blocks.last, last.kind == .code {
                    let offset = last.text.utf16.count + 1
                    blocks[blocks.count - 1].text += "\n" + plain
                    blocks[blocks.count - 1].formatting += runs.map { TextStyleRun(location: $0.location + offset, length: $0.length, style: $0.style) }
                } else { blocks.append(TransferBlock(kind, plain, formatting: runs)) }
            }
            paragraph.enumerateAttribute(.attachment, in: NSRange(location: 0, length: paragraph.length)) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                let bytes = attachment.fileWrapper?.regularFileContents ?? attachment.image?.tiffRepresentation
                if let bytes, let image = try? ImageSource.embedded(bytes) { blocks.append(TransferBlock(.image, image)) }
            }
            location = NSMaxRange(range)
        }
        var pageTitle = title
        if consumeLeadingTitle, let first = blocks.first, first.kind == .heading { pageTitle = first.text; blocks.removeFirst() }
        return TransferDocument(name: pageTitle, pages: [TransferPage(title: pageTitle, blocks: blocks)])
    }
}
