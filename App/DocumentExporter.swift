import Foundation
import AppKit

@MainActor
enum DocumentExporter {
    static func safeName(_ input: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let value = input.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return value.isEmpty ? "未命名" : String(value.prefix(80))
    }
    static func write(_ document: TransferDocument, format: TransferFormat, to destination: URL) throws {
        _ = try document.orderedPages()
        let data: Data
        var assetDirectory: URL?
        do {
            switch format {
            case .json:
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try encoder.encode(document)
            case .html: data = Data(try HTMLTransfer.document(document).utf8)
            case .text: data = Data(try document.orderedPages().map { "\(document.path(for: $0))\n\(String(repeating: "=", count: 30))\n\(plain($0))" }.joined(separator: "\n\n").utf8)
            case .markdown:
                let folder = destination.deletingLastPathComponent().appendingPathComponent(safeName(destination.deletingPathExtension().lastPathComponent) + ".assets-" + UUID().uuidString.prefix(8), isDirectory: true)
                assetDirectory = folder
                let output = try document.orderedPages().map { try markdown($0, assetDirectory: folder) }.joined(separator: "\n\n---\n\n")
                if FileManager.default.fileExists(atPath: folder.path) { assetDirectory = folder }
                data = Data(output.utf8)
            case .word:
                data = try DOCXTransfer.encode(document)
            case .pdf: data = try pdf(richText(document))
            }
            try data.write(to: destination, options: .atomic)
        } catch {
            if let assetDirectory { try? FileManager.default.removeItem(at: assetDirectory) }
            throw error
        }
    }

