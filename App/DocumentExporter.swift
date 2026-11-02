import Foundation
import AppKit
import UniformTypeIdentifiers
import Darwin

@MainActor
enum DocumentExporter {
    static func safeName(_ input: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let value = input.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return value.isEmpty ? "未命名" : String(value.prefix(80))
    }
    static func write(_ document: TransferDocument, format: TransferFormat, to destination: URL) async throws {
        _ = try document.orderedPages()
        let data: Data
        var assetDirectory: URL?
        do {
            switch format {
            case .json:
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try encoder.encode(document)
            case .epub:
                data = try await EPUBTransfer.encode(document)
            case .pdf:
                data = try await EmbeddedPDF.exportPDF(document)
            case .html, .word:
                let renderer = DocumentRenderSession(); defer { renderer.close() }
                try await renderer.render(document)
                switch format {
                case .html: data = Data(try await renderer.html(document).utf8)
                case .word: data = try await renderer.word(document)
                default: throw AppError.message("无法导出此格式")
                }
            case .text: data = Data(try document.orderedPages().map { "\(document.path(for: $0))\n\(String(repeating: "=", count: 30))\n\(plain($0))" }.joined(separator: "\n\n").utf8)
            case .markdown:
                let folder = destination.deletingLastPathComponent().appendingPathComponent(safeName(destination.deletingPathExtension().lastPathComponent) + ".assets-" + UUID().uuidString.prefix(8), isDirectory: true)
                assetDirectory = folder
                let output = try document.orderedPages().map { try markdown($0, assetDirectory: folder) }.joined(separator: "\n\n---\n\n")
                if FileManager.default.fileExists(atPath: folder.path) { assetDirectory = folder }
                data = Data(output.utf8)
            }
            try data.write(to: destination, options: .atomic)
        } catch {
            if let assetDirectory { try? FileManager.default.removeItem(at: assetDirectory) }
            throw error
        }
    }

