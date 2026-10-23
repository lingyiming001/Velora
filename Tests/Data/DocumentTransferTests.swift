import AppKit
import PDFKit
import CoreText
import SQLite3
import XCTest
@testable import Velora

@MainActor
final class DocumentTransferTests: XCTestCase {
    func testMarkdownTableInlineCodeHasNoVisibleDelimiterCharacters() throws {
        let source = #"""
        | 方法 | 作用 |
        | --- | --- |
        | ` add() ` | **添加消息** |
        | ` messages() ` | 获取当前消息 |
        | ` clear() ` | 清空 |
        | ` id() ` | 返回会话 |
        | `a\|b` | 管道字符 |
        | ``value `quoted` `` | 内容中的反引号 |
        """#
        let table = try XCTUnwrap(DocumentTransfer.markdown(source, title: "Fixture", consumeLeadingTitle: false).pages[0].blocks.first)
        let rows = try JSONDecoder().decode([[String]].self, from: Data(table.text.utf8))
        XCTAssertEqual(table.kind, .table)
        XCTAssertTrue(table.tableLayout.cellsArePlain)
        XCTAssertEqual(rows.map { $0[0] }, ["方法", "add()", "messages()", "clear()", "id()", "a|b", "value `quoted` "])
        XCTAssertEqual(rows[1][1], "添加消息")
        XCTAssertEqual(TableCellContent.visible("` add() `", layout: TableLayout()), "add()")
        XCTAssertEqual(TableCellContent.visible("`literal`", layout: TableLayout(cellsArePlain: true)), "`literal`")
        XCTAssertEqual(TableCellContent.visible("a ` b", layout: TableLayout()), "a ` b")
    }

    func testExternalWordTablePreservesActualBackticks() throws {
        let rows = [["内容"], ["`literal`"]]
        let block = TransferBlock(.table, String(decoding: try JSONEncoder().encode(rows), as: UTF8.self), tableLayout: TableLayout(cellsArePlain: true))
        let document = TransferDocument(name: "table", pages: [TransferPage(title: "", blocks: [block])])
        var package = try ZIPPackage.decode(DOCXTransfer.encode(document))
        package["customXml/velora.xml"] = nil
        let external = try ZIPPackage.encode(package.map { ($0.key, $0.value) })
        let table = try XCTUnwrap(DOCXTransfer.decode(external, title: "external").pages[0].blocks.first { $0.kind == .table })
        let result = try JSONDecoder().decode([[String]].self, from: Data(table.text.utf8))
        XCTAssertEqual(result, rows)
        XCTAssertTrue(table.tableLayout.cellsArePlain)
        XCTAssertEqual(TableCellContent.visible(result[1][0], layout: table.tableLayout), "`literal`")
    }

    func testPlainTableMarkdownRoundTripPreservesLiteralSyntax() throws {
        let rows = [["方法", "内容"], ["`literal`", "*stars* &lt; <tag> [link]"], ["a|b", #"C:\Temp"#]]
        let table = TransferBlock(.table, String(decoding: try JSONEncoder().encode(rows), as: UTF8.self), tableLayout: TableLayout(cellsArePlain: true))
        let markdown = try DocumentExporter.markdown(TransferPage(title: "", blocks: [table]), assetDirectory: nil)
        let restored = try DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false)
        let result = try XCTUnwrap(restored.pages[0].blocks.first { $0.kind == .table })
        XCTAssertEqual(try JSONDecoder().decode([[String]].self, from: Data(result.text.utf8)), rows)
        let html = HTMLTransfer.page(TransferPage(title: "", blocks: [table]))
        XCTAssertTrue(html.contains("`literal`"))
        XCTAssertTrue(html.contains("&amp;lt;"))
    }

    func testHTMLClipboardTableCodeConvertsToPlainNativeCells() async throws {
        let html = "<table><tr><th>方法</th><th>作用</th></tr><tr><td><code>messages()</code></td><td>获取消息</td></tr></table>"
        let markdown = try await ClipboardDocument.markdown(plain: "方法\t作用\nmessages()\t获取消息", html: html)
        let table = try XCTUnwrap(DocumentTransfer.markdown(markdown, title: "", consumeLeadingTitle: false).pages[0].blocks.first { $0.kind == .table })
        let rows = try JSONDecoder().decode([[String]].self, from: Data(table.text.utf8))
        XCTAssertEqual(rows[1], ["messages()", "获取消息"])
        XCTAssertTrue(table.tableLayout.cellsArePlain)
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/transfer", isDirectory: true)
    }
    private func directory() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func png() throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 120,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(image.bitmapData)
        for y in 0..<120 { for x in 0..<240 {
            let p = y * image.bytesPerRow + x * 4
            bytes[p] = 48; bytes[p + 1] = 110; bytes[p + 2] = 220; bytes[p + 3] = 255
        } }
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
    private func fixture() throws -> TransferDocument {
        let image = try ImageSource.embedded(png())
        let rows = String(decoding: try JSONEncoder().encode([["字段", "说明"], ["版本", "导入导出验证"]]), as: UTF8.self)
        let page = TransferPage(title: "导入导出验证", blocks: [
            TransferBlock(.heading, "功能概览"), TransferBlock(.paragraph, "中文内容与 English。导出后应保留标题、列表、代码、表格和本地图片。"),
            TransferBlock(.bullet, "支持常用格式"), TransferBlock(.todo, "图片与备份验证", checked: true),
            TransferBlock(.code, "let message = \"你好\"\nprint(message)\n// ``` inside code", language: "Swift"),
            TransferBlock(.table, rows), TransferBlock(.image, image),
            TransferBlock(.quote, "保留内容，便于迁移。"), TransferBlock(.toggle, "折叠内容", collapsed: true)
        ])
        let child = TransferPage(parentID: page.id, title: "子页面", blocks: [TransferBlock(.paragraph, "Child page content")])
        return TransferDocument(name: "格式验证", pages: [page, child])
    }

    func testPartialStyleAndLinkSurviveMarkdownAndNativeAttributes() throws {
        let style = try JSONDecoder().decode(InlineTextStyle.self, from: Data(#"{"bold":true,"link":"https://example.com/test"}"#.utf8))
        XCTAssertTrue(style.bold == true); XCTAssertFalse(style.underline)
        let runs = [TextStyleRun(location: 0, length: 2, style: style)]
        let markdown = RichInlineContent.markdown("链接", runs: runs)
        let parsed = RichInlineContent.parseMarkdown(markdown)
        XCTAssertEqual(parsed.text, "链接")
        XCTAssertEqual(parsed.runs.first?.style.link, style.link)
        let attributed = RichTextFormatting.attributed("链接", runs: runs, base: .systemFont(ofSize: 17))
        XCTAssertEqual(RichTextFormatting.runs(attributed, base: .systemFont(ofSize: 17)).first?.style.link, style.link)
    }

    func testChatGPTClipboardAndVisualExportsKeepStructureAndMath() async throws {
        let markdown = #"""
        ## MIXED_HEADING

        **重要结论**：行内公式 \(x_i^2 + \frac{a}{b}\)，以及 [参考链接](https://example.com/reference)。

        3. 第三项
           - 嵌套条目
           - **嵌套粗体**
        4. 第四项

        | 参数 | 结果 |
        | --- | --- |
        | A | $\frac{1}{2}$ |

        ```python
        print("literal $x$ and <script>")
        ```

        $$
        \begin{pmatrix}a&b\\c&d\end{pmatrix}
        $$

        MARKER_AFTER_EQUATION
        """#
        let document = TransferDocument(name: "复制与导出一致性", pages: [TransferPage(title: "复制与导出一致性", blocks: [TransferBlock(.markdown, markdown)])])
        let session = DocumentRenderSession(); defer { session.close() }
        try await session.render(document)
        let fontState = try await session.run("return Array.from(document.fonts).some(f=>f.family==='KaTeX_Size3'&&f.status==='loaded')")
        XCTAssertEqual(fontState as? Bool, true)
        let renderedHTML = try await session.run("return document.querySelector('#content').innerHTML")
        let html = try XCTUnwrap(renderedHTML as? String)
        let converted = try await ClipboardDocument.markdown(plain: "网页格式的粘贴", html: html)
        XCTAssertTrue(converted.contains(#"\frac{a}{b}"#))
        XCTAssertTrue(converted.contains("x_i"))
        XCTAssertTrue(converted.contains("  - **嵌套粗体**"))
        XCTAssertTrue(converted.contains("3. "))
        XCTAssertTrue(converted.contains("```python"))
        XCTAssertTrue(converted.contains("https://example.com/reference"))
        XCTAssertFalse(converted.contains("复制代码"))
        let corruptedPlain = "## 方差\n\n$\\operatorname{Var}(X)=\\sigma^2 \\\u{0332}$"
        let recovered = try await ClipboardDocument.markdown(plain: corruptedPlain, html: html)
        XCTAssertTrue(recovered.contains(#"\frac{a}{b}"#))
        XCTAssertFalse(recovered.contains("\u{0332}"))
        let annotationHTML = #"<span class="katex"><span class="katex-mathml"><math><semantics><annotation encoding="application/x-tex">\operatorname{Var}(X)=\sigma^2</annotation></semantics></math></span></span>"#
        let corruptedEquation = #"\operatorname{Var}(X)=\sigma^2 \"# + "\u{0332}"
        XCTAssertEqual(ClipboardDocument.equationPaste(plain: corruptedEquation, html: annotationHTML), #"\operatorname{Var}(X)=\sigma^2"#)
        XCTAssertEqual(ClipboardDocument.equationPaste(plain: #"\begin{aligned}a&=b\\c&=d\end{aligned}"#, html: nil), #"\begin{aligned}a&=b\\c&=d\end{aligned}"#)
        XCTAssertTrue(ClipboardDocument.isStructured(markdown, html: nil))
        XCTAssertFalse(ClipboardDocument.isStructured("普通文本", html: nil))
        let combined = ClipboardDocument.replacing("前😀选中后", formatting: [], selection: NSRange(location: 3, length: 2), with: converted)
        XCTAssertTrue(combined.hasPrefix("前😀\n\n")); XCTAssertTrue(combined.hasSuffix("\n\n后"))
        let folder = root.appendingPathComponent("Fidelity-QA")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for format in [TransferFormat.html, .pdf, .word, .markdown] {
            let file = folder.appendingPathComponent("mixed." + format.ext)
            try await DocumentExporter.write(document, format: format, to: file)
        }
        try assertFidelityFiles(document, in: folder)
    }

    func testChatGPTMermaidPasteRenderAndVisualExports() async throws {
        let flow = "flowchart LR\n    A[\"数据输入\"] --> B{\"质量检查\"}\n    B -->|通过| C[\"模型训练\"]\n    B -->|失败| D[\"修正数据\"]"
        XCTAssertTrue(ClipboardDocument.isStructured(flow, html: nil))
        let wrapped = try await ClipboardDocument.markdown(plain: flow, html: nil)
        XCTAssertTrue(wrapped.hasPrefix("```mermaid\n"))
        XCTAssertTrue(wrapped.contains(flow))
        let clipboard = "<h2>图表</h2><pre data-language=\"mermaid\"><code>" + HTMLTransfer.escape(flow).replacingOccurrences(of: "\n", with: "<br>") + "</code></pre>"
        let fromHTML = try await ClipboardDocument.markdown(plain: "## 图表\n数据输入 → 质量检查", html: clipboard)
        XCTAssertTrue(fromHTML.contains("```mermaid\n"))
        XCTAssertTrue(fromHTML.contains(flow))
        let sequence = "sequenceDiagram\n    participant U as 用户\n    participant S as 服务\n    U->>S: 提交请求\n    S-->>U: 返回结果"
        let mindmap = "mindmap\n  root((学习计划))\n    数学\n      线性代数\n    编程"
        let source = "## 图表测试\n\n" + wrapped + "\n\n" + ClipboardDocument.fencedMermaid(sequence) + "\n\n" + ClipboardDocument.fencedMermaid(mindmap)
        let session = DocumentRenderSession(); defer { session.close() }
        _ = try await session.run("return await renderContent(source,false,false,17,'zh-Hans')", arguments: ["source": source])
        let values = try await session.run("return {diagrams:root.querySelectorAll('.mermaid-canvas svg').length,errors:root.querySelectorAll('.mermaid-error').length,nodes:root.querySelectorAll('.node').length,foreign:root.querySelectorAll('foreignObject,script').length,wide:[...root.querySelectorAll('.mermaid-canvas svg')].every(n=>n.viewBox.baseVal.width>0&&n.viewBox.baseVal.height>0),texts:root.textContent}")
        let result = try XCTUnwrap(values as? [String: Any])
        XCTAssertEqual(result["diagrams"] as? Int, 3, result["texts"] as? String ?? "")
        XCTAssertEqual(result["errors"] as? Int, 0)
        XCTAssertEqual(result["foreign"] as? Int, 0)
        XCTAssertEqual(result["wide"] as? Bool, true)
        let rendered = try await session.run("return root.innerHTML") as? String ?? ""
        let roundtrip = try await ClipboardDocument.markdown(plain: "图表", html: rendered)
        XCTAssertTrue(roundtrip.contains(flow)); XCTAssertTrue(roundtrip.contains(sequence)); XCTAssertTrue(roundtrip.contains(mindmap))
        _ = try await session.run("return await renderContent(source,false,true,17,'en')", arguments: ["source": wrapped])
        let dark = try await session.run("return document.documentElement.classList.contains('dark')&&root.querySelectorAll('.mermaid-canvas svg').length===1")
        XCTAssertEqual(dark as? Bool, true)
        _ = try await session.run("return await renderContent(source,false,false,17,'en')", arguments: ["source": ClipboardDocument.fencedMermaid("flowchart TD\n A --> [broken")])
        let failed = try await session.run("return root.querySelector('.mermaid-error')!==null&&root.querySelector('details').open&&root.textContent.includes('[broken')")
        XCTAssertEqual(failed as? Bool, true)
        let document = TransferDocument(name: "Mermaid QA", pages: [TransferPage(title: "Mermaid 图表", blocks: [TransferBlock(.markdown, source)])])
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".agents/test/mermaid-QA")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for format in [TransferFormat.html, .pdf, .word, .markdown] {
            try await DocumentExporter.write(document, format: format, to: folder.appendingPathComponent("diagrams." + format.ext))
        }
        let html = try String(contentsOf: folder.appendingPathComponent("diagrams.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<svg")); XCTAssertFalse(html.contains("<script src="))
        let word = try ZIPPackage.decode(Data(contentsOf: folder.appendingPathComponent("diagrams.docx")))
        XCTAssertEqual(word.keys.filter { $0.hasPrefix("word/media/") }.count, 3)
        let restored = try await DocumentTransfer.load(folder.appendingPathComponent("diagrams.docx"))
        XCTAssertEqual(restored.pages.first?.blocks.first?.text, source)
    }

    private func assertFidelityFiles(_ document: TransferDocument, in folder: URL) throws {
        let exportedHTML = try String(contentsOf: folder.appendingPathComponent("mixed.html"), encoding: .utf8)
        XCTAssertTrue(exportedHTML.contains("katex-mathml"))
        XCTAssertTrue(exportedHTML.contains("data:font/woff2;base64,"))
        XCTAssertFalse(exportedHTML.contains("<script src="))
        XCTAssertEqual(HTMLTransfer.embeddedDocument(exportedHTML)?.pages.first?.blocks, document.pages[0].blocks)
        let pdf = try XCTUnwrap(PDFDocument(url: folder.appendingPathComponent("mixed.pdf")))
        for word in ["MARKER", "AFTER", "EQUATION"] { XCTAssertTrue(pdf.string?.contains(word) == true) }
        XCTAssertFalse(pdf.string?.contains(#"\begin{pmatrix}"#) == true)
        let word = try Data(contentsOf: folder.appendingPathComponent("mixed.docx"))
        var package = try ZIPPackage.decode(word)
        let xml = try XCTUnwrap(package["word/document.xml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(xml.contains("<m:f>")); XCTAssertTrue(xml.contains("<m:m>"))
        XCTAssertTrue(xml.contains("<w:tbl>")); XCTAssertTrue(xml.contains("<w:hyperlink"))
        XCTAssertFalse(xml.contains("VELORAMATH"))
        XCTAssertEqual(try DOCXTransfer.decode(word, title: "fallback").pages[0].blocks, document.pages[0].blocks)
        // An external edit must invalidate source metadata rather than silently restoring old text.
        package["word/document.xml"] = Data(xml.replacingOccurrences(of: "MARKER_AFTER_EQUATION", with: "EDITED_IN_WORD").utf8)
        let changed = try ZIPPackage.encode(package.map { ($0.key, $0.value) })
        let restored = try DOCXTransfer.decode(changed, title: "Edited")
        XCTAssertTrue(restored.pages[0].blocks.contains { $0.text.contains("EDITED_IN_WORD") })
        XCTAssertTrue(restored.pages[0].blocks.contains { $0.kind == .markdown && $0.text.contains(#"\frac{"#) })
    }

    func testMarkdownBlocksAndLocalAssetsRoundTrip() async throws {
        let folder = try directory(); let document = try fixture()
        let exported = try await DocumentExporter.markdownFolder(document, in: folder)
        let restored = try await DocumentImporter.directory(exported)
        let page = try XCTUnwrap(restored.pages.first { $0.title == "导入导出验证" })
        XCTAssertGreaterThan(page.blocks.count, 5)
        XCTAssertTrue(page.blocks.contains { $0.kind == .todo && $0.checked })
        XCTAssertTrue(page.blocks.contains { $0.kind == .code && $0.text.contains("``` inside code") })
        XCTAssertTrue(page.blocks.contains { $0.kind == .table && $0.text.contains("字段") })
        XCTAssertTrue(page.blocks.contains { $0.kind == .image && $0.text.hasPrefix("data:image/") })
        let child = try XCTUnwrap(restored.pages.first { $0.title == "子页面" })
        XCTAssertEqual(child.parentID, page.id)
        let files = FileManager.default.enumerator(at: exported, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
        XCTAssertTrue(files.contains { $0.pathExtension == "png" })
        let single = folder.appendingPathComponent("one.md")
        try await DocumentExporter.write(TransferDocument(name: page.title, pages: [TransferPage(title: page.title, blocks: page.blocks)]), format: .markdown, to: single)
        let importedSingle = try await DocumentTransfer.load(single)
        XCTAssertEqual(importedSingle.pages.first?.title, page.title)
    }

    func testJSONPreservesStructureAndImportRemapsIDs() async throws {
        let folder = try directory(); let document = try fixture(); let file = folder.appendingPathComponent("export.json")
        try await DocumentExporter.write(document, format: .json, to: file)
        let decoded = try await DocumentTransfer.load(file)
        XCTAssertEqual(decoded.pages[0].blocks, document.pages[0].blocks)
        XCTAssertEqual(decoded.pages[1].parentID, document.pages[0].id)
        let store = try SQLiteStore(databaseURL: folder.appendingPathComponent("store.sqlite"))
        let original = try await store.createPage()
        _ = try await store.importTransfer(decoded); _ = try await store.importTransfer(decoded)
        let pages = try await store.pages()
        XCTAssertEqual(pages.count, 5)
        XCTAssertTrue(pages.contains { $0.id == original.id })
        XCTAssertEqual(Set(pages.map(\.id)).count, 5)
        for child in pages where child.title == "子页面" { XCTAssertEqual(pages.first { $0.id == child.parentID }?.title, "导入导出验证") }
    }

    func testInvalidImportAndMidTransactionFailureLeaveExistingPagesIntact() async throws {
        let folder = try directory(); let database = folder.appendingPathComponent("store.sqlite")
        let store = try SQLiteStore(databaseURL: database); let original = try await store.createPage()
        var invalid = try fixture(); invalid.pages[0].parentID = invalid.pages[1].id
        do { _ = try await store.importTransfer(invalid); XCTFail("Cycle should be rejected") } catch { }
        var raw: OpaquePointer?; XCTAssertEqual(sqlite3_open(database.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TRIGGER reject_test BEFORE INSERT ON pages WHEN NEW.title='拒绝导入' BEGIN SELECT RAISE(ABORT,'test failure'); END;", nil, nil, nil), SQLITE_OK)
        let document = TransferDocument(name: "事务", pages: [TransferPage(title: "先写入", blocks: []), TransferPage(title: "拒绝导入", blocks: [])])
        do { _ = try await store.importTransfer(document); XCTFail("Trigger should abort entire import") } catch { }
        let pages = try await store.pages(); XCTAssertEqual(pages.map(\.id), [original.id])
    }

    func testHTMLRoundTripAndInactiveContentRemoval() async throws {
        let folder = try directory(); let fixture = try fixture(); let file = folder.appendingPathComponent("export.html")
        let document = TransferDocument(name: fixture.name, pages: [fixture.pages[0]])
        try await DocumentExporter.write(document, format: .html, to: file)
        let imported = try await DocumentTransfer.load(file)
        let blocks = try XCTUnwrap(imported.pages.first?.blocks)
        XCTAssertTrue(blocks.contains { $0.kind == .table })
        XCTAssertTrue(blocks.contains { $0.kind == .image })
        XCTAssertTrue(blocks.contains { $0.kind == .code && $0.text.contains("let message") })
        let unsafe = "<html><head><title>HTML 测试</title><link href='https://example.com/external.css'/></head><body><script>alert('do-not-import')</script><p>visible text</p><iframe src='https://example.com'></iframe></body></html>"
        let safe = try HTMLTransfer.importDocument(unsafe, title: "test")
        let text = safe.pages.flatMap(\.blocks).map(\.text).joined()
        XCTAssertTrue(text.contains("visible text")); XCTAssertFalse(text.contains("do-not-import")); XCTAssertFalse(text.contains("external.css"))
    }

    func testRelativeImagesCannotEscapeDocumentFolder() throws {
        let folder = try directory(); let inside = folder.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try png().write(to: folder.appendingPathComponent("outside.png"))
        XCTAssertThrowsError(try DocumentTransfer.markdown("![图片](../outside.png)", title: "test", directory: inside))
        XCTAssertThrowsError(try DocumentTransfer.markdown("![图片](file:///etc/passwd)", title: "test", directory: inside))
        XCTAssertThrowsError(try DocumentTransfer.decodeText(Data([0xFF, 0x00, 0xFF])))
    }

    func testSnapshotSelectionIncludesChildrenAndOptionalTrash() async throws {
        let folder = try directory(); let store = try SQLiteStore(databaseURL: folder.appendingPathComponent("store.sqlite"))
        let root = try await store.createPage(); let child = try await store.createPage(parentID: root.id)
        let other = try await store.createPage(); try await store.archivePage(other.id, archived: true)
        let one = try await store.transferSnapshot(name: "page", pageID: child.id, includeChildren: false)
        XCTAssertEqual(one.pages.count, 1); XCTAssertNil(one.pages[0].parentID)
        let tree = try await store.transferSnapshot(name: "tree", pageID: root.id)
        XCTAssertEqual(tree.pages.count, 2)
        let withoutTrash = try await store.transferSnapshot(name: "workspace")
        let withTrash = try await store.transferSnapshot(name: "workspace", includeArchived: true)
        XCTAssertEqual(withoutTrash.pages.count, 2); XCTAssertEqual(withTrash.pages.count, 3)
    }

    func testPDFRecognizesCodeRestoresGeometricIndentAndGroupsQuotes() async throws {
        let folder = try directory()
        let file = folder.appendingPathComponent("code-and-quote.pdf")
        let consumer = try XCTUnwrap(CGDataConsumer(url: file as CFURL))
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        func draw(_ text: String, font: NSFont, x: CGFloat, y: CGFloat) {
            context.textPosition = CGPoint(x: x, y: y)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            CTLineDraw(line, context)
        }
        let body = NSFont.systemFont(ofSize: 12)
        let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let space = (" " as NSString).size(withAttributes: [.font: code]).width
        draw("Ordinary body text; a paragraph before the code sample.", font: body, x: 50, y: 750)
        draw("if ready:", font: code, x: 50, y: 700)
        draw("print(value)", font: code, x: 50 + space * 4, y: 682)
        draw("return value", font: code, x: 50 + space * 8, y: 664)
        draw("# keep *literal* and 1. items", font: code, x: 50, y: 628)
        draw("Quoted first line", font: body, x: 80, y: 570)
        draw("Quoted second line", font: body, x: 80, y: 552)
        draw("Ordinary body text after the quote; keep it as prose.", font: body, x: 50, y: 500)
        context.endPDFPage(); context.closePDF()
        let imported = try await DocumentTransfer.load(file)
        let blocks = imported.pages[0].blocks
        let source = try XCTUnwrap(blocks.first { $0.kind == .code })
        XCTAssertEqual(source.text, "if ready:\n    print(value)\n        return value\n\n# keep *literal* and 1. items")
        let quote = try XCTUnwrap(blocks.first { $0.kind == .quote })
        XCTAssertEqual(quote.text, "Quoted first line\nQuoted second line")
        XCTAssertTrue(blocks.contains { $0.kind == .paragraph && $0.text.contains("after the quote") })
    }

    func testMarkdownPreservesIndentedCodeAndQuoteSubtrees() throws {
        let input = "Before\n\n    if ready:\n        print(value)\n\n        return value\n\n> First quote line\n> Second quote line\n\n> ```python\n> if ready:\n>     print(value)\n> ```\n\n- parent\n    - child\n\nAfter"
        let blocks = try DocumentTransfer.markdownDocument(input, title: "structure").pages[0].blocks
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code, .quote, .markdown, .markdown, .paragraph])
        XCTAssertEqual(blocks[1].text, "if ready:\n    print(value)\n\n    return value")
        XCTAssertEqual(blocks[2].text, "First quote line\nSecond quote line")
        XCTAssertTrue(blocks[3].text.contains(">     print(value)"))
        XCTAssertTrue(blocks[4].text.contains("    - child"))
    }

    func testHTMLCodeRetainsIndentationAndMultipleBlankLines() async throws {
        let source = "if ready:\n    print(value)\n\n\n    return value"
        let html = "<p>Before</p><pre><code class=\"language-python\">" + HTMLTransfer.escape(source) + "</code></pre><blockquote><p>First quote</p><p>Second quote</p></blockquote>"
        let markdown = try await DocumentRenderSession.markdown(fromHTML: html)
        let blocks = try DocumentTransfer.markdownDocument(markdown, title: "html").pages[0].blocks
        let code = try XCTUnwrap(blocks.first { $0.kind == .code })
        XCTAssertEqual(code.text, source)
        XCTAssertEqual(code.language, "python")
        let quote = try XCTUnwrap(blocks.first { $0.kind == .quote })
        XCTAssertTrue(quote.text.contains("First quote\n\nSecond quote"))
    }

    func testRTFCodeRetainsWhitespaceAndQuotationIndent() async throws {
        let folder = try directory()
        let source = "if ready:\n    print(value)\n\n    return value"
        let text = NSMutableAttributedString(string: source + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        let quote = NSMutableParagraphStyle(); quote.headIndent = 24; quote.firstLineHeadIndent = 24
        text.append(NSAttributedString(string: "Quoted text", attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: quote]))
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let file = folder.appendingPathComponent("code.rtf"); try data.write(to: file)
        let blocks = try await DocumentTransfer.load(file).pages[0].blocks
        XCTAssertEqual(blocks.first { $0.kind == .code }?.text, source)
        XCTAssertEqual(blocks.first { $0.kind == .quote }?.text, "Quoted text")
    }

    func testExternalWordCodePreservesIndentTabsAndEmptyLines() throws {
        let source = "    if ready:\n\tprint(value)\n\n\n    return value"
        let document = TransferDocument(name: "code", pages: [TransferPage(title: "code", blocks: [TransferBlock(.code, source), TransferBlock(.quote, "Quoted content")])])
        var package = try ZIPPackage.decode(DOCXTransfer.encode(document))
        package["customXml/velora.xml"] = nil
        let data = try ZIPPackage.encode(package.map { ($0.key, $0.value) })
        let blocks = try DOCXTransfer.decode(data, title: "external").pages[0].blocks
        XCTAssertEqual(blocks.first { $0.kind == .code }?.text, source)
        XCTAssertEqual(blocks.first { $0.kind == .quote }?.text, "Quoted content")
    }

    func testScannedPDFImportsPageImagesInsteadOfFileAttachment() async throws {
        let folder = try directory()
        let pdf = PDFDocument()
        let image = try XCTUnwrap(NSImage(data: png()))
        for index in 0..<2 { pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: index) }
        let file = folder.appendingPathComponent("scanned.pdf")
        try XCTUnwrap(pdf.dataRepresentation()).write(to: file)
        let imported = try await DocumentTransfer.load(file)
        XCTAssertEqual(imported.pages[0].blocks.filter { $0.kind == .image }.count, 2)
        XCTAssertFalse(imported.pages[0].blocks.contains { $0.kind == .pdfDocument })
        XCTAssertThrowsError(try DocumentTransfer.parsedPDF(Data("invalid".utf8), title: "bad"))
    }

    func testScannedPDFRecognizesEditableText() async throws {
        let folder = try directory()
        let image = NSImage(size: NSSize(width: 900, height: 400))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 400).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
        ("SCANNED DOCUMENT" as NSString).draw(at: NSPoint(x: 40, y: 260), withAttributes: attributes)
        ("Editable text from a PDF scan" as NSString).draw(at: NSPoint(x: 40, y: 140), withAttributes: attributes)
        image.unlockFocus()
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let file = folder.appendingPathComponent("ocr.pdf")
        try XCTUnwrap(pdf.dataRepresentation()).write(to: file)
        let imported = try await DocumentTransfer.load(file)
        let blocks = imported.pages[0].blocks
        XCTAssertTrue(blocks.contains { $0.kind == .image })
        XCTAssertTrue(blocks.contains { $0.kind == .paragraph && $0.text.contains("SCANNED DOCUMENT") })
        XCTAssertTrue(blocks.contains { $0.kind == .paragraph && $0.text.contains("Editable text") })
    }

    func testMarkdownImportSplitsContentIntoNativeBlocks() async throws {
        let folder = try directory()
        let file = folder.appendingPathComponent("blocks.md")
        let source = "# Title\n\n## Section\n\nA **bold** paragraph.\n\n- item\n- [x] done\n\n```swift\nlet x = 1\n```\n\n$$x^2$$\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let imported = try await DocumentTransfer.load(file)
        XCTAssertEqual(imported.pages[0].title, "Title")
        XCTAssertEqual(imported.pages[0].blocks.map(\.kind), [.heading2, .paragraph, .bullet, .todo, .code, .equation])
        XCTAssertFalse(imported.pages[0].blocks[1].formatting.isEmpty)
        let plain = DocumentTransfer.plainText("First\r\nSecond\r\n\r\nThird", title: "plain")
        XCTAssertEqual(plain.pages[0].blocks.map(\.text), ["First", "Second", "Third"])
    }

    func testNativePDFAndWordExportsCanBeImportedAndPaginate() async throws {
        let folder = root.appendingPathComponent("QA", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = try fixture()
        for index in 1...42 { document.pages[1].blocks.append(TransferBlock(.paragraph, "\(index). 分页测试内容，保留中文与 English。文本需要自然换行，页面边界不应截断段落。")) }
        let pdf = folder.appendingPathComponent("sample.pdf"); let word = folder.appendingPathComponent("sample.docx")
        try await DocumentExporter.write(document, format: .pdf, to: pdf)
        try await DocumentExporter.write(document, format: .word, to: word)
        let pdfDocument = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThan(pdfDocument.pageCount, 1)
        XCTAssertTrue(pdfDocument.string?.contains("English") == true)
        let importedPDF = try await DocumentTransfer.load(pdf)
        XCTAssertGreaterThan(importedPDF.pages[0].blocks.count, 2)
        XCTAssertTrue(importedPDF.pages[0].blocks.contains { $0.kind.isHeading })
        XCTAssertFalse(importedPDF.pages[0].blocks.contains { $0.kind == .pdfDocument })
        XCTAssertTrue(importedPDF.pages[0].blocks.contains { $0.text.contains("English") })
        // Explicit PDF-original blocks remain supported by the exporter.
        let original = TransferDocument(name: "original", pages: [TransferPage(title: "original", blocks: [
            TransferBlock(.pdfDocument, EmbeddedPDF.source(try Data(contentsOf: pdf)))
        ])])
        let reexportedPDF = folder.appendingPathComponent("original-roundtrip.pdf")
        try await DocumentExporter.write(original, format: .pdf, to: reexportedPDF)
        XCTAssertEqual(try Data(contentsOf: reexportedPDF), try Data(contentsOf: pdf))
        let importedWord = try await DocumentTransfer.load(word)
        XCTAssertTrue(importedWord.pages[0].blocks.contains { $0.text.contains("English") })
        XCTAssertTrue(importedWord.pages[0].blocks.contains { $0.kind == .image })
        let plain = folder.appendingPathComponent("sample.txt")
        try await DocumentExporter.write(document, format: .text, to: plain)
        let importedText = try await DocumentTransfer.load(plain)
        XCTAssertTrue(importedText.pages[0].blocks.contains { $0.text.contains("English") })
        XCTAssertFalse(try String(contentsOf: plain, encoding: .utf8).contains("data:image/"))
    }
}
