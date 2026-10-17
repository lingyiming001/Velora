import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum TransferFormat: String, CaseIterable, Identifiable {
    case markdown, text, html, json, pdf, word
    var id: String { rawValue }
    var label: String {
        switch self {
        case .markdown: "Markdown"
        case .text: "纯文本 TXT"
        case .html: "网页 HTML"
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
    init(_ kind: BlockKind, _ text: String = "", checked: Bool = false, language: String = "Plain Text", collapsed: Bool = false, formatting: [TextStyleRun] = []) {
        self.formatting = formatting
        self.kind = kind; self.text = text; self.checked = checked; self.language = language; self.collapsed = collapsed
    }
    init(_ block: Block) { self.init(block.kind, block.text, checked: block.checked, language: block.language, collapsed: block.collapsed, formatting: block.formatting) }
    enum CodingKeys: String, CodingKey { case kind, text, checked, language, collapsed, formatting }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(BlockKind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        checked = try container.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "Plain Text"
        collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        formatting = try container.decodeIfPresent([TextStyleRun].self, forKey: .formatting) ?? []
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
    static func load(_ url: URL) throws -> TransferDocument {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let format = TransferFormat.detect(url) else { throw AppError.message("不支持的文件格式：" + url.lastPathComponent) }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumFileSize else { throw AppError.message("单个导入文件不能超过 100 MB") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumFileSize else { throw AppError.message("文件超过 100 MB") }
        let name = url.deletingPathExtension().lastPathComponent
        if format == .json {
            let document = try JSONDecoder().decode(TransferDocument.self, from: data)
            _ = try document.orderedPages(); return document
        }
        if format == .pdf {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw AppError.message("PDF 无法读取或需要密码") }
            let text = pdf.string ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("PDF 没有可提取文字；扫描件请先进行 OCR") }
            return plainText(text, title: name)
        }
        if format == .word {
            if url.pathExtension.lowercased() == "docx" { return try DOCXTransfer.decode(data, title: name) }
            let type: NSAttributedString.DocumentType = url.pathExtension.lowercased() == "rtf" ? .rtf : url.pathExtension.lowercased() == "doc" ? .docFormat : .officeOpenXML
            let attributed = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil)
            return fromAttributed(attributed, title: name)
        }
        let text = try decodeText(data)
        switch format {
        case .markdown: return try markdown(text, title: name, directory: url.deletingLastPathComponent())
        case .html: return try HTMLTransfer.importDocument(text, title: name, directory: url.deletingLastPathComponent())
        default: return plainText(text, title: name)
        }
    }

    static func decodeText(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text.replacingOccurrences(of: "\u{FEFF}", with: "") }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
        throw AppError.message("文本编码不受支持，请另存为 UTF-8 或带 BOM 的 UTF-16")
    }
    static func plainText(_ text: String, title: String) -> TransferDocument {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { TransferBlock(.paragraph, $0) }
        return TransferDocument(name: title, pages: [TransferPage(title: title, blocks: blocks)])
    }
    static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    static func markdown(_ input: String, title: String, directory: URL? = nil) throws -> TransferDocument {
        let lines = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var blocks: [TransferBlock] = []; var paragraph: [String] = []; var pageTitle = title; var index = 0; var consumedTitle = false
        func flush() { if !paragraph.isEmpty { blocks.append(TransferBlock(.paragraph, paragraph.joined(separator: "\n"))); paragraph = [] } }
        while index < lines.count {
            let line = lines[index]; let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            if let match = firstMatch("^(`{3,}|~{3,})(.*)$", trimmed) {
                flush(); let fence = match[1]; var code: [String] = []; index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    if next.count >= fence.count && next.allSatisfy({ $0 == fence.first! }) { break }
                    code.append(lines[index]); index += 1
                }
                blocks.append(TransferBlock(.code, code.joined(separator: "\n"), language: match[2].trimmingCharacters(in: .whitespaces).isEmpty ? "Plain Text" : match[2].trimmingCharacters(in: .whitespaces)))
            } else if let heading = firstMatch("^(#{1,6})\\s+(.+?)\\s*#*\\s*$", trimmed) {
                flush()
                if blocks.isEmpty && !consumedTitle && heading[1] == "#" { pageTitle = heading[2]; consumedTitle = true }
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
                flush(); blocks.append(TransferBlock(.quote, String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let image = firstMatch("^!\\[.*?\\]\\((.+)\\)$", trimmed) {
                flush(); let source = image[1].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                blocks.append(TransferBlock(.image, try importImage(source, directory: directory)))
            } else if index + 1 < lines.count, trimmed.contains("|"), firstMatch("^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)+\\|?\\s*$", lines[index + 1]) != nil {
                flush(); var rows = [tableCells(trimmed)]; index += 2
                while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index])); index += 1
                }
                let columns = rows.map(\.count).max() ?? 1
                rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
                blocks.append(TransferBlock(.table, String(decoding: try JSONEncoder().encode(rows), as: UTF8.self))); continue
            } else { paragraph.append(line) }
            index += 1
        }
        flush()
        for index in blocks.indices where ![.code, .image, .audio, .video, .table, .divider, .tableOfContents, .file, .bookmark].contains(blocks[index].kind) {
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

    static func fromAttributed(_ text: NSAttributedString, title: String) -> TransferDocument {
        var blocks: [TransferBlock] = []; let ns = text.string as NSString
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let paragraph = text.attributedSubstring(from: range)
            let plain = paragraph.string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                let size = font?.pointSize ?? 12
                blocks.append(TransferBlock(size >= 24 ? .heading : size >= 20 ? .heading2 : size >= 17 ? .heading3 : .paragraph, plain))
            }
            paragraph.enumerateAttribute(.attachment, in: NSRange(location: 0, length: paragraph.length)) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                let bytes = attachment.fileWrapper?.regularFileContents ?? attachment.image?.tiffRepresentation
                if let bytes, let image = try? ImageSource.embedded(bytes) { blocks.append(TransferBlock(.image, image)) }
            }
            location = NSMaxRange(range)
        }
        var pageTitle = title
        if let first = blocks.first, first.kind == .heading { pageTitle = first.text; blocks.removeFirst() }
        return TransferDocument(name: pageTitle, pages: [TransferPage(title: pageTitle, blocks: blocks)])
    }
}