    static func markdownFolder(_ document: TransferDocument, in parent: URL) throws -> URL {
        let root = parent.appendingPathComponent(safeName(document.name) + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            var locations: [UUID: URL] = [:]
            for page in try document.orderedPages() {
                let parent = page.parentID.flatMap { locations[$0] } ?? root
                let directory = parent.appendingPathComponent(safeName(page.title) + "-" + page.id.uuidString.prefix(8), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                locations[page.id] = directory
                try write(TransferDocument(name: page.title, pages: [TransferPage(id: page.id, title: page.title, archived: page.archived, blocks: page.blocks)]), format: .markdown, to: directory.appendingPathComponent("index.md"))
            }
            return root
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    static func markdown(_ page: TransferPage, assetDirectory: URL) throws -> String {
        var imageIndex = 0
        let blocks = try page.blocks.map { block -> String in
            let inline = RichInlineContent.markdown(block.text, runs: block.formatting)
            switch block.kind {
            case .heading: return "# " + inline
            case .heading2: return "## " + inline
            case .heading3: return "### " + inline
            case .bullet: return "- " + block.text.replacingOccurrences(of: "\n", with: "\n  ")
            case .numbered: return "1. " + block.text.replacingOccurrences(of: "\n", with: "\n   ")
            case .todo: return "- [\(block.checked ? "x" : " ")] " + block.text
            case .quote, .callout: return block.text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .divider: return "---"
            case .code:
                let runs = block.text.components(separatedBy: CharacterSet(charactersIn: "\n"))
                let longest = runs.map { line in line.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0 }.max() ?? 0
                let fence = String(repeating: "`", count: max(3, longest + 1))
                let language = block.language == "Plain Text" ? "" : block.language.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\n", with: " ")
                return fence + language + "\n" + block.text + "\n" + fence
            case .image:
                guard !block.text.isEmpty else { return "<!-- 未选择图片 -->" }
                let image = try ImageSource.validated(block.text)
                if image.hasPrefix("data:"), let split = image.range(of: ";base64,"), let bytes = Data(base64Encoded: String(image[split.upperBound...])) {
                    try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
                    imageIndex += 1
                    let ext = image.hasPrefix("data:image/jpeg") ? "jpg" : image.hasPrefix("data:image/gif") ? "gif" : image.hasPrefix("data:image/webp") ? "webp" : "png"
                    let file = assetDirectory.appendingPathComponent("image-\(page.id.uuidString.prefix(8))-\(imageIndex).\(ext)")
                    try bytes.write(to: file, options: .atomic)
                    let path = assetDirectory.lastPathComponent + "/" + file.lastPathComponent
                    return "![图片](<" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + ">)"
                }
                return "![图片](<" + image + ">)"
            case .table:
                guard let data = block.text.data(using: .utf8), let rows = try? JSONDecoder().decode([[String]].self, from: data), let first = rows.first else { return block.text }
                func row(_ cells: [String]) -> String { "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }.joined(separator: " | ") + " |" }
                return ([row(first), row(Array(repeating: "---", count: first.count))] + rows.dropFirst().map(row)).joined(separator: "\n")
            case .video, .audio, .file, .bookmark: return "[\(block.kind.label)](<\(block.text)>)"
            case .tableOfContents: return "<!-- 页面目录 -->"
            default: return inline
            }
        }
        return "# " + page.title + "\n\n" + blocks.joined(separator: "\n\n") + "\n"
    }

    static func plain(_ page: TransferPage) -> String {
        page.blocks.map { block in
            switch block.kind {
            case .todo: return (block.checked ? "☑ " : "☐ ") + block.text
            case .bullet: return "• " + block.text
            case .numbered: return "1. " + block.text
            case .image: return block.text.hasPrefix("data:") ? "[本地图片]" : "[图片] " + block.text
            case .table:
                guard let data = block.text.data(using: .utf8), let rows = try? JSONDecoder().decode([[String]].self, from: data) else { return block.text }
                return rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
            case .divider: return "--------------------"
            default: return block.text
            }
        }.joined(separator: "\n\n")
    }

    static func richText(_ document: TransferDocument) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        func append(_ text: String, size: CGFloat = 12, bold: Bool = false, mono: Bool = false, color: NSColor = .black, formatting: [TextStyleRun] = []) {
            let style = NSMutableParagraphStyle(); style.paragraphSpacing = 9; style.lineSpacing = 3; style.lineBreakMode = .byCharWrapping
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            let value = NSMutableAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            for run in formatting { if let range = run.validRange(in: text) { value.addAttributes(RichTextFormatting.attributes(run.style, base: font), range: range) } }
            output.append(value)
        }
        for (index, page) in ((try? document.orderedPages()) ?? []).enumerated() {
            if index > 0 { append("\n") }
            if page.parentID != nil { append(document.path(for: page), size: 10, color: .darkGray) }
            append(page.title, size: 26, bold: true)
            for block in page.blocks {
                switch block.kind {
                case .heading: append(block.text, size: 22, bold: true, formatting: block.formatting)
                case .heading2: append(block.text, size: 18, bold: true, formatting: block.formatting)
                case .heading3: append(block.text, size: 16, bold: true, formatting: block.formatting)
                case .code: append(block.text, size: 10, mono: true, formatting: block.formatting)
                case .image:
                    if block.text.hasPrefix("data:"), let image = ImageSource.thumbnail(block.text), image.size.width > 0, image.size.height > 0 {
                        let ratio = min(1, 490 / image.size.width, 400 / image.size.height)
                        let displaySize = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
                        let png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
                        if let png {
                            let wrapper = FileWrapper(regularFileWithContents: png); wrapper.preferredFilename = "image.png"
                            let attachment = NSTextAttachment(fileWrapper: wrapper)
                            let display = image.copy() as! NSImage; display.size = displaySize
                            attachment.attachmentCell = NSTextAttachmentCell(imageCell: display)
                            attachment.bounds = NSRect(origin: .zero, size: displaySize)
                            output.append(NSAttributedString(attachment: attachment)); append("")
                        }
                    } else { append("[图片链接] " + block.text, size: 10, color: .darkGray) }
                case .table: append(plain(TransferPage(title: "", blocks: [block])), size: 10, mono: true)
                case .todo: append((block.checked ? "☑ " : "☐ ") + block.text)
                case .bullet: append("• " + block.text)
                case .numbered: append("1. " + block.text)
                case .quote, .callout: append("▎ " + block.text, color: .darkGray)
                case .divider: append("────────────────────", color: .lightGray)
                case .tableOfContents: append("页面目录", size: 10, color: .darkGray)
                default: append(block.text, formatting: block.formatting)
                }
            }
        }
        return output
    }

    static func pdf(_ attributed: NSAttributedString) throws -> Data {
        let width: CGFloat = 499; let height: CGFloat = 746
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        let all = manager.glyphRange(for: container)
        var pages: [(range: NSRange, offset: CGFloat)] = []
        var start = all.location; var top: CGFloat = 0
        manager.enumerateLineFragments(forGlyphRange: all) { rect, _, _, range, _ in
            if rect.maxY - top > height && range.location > start {
                pages.append((NSRange(location: start, length: range.location - start), top))
                start = range.location; top = rect.minY
            }
        }
        if NSMaxRange(all) > start { pages.append((NSRange(location: start, length: NSMaxRange(all) - start), top)) }
        if pages.isEmpty { pages.append((NSRange(location: 0, length: 0), 0)) }
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw AppError.message("无法创建 PDF") }
        for page in pages {
            context.beginPDFPage(nil)
            context.saveGState()
            context.setFillColor(NSColor.white.cgColor); context.fill(mediaBox)
            context.translateBy(x: 48, y: 842 - 48); context.scaleBy(x: 1, y: -1)
            context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            manager.drawBackground(forGlyphRange: page.range, at: NSPoint(x: 0, y: -page.offset))
            manager.drawGlyphs(forGlyphRange: page.range, at: NSPoint(x: 0, y: -page.offset))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        guard data.length > 0 else { throw AppError.message("PDF 导出失败") }
        return data as Data
    }
}
