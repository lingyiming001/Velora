import AppKit
import PDFKit
import SQLite3
import XCTest
@testable import Velora

@MainActor
final class DocumentTransferTests: XCTestCase {
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

    func testMarkdownBlocksAndLocalAssetsRoundTrip() throws {
        let folder = try directory(); let document = try fixture()
        let exported = try DocumentExporter.markdownFolder(document, in: folder)
        let restored = try DocumentImporter.directory(exported)
        let page = try XCTUnwrap(restored.pages.first { $0.title == "导入导出验证" })
        XCTAssertTrue(page.blocks.contains { $0.kind == .todo && $0.checked })
        XCTAssertTrue(page.blocks.contains { $0.kind == .code && $0.language == "Swift" && $0.text.contains("``` inside code") })
        XCTAssertTrue(page.blocks.contains { $0.kind == .table })
        XCTAssertTrue(page.blocks.contains { $0.kind == .image && $0.text.hasPrefix("data:image/png;base64,") })
        let child = try XCTUnwrap(restored.pages.first { $0.title == "子页面" })
        XCTAssertEqual(child.parentID, page.id)
        let files = FileManager.default.enumerator(at: exported, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
        XCTAssertTrue(files.contains { $0.pathExtension == "png" })
        let single = folder.appendingPathComponent("one.md")
        try DocumentExporter.write(TransferDocument(name: page.title, pages: [TransferPage(title: page.title, blocks: page.blocks)]), format: .markdown, to: single)
        XCTAssertEqual(try DocumentTransfer.load(single).pages.first?.title, page.title)
    }

    func testJSONPreservesStructureAndImportRemapsIDs() async throws {
        let folder = try directory(); let document = try fixture(); let file = folder.appendingPathComponent("export.json")
        try DocumentExporter.write(document, format: .json, to: file)
        let decoded = try DocumentTransfer.load(file)
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

    func testHTMLRoundTripAndInactiveContentRemoval() throws {
        let folder = try directory(); let fixture = try fixture(); let file = folder.appendingPathComponent("export.html")
        let document = TransferDocument(name: fixture.name, pages: [fixture.pages[0]])
        try DocumentExporter.write(document, format: .html, to: file)
        let imported = try DocumentTransfer.load(file)
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

    func testNativePDFAndWordExportsCanBeImportedAndPaginate() throws {
        let folder = root.appendingPathComponent("QA", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = try fixture()
        for index in 1...42 { document.pages[1].blocks.append(TransferBlock(.paragraph, "\(index). 分页测试内容，保留中文与 English。文本需要自然换行，页面边界不应截断段落。")) }
        let pdf = folder.appendingPathComponent("sample.pdf"); let word = folder.appendingPathComponent("sample.docx")
        try DocumentExporter.write(document, format: .pdf, to: pdf)
        try DocumentExporter.write(document, format: .word, to: word)
        let pdfDocument = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThan(pdfDocument.pageCount, 1)
        XCTAssertTrue(pdfDocument.string?.contains("English") == true)
        XCTAssertFalse(try DocumentTransfer.load(pdf).pages[0].blocks.isEmpty)
        let importedWord = try DocumentTransfer.load(word)
        XCTAssertTrue(importedWord.pages[0].blocks.contains { $0.text.contains("English") })
        XCTAssertTrue(importedWord.pages[0].blocks.contains { $0.kind == .image })
        let plain = folder.appendingPathComponent("sample.txt")
        try DocumentExporter.write(document, format: .text, to: plain)
        XCTAssertTrue(try DocumentTransfer.load(plain).pages[0].blocks.contains { $0.text.contains("English") })
        XCTAssertFalse(try String(contentsOf: plain, encoding: .utf8).contains("data:image/"))
    }
}
