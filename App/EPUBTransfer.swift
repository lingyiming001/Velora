import AppKit
import Foundation

/// Reflowable EPUB 3: no runtime scripts, source database, or application settings.
@MainActor
enum EPUBTransfer {
    static func xml(_ value: String) -> String { DOCXTransfer.xml(value) }
    static func xhtml(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh-CN" lang="zh-CN"><head><title>\(xml(title))</title><link rel="stylesheet" type="text/css" href="book.css"/></head><body>\(body)</body></html>
        """
    }

    static func encode(_ document: TransferDocument) async throws -> Data {
        let validated = try document.expandingImageCards().orderedPages()
        let children = Dictionary(grouping: validated.filter { $0.parentID != nil }, by: { $0.parentID! })
        // Book reading order follows the visible tree, completing each subtree first.
        var pages: [TransferPage] = []
        var pending = Array(validated.filter { $0.parentID == nil }.reversed())
        while let page = pending.popLast() {
            pages.append(page); pending.append(contentsOf: (children[page.id] ?? []).reversed())
        }
        let locations = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element.id, "chapter-\($0.offset + 1).xhtml") })
        var files: [(String, Data)] = []
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"css\" href=\"book.css\" media-type=\"text/css\"/>"
        var spine = ""
        var headingLinks: [UUID: String] = [:]
        var imageCache: [String: String] = [:]
        var totalBytes = 0
        func add(_ path: String, _ data: Data) throws {
            totalBytes += data.count
            guard totalBytes <= DocumentTransfer.maximumFileSize else { throw AppError.message("EPUB 内容超过 100 MB") }
            files.append(("EPUB/" + path, data))
        }
        func image(_ source: String) async throws -> String {
            if let path = imageCache[source] { return "<img src=\"\(path)\" alt=\"图片\"/>" }
            let resource = try await MediaResourceExporter.prepare(source: source, kind: .image)
            defer { resource.discard() }
            let bytes = try Data(contentsOf: resource.fileURL)
            // PNG is a core EPUB image type, including for source WebP/HEIC/SVG.
            guard let picture = NSImage(data: bytes), let tiff = picture.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
                throw AppError.message("EPUB 图片无法读取")
            }
            let path = "images/image-\(imageCache.count + 1).png"
            try add(path, png)
            manifest += "<item id=\"image-\(imageCache.count + 1)\" href=\"\(path)\" media-type=\"image/png\"/>"
            imageCache[source] = path
            return "<img src=\"\(path)\" alt=\"图片\"/>"
        }
        for (pageIndex, page) in pages.enumerated() {
            try Task.checkCancellation()
            var blocks: [TransferBlock] = []
            for block in page.blocks {
                if block.kind == .markdown {
                    blocks += try DocumentTransfer.markdown(block.text, title: "", consumeLeadingTitle: false).pages[0].blocks
                } else { blocks.append(block) }
            }
            var body = "<h1>\(xml(page.title))</h1>"
            var links = ""
            let numbers = ListNumbering.numbers(blocks)
            for (index, block) in blocks.enumerated() {
                try Task.checkCancellation()
                // Remove XML-illegal controls before constructing rich inline markup.
                let cleaned = String(String.UnicodeScalarView(block.text.unicodeScalars.filter { ($0.value >= 32 || [9,10,13].contains($0.value)) && $0.value != 0xFFFE && $0.value != 0xFFFF }))
                let text = RichInlineContent.html(cleaned, runs: cleaned == block.text ? block.formatting : [])
                switch block.kind {
                case .heading, .heading2, .heading3:
                    let level = block.kind == .heading ? 2 : block.kind == .heading2 ? 3 : 4
                    let anchor = "heading-\(index)"
                    body += "<h\(level) id=\"\(anchor)\">\(text)</h\(level)>"
                    links += "<li><a href=\"\(locations[page.id]!)#\(anchor)\">\(xml(block.text))</a></li>"
                case .numbered: body += "<ol start=\"\(numbers[index])\"><li>\(text)</li></ol>"
                case .bullet: body += "<ul><li>\(text)</li></ul>"
                case .todo: body += "<p>\(block.checked ? "☑" : "☐") \(text)</p>"
                case .code: body += "<pre><code>\(xml(block.text))</code></pre>"
                case .equation: body += "<pre class=\"equation\">\(xml(DocumentTransfer.equationSource(block.text)))</pre>"
                case .divider: body += "<hr/>"
                case .quote, .callout, .warning, .success: body += "<blockquote>\(text)</blockquote>"
                case .image:
                    if !block.text.isEmpty { body += "<p class=\"image\">" + (try await image(block.text)) + "</p>" }
                case .pdfDocument:
                    for source in try EmbeddedPDF.images(block.text) { body += "<p class=\"image\">" + (try await image(source)) + "</p>" }
                case .table:
                    if let data = block.text.data(using: .utf8), let rows = try? JSONDecoder().decode([[String]].self, from: data) {
                        body += "<table>" + rows.enumerated().map { row, cells in
                            "<tr>" + cells.map { cell in
                                let tag = row == 0 ? "th" : "td"
                                return "<\(tag)>\(xml(TableCellContent.visible(cell, layout: block.tableLayout)))</\(tag)>"
                            }.joined() + "</tr>"
                        }.joined() + "</table>"
                    } else { body += "<p>\(text)</p>" }
                case .tableOfContents: body += "<p><a href=\"nav.xhtml\">目录</a></p>"
                case .audio, .video, .file, .bookmark:
                    if let link = HTMLTransfer.safeLink(block.text) {
                        body += "<p><a href=\"\(xml(link))\">\(xml(block.kind.label))</a></p>"
                    } else { body += "<p>[\(xml(block.kind.label))]</p>" }
                default: body += "<p>\(text)</p>"
                }
            }
            headingLinks[page.id] = links
            let path = locations[page.id]!
            try add(path, Data(xhtml(title: page.title, body: body).utf8))
            manifest += "<item id=\"chapter-\(pageIndex)\" href=\"\(path)\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"chapter-\(pageIndex)\"/>"
            await Task.yield()
        }
        // Iterative construction also handles deeply nested page trees.
        var entries: [UUID: String] = [:]
        for page in pages.reversed() {
            let nested = (headingLinks[page.id] ?? "") + (children[page.id] ?? []).map { entries[$0.id] ?? "" }.joined()
            entries[page.id] = "<li><a href=\"\(locations[page.id]!)\">\(xml(page.title.isEmpty ? "未命名" : page.title))</a>" + (nested.isEmpty ? "" : "<ol>\(nested)</ol>") + "</li>"
        }
        let toc = pages.filter { $0.parentID == nil }.map { entries[$0.id] ?? "" }.joined()
        try add("nav.xhtml", Data(xhtml(title: "目录", body: "<nav epub:type=\"toc\" id=\"toc\"><h1>目录</h1><ol>\(toc)</ol></nav>").utf8))
        try add("book.css", Data("""
        body{font-family:serif;line-height:1.65;margin:5%;overflow-wrap:break-word}h1,h2,h3,h4{line-height:1.3;break-after:avoid}h1{margin-bottom:1.5em}p{margin:.7em 0}img{max-width:100%;height:auto}.image{text-align:center}pre{white-space:pre-wrap;overflow-wrap:break-word;background:#f3f3f3;padding:.8em}code{font-family:monospace;background:#f3f3f3}blockquote{border-left:.2em solid #aaa;padding-left:1em;margin-left:0}table{border-collapse:collapse;width:100%}th,td{border:1px solid #aaa;padding:.4em;text-align:left}a{color:#285b91}nav ol{padding-left:1.4em}
        """.utf8))
        let date = ISO8601DateFormatter().string(from: Date())
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(xml(document.name.isEmpty ? "未命名" : document.name))</dc:title><dc:language>zh-CN</dc:language><meta property="dcterms:modified">\(date)</meta></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
        """
        try add("package.opf", Data(opf.utf8))
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        return try ZIPPackage.encode([("mimetype", Data("application/epub+zip".utf8)), ("META-INF/container.xml", Data(container.utf8))] + files)
    }
}