    static func markdownFolder(_ document: TransferDocument, in parent: URL) async throws -> URL {
        let root = parent.appendingPathComponent(safeName(document.name) + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            var locations: [UUID: URL] = [:]
            for page in try document.orderedPages() {
                let parent = page.parentID.flatMap { locations[$0] } ?? root
                let directory = parent.appendingPathComponent(safeName(page.title) + "-" + page.id.uuidString.prefix(8), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                locations[page.id] = directory
                try await write(TransferDocument(name: page.title, pages: [TransferPage(id: page.id, title: page.title, archived: page.archived, blocks: page.blocks)]), format: .markdown, to: directory.appendingPathComponent("index.md"))
            }
            return root
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    static func markdown(_ page: TransferPage, assetDirectory: URL?, cardsAsHTML: Bool = false) throws -> String {
        var imageIndex = 0
        var counter = 0
        let blocks = try page.blocks.map { block -> String in
            let number = ListNumbering.advance(kind: block.kind, start: block.listStart, counter: &counter)
            let inline = RichInlineContent.markdown(block.text, runs: block.formatting)
            switch block.kind {
            case .imageCard:
                if cardsAsHTML { return HTMLTransfer.page(TransferPage(title: "", blocks: [block])).replacingOccurrences(of: "<h1></h1>", with: "") }
                guard let card = ImageTextCard.decode(block.text) else { return "[图文卡片无法读取]" }
                let cardPage = TransferPage(id: page.id, title: "", blocks: card.expanded)
                return try markdown(cardPage, assetDirectory: assetDirectory).replacingOccurrences(of: "# \n\n", with: "")
            case .heading: return "# " + inline
            case .heading2: return "## " + inline
            case .heading3: return "### " + inline
            case .bullet: return "- " + inline.replacingOccurrences(of: "\n", with: "\n  ")
            case .numbered: return "\(number). " + inline.replacingOccurrences(of: "\n", with: "\n   ")
            case .todo: return "- [\(block.checked ? "x" : " ")] " + inline
            case .equation: return "$$\n" + DocumentTransfer.equationSource(block.text) + "\n$$"
            case .markdown: return block.text
            case .warning: return "> [!WARNING]\n" + block.text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .success: return "> [!TIP]\n" + block.text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .quote, .callout: return inline.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .divider: return "---"
            case .code:
                let runs = block.text.components(separatedBy: CharacterSet(charactersIn: "\n"))
                let longest = runs.map { line in line.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0 }.max() ?? 0
                let fence = String(repeating: "`", count: max(3, longest + 1))
                let language = block.language == "Plain Text" ? "" : block.language.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\n", with: " ")
                return fence + language + "\n" + block.text + "\n" + fence
            case .pdfDocument:
                let images = try EmbeddedPDF.images(block.text)
                return try images.enumerated().map { index, source in
                    guard let assetDirectory else { return "![PDF 第 \(index + 1) 页](<" + source + ">)" }
                    try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
                    let file = assetDirectory.appendingPathComponent("pdf-" + page.id.uuidString.prefix(8) + "-" + UUID().uuidString.prefix(8) + ".png")
                    guard let split = source.range(of: ";base64,"), let data = Data(base64Encoded: String(source[split.upperBound...])) else { throw AppError.message("PDF 图像无法读取") }
                    try data.write(to: file)
                    return "![PDF 第 \(index + 1) 页](<" + assetDirectory.lastPathComponent + "/" + file.lastPathComponent + ">)"
                }.joined(separator: "\n\n")
            case .image:
                guard !block.text.isEmpty else { return "<!-- 未选择图片 -->" }
                let image = try ImageSource.validated(block.text)
                if image.hasPrefix("data:"), let split = image.range(of: ";base64,"), let bytes = Data(base64Encoded: String(image[split.upperBound...])) {
                    guard let assetDirectory else { return "![图片](<" + image + ">)" }
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
                func row(_ cells: [String]) -> String { "| " + cells.map { TableCellContent.markdown($0, layout: block.tableLayout) }.joined(separator: " | ") + " |" }
                return ([row(first), row(Array(repeating: "---", count: first.count))] + rows.dropFirst().map(row)).joined(separator: "\n")
            case .video, .audio, .file, .bookmark: return "[\(block.kind.label)](<\(block.text)>)"
            case .tableOfContents: return "<!-- 页面目录 -->"
            default: return inline
            }
        }
        return "# " + page.title + "\n\n" + blocks.joined(separator: "\n\n") + "\n"
    }

    static func plain(_ page: TransferPage) -> String {
        let numbers = ListNumbering.numbers(page.blocks)
        return page.blocks.enumerated().map { index, block in
            switch block.kind {
            case .imageCard: return ImageTextCard.decode(block.text).map { [$0.title, $0.body, $0.caption].joined(separator: "\n") } ?? "[图文卡片]"
            case .todo: return (block.checked ? "☑ " : "☐ ") + block.text
            case .bullet: return "• " + block.text
            case .numbered: return "\(numbers[index]). " + block.text
            case .pdfDocument: return EmbeddedPDF.document(block.text)?.string ?? "[PDF 原件无可提取文字]"
            case .image: return block.text.hasPrefix("data:") ? "[本地图片]" : "[图片] " + block.text
            case .table:
                guard let data = block.text.data(using: .utf8), let rows = try? JSONDecoder().decode([[String]].self, from: data) else { return block.text }
                return rows.map { $0.map { TableCellContent.visible($0, layout: block.tableLayout) }.joined(separator: " | ") }.joined(separator: "\n")
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
        for (index, page) in ((try? document.expandingImageCards().orderedPages()) ?? []).enumerated() {
            if index > 0 { append("\n") }
            if page.parentID != nil { append(document.path(for: page), size: 10, color: .darkGray) }
            append(page.title, size: 26, bold: true)
            let numbers = ListNumbering.numbers(page.blocks)
            for (blockIndex, block) in page.blocks.enumerated() {
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
                case .numbered: append("\(numbers[blockIndex]). " + block.text)
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

/// A prepared original resource, independent of the editor's display thumbnail.
struct PreparedMediaResource {
    let fileURL: URL
    let filename: String
    fileprivate let ownedDirectory: URL?

    func discard() { if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) } }

    /// Stage beside the chosen destination so the final replacement is atomic.
    /// A failed download/copy or cancellation must leave an existing file intact.
    func write(to destination: URL) async throws {
        guard destination.isFileURL else { throw AppError.message(L10n.tr("请选择本地保存位置")) }
        try Task.checkCancellation()
        if fileURL.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL { return }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".velora-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: fileURL.resolvingSymlinksInPath(), to: staged)
        try Task.checkCancellation()
        // rename on the same volume atomically replaces the panel-approved name.
        guard rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

enum MediaResourceExporter {
    typealias Download = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    static func supports(_ kind: BlockKind) -> Bool { [.image, .video, .audio, .file, .pdfDocument].contains(kind) }

    static func filename(_ proposed: String?, mime: String?, kind: BlockKind) -> String {
        let leaf = (proposed ?? "").components(separatedBy: "/").last ?? ""
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\\:"))
        var name = leaf.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.isEmpty || name == "Unknown" {
            switch kind {
            case .image: name = "image"
            case .video: name = "video"
            case .audio: name = "audio"
            case .pdfDocument: name = "document"
            default: name = "attachment"
            }
        }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let contentType = mime?.lowercased()
        let type = contentType.flatMap { UTType(mimeType: $0) }
        let inferred = contentType == "application/octet-stream" ? nil : type?.preferredFilenameExtension
        let matchesKind = (kind == .image && contentType?.hasPrefix("image/") == true)
            || (kind == .audio && contentType?.hasPrefix("audio/") == true)
            || (kind == .video && contentType?.hasPrefix("video/") == true)
            || (kind == .pdfDocument && contentType == "application/pdf")
        let suffix: String
        if ext.isEmpty { suffix = inferred ?? (kind == .pdfDocument ? "pdf" : "bin") }
        else if matchesKind, let inferred, UTType(filenameExtension: ext) != type { suffix = inferred }
        else { suffix = String(ext.prefix(16)) }
        return String(stem.prefix(120)) + "." + suffix
    }

    static func validate(_ response: URLResponse, kind: BlockKind) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AppError.message(String(format: L10n.tr("下载失败（HTTP %d）"), code))
        }
        let mime = response.mimeType?.lowercased() ?? ""
        if kind != .file, ["text/html", "application/xhtml+xml"].contains(mime) {
            throw AppError.message(L10n.tr("此链接返回的是网页，请使用图片或音视频文件的直接链接"))
        }
        if [.audio, .video].contains(kind), mime.contains("mpegurl") || mime.contains("dash+xml")
            || ["m3u8", "mpd"].contains(response.url?.pathExtension.lowercased() ?? "") {
            throw AppError.message(L10n.tr("播放列表不能保存为完整音视频，请使用原始媒体文件链接"))
        }
    }

    static func prepare(source: String, kind: BlockKind,
                        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                        download: Download = { try await URLSession.shared.download(for: $0) }) async throws -> PreparedMediaResource {
        guard supports(kind), !source.isEmpty else { throw AppError.message(L10n.tr("此块没有可保存的媒体文件")) }
        try Task.checkCancellation()
        if source.hasPrefix("data:") {
            guard let separator = source.range(of: ";base64,"),
                  let data = Data(base64Encoded: String(source[separator.upperBound...])), !data.isEmpty else {
                throw AppError.message(L10n.tr("媒体数据无效，无法保存"))
            }
            let mime = String(source[source.index(source.startIndex, offsetBy: 5)..<separator.lowerBound]).lowercased()
            guard (kind == .image && mime.hasPrefix("image/")) || (kind == .pdfDocument && mime == "application/pdf")
                    || (kind == .audio && mime.hasPrefix("audio/")) || (kind == .video && mime.hasPrefix("video/")) || kind == .file else {
                throw AppError.message(L10n.tr("媒体数据类型不匹配，无法保存"))
            }
            let directory = temporaryDirectory.appendingPathComponent("velora-media-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let name = filename(nil, mime: mime, kind: kind)
                let file = directory.appendingPathComponent(name)
                try data.write(to: file, options: .atomic)
                try Task.checkCancellation()
                return PreparedMediaResource(fileURL: file, filename: name, ownedDirectory: directory)
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
        guard let url = MediaSource.url(source) else { throw AppError.message(L10n.tr("媒体链接无效，无法保存")) }
        if url.isFileURL {
            let file = url.resolvingSymlinksInPath()
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isReadableFile(atPath: file.path) else {
                throw AppError.message(L10n.tr("文件不存在或无法读取，请重新选择。"))
            }
            return PreparedMediaResource(fileURL: file, filename: filename(url.lastPathComponent, mime: nil, kind: kind), ownedDirectory: nil)
        }
        let (downloaded, response) = try await download(URLRequest(url: url, timeoutInterval: 120))
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        try validate(response, kind: kind)
        guard ((try? downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            throw AppError.message(L10n.tr("下载的文件为空，未保存"))
        }
        let directory = temporaryDirectory.appendingPathComponent("velora-media-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let name = filename(response.suggestedFilename ?? url.lastPathComponent, mime: response.mimeType, kind: kind)
            let file = directory.appendingPathComponent(name)
            try FileManager.default.moveItem(at: downloaded, to: file)
            try Task.checkCancellation()
            return PreparedMediaResource(fileURL: file, filename: name, ownedDirectory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}

/// Persistent image bytes live inside the document database and travel with backups.
@MainActor
enum LocalDocumentImages {
    typealias Fetch = (String) async throws -> Data
    static func fetch(_ source: String) async throws -> Data {
        let resource = try await MediaResourceExporter.prepare(source: source, kind: .image)
        defer { resource.discard() }
        guard (try resource.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= ImageSource.maximumBytes else {
            throw AppError.message("图片超过 12 MB，未导入")
        }
        return try await Task.detached { try Data(contentsOf: resource.fileURL) }.value
    }
    static func blocks(_ input: [TransferBlock], fetch: Fetch = LocalDocumentImages.fetch) async throws -> [TransferBlock] {
        var result = input, cached: [String: String] = [:]
        for index in result.indices where result[index].kind == .image || result[index].kind == .imageCard {
            var card = result[index].kind == .imageCard ? ImageTextCard.decode(result[index].text) : nil
            let source = card?.image ?? result[index].text
            func setSource(_ value: String) {
                if card != nil { card!.image = value; result[index].text = card!.encoded }
                else { result[index].text = value }
            }
            guard source.lowercased().hasPrefix("https://") || source.lowercased().hasPrefix("http://") else { continue }
            try Task.checkCancellation()
            if let embedded = cached[source] { setSource(embedded); continue }
            let bytes = try await fetch(try ImageSource.validated(source))
            let embedded = try ImageSource.embedded(bytes)
            cached[source] = embedded; setSource(embedded)
            guard result.reduce(0, { $0 + $1.text.utf8.count }) <= DocumentTransfer.maximumFileSize else {
                throw AppError.message("本地图片与文档总量超过 100 MB，未导入")
            }
        }
        guard result.reduce(0, { $0 + $1.text.utf8.count }) <= DocumentTransfer.maximumFileSize else {
            throw AppError.message("本地图片与文档总量超过 100 MB，未导入")
        }
        return result
    }
    static func document(_ input: TransferDocument) async throws -> TransferDocument {
        var result = input
        let counts = result.pages.map { $0.blocks.count }
        let converted = try await blocks(result.pages.flatMap(\.blocks))
        var offset = 0
        for index in result.pages.indices {
            result.pages[index].blocks = Array(converted[offset..<(offset + counts[index])]); offset += counts[index]
        }
        return result
    }
}
