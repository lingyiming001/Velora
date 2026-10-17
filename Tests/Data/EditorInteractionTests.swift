import AppKit
import XCTest
@testable import Velora

@MainActor
final class EditorInteractionTests: XCTestCase {
    private func fixture() async throws -> (URL, SQLiteStore, WorkspaceModel, [Block]) {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/editor-" + UUID().uuidString)
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("store.sqlite"))
        let page = try await store.createPage()
        var blocks: [Block] = []
        for kind in [BlockKind.paragraph, .code, .divider, .image, .paragraph] {
            let block = try await store.createBlock(pageID: page.id, kind: kind)
            if kind != .image { try await store.updateBlock(block.id, text: kind == .code ? "let value = 1" : "内容") }
            blocks.append(block)
        }
        let model = WorkspaceModel(store: store); await model.refreshPages(); model.select(page.id)
        for _ in 0..<100 where model.blocks.count != blocks.count { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.count, blocks.count)
        return (directory, store, model, blocks)
    }

    func testRangeSelectionDeleteAndSelectAllLeavesWritableParagraph() async throws {
        let (_, store, model, original) = try await fixture()
        model.selectBlock(original[1].id)
        model.selectBlock(original[3].id, extend: true)
        XCTAssertEqual(model.selectedBlockIDs, Set(original[1...3].map(\.id)))
        try await model.deleteSelectedBlocks()
        XCTAssertEqual(model.blocks.map(\.id), [original[0].id, original[4].id])
        let saved = try await store.blocks(in: original[0].pageID)
        XCTAssertEqual(saved.count, 2)
        model.selectAllBlocks(); try await model.deleteSelectedBlocks()
        XCTAssertEqual(model.blocks.count, 1); XCTAssertEqual(model.blocks[0].kind, .paragraph)
        XCTAssertTrue(model.blocks[0].text.isEmpty); XCTAssertTrue(model.selectedBlockIDs.isEmpty)
        XCTAssertEqual(model.editorFocusRequest?.blockID, model.blocks[0].id)
    }

    func testBoundaryNavigationAndShiftExtend() async throws {
        let (_, _, model, original) = try await fixture()
        model.activeEditingBlockID = original[1].id
        model.jumpToDocumentBoundary(atStart: false, extend: true)
        XCTAssertEqual(model.selectedBlockIDs, Set(original[1...4].map(\.id)))
        model.jumpToDocumentBoundary(atStart: true)
        XCTAssertTrue(model.documentBoundaryRequest?.atStart == true)
        XCTAssertEqual(model.editorFocusRequest?.blockID, original[0].id)
        XCTAssertEqual(model.editorFocusRequest?.offset, 0)
        model.jumpToDocumentBoundary(atStart: false)
        XCTAssertEqual(model.editorFocusRequest?.blockID, original[4].id)
        XCTAssertEqual(model.editorFocusRequest?.offset, model.blocks.last?.text.utf16.count)
    }

    func testFormattingPersistsAcrossSaveReloadAndJSON() async throws {
        let (directory, store, model, original) = try await fixture()
        var style = InlineTextStyle(); style.bold = true; style.italic = true; style.color = "D93D3D"; style.fontSize = 24; style.fontFamily = "Menlo"
        let runs = [TextStyleRun(location: 1, length: 2, style: style)]
        model.changeRichText("A😀中文", formatting: runs, in: original[0]); await model.flushAll()
        XCTAssertFalse(model.saving)
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("store.sqlite"))
        let saved = try await reopened.blocks(in: original[0].pageID)
        XCTAssertEqual(saved.first?.formatting, runs); XCTAssertEqual(saved.first?.text, "A😀中文")
        let document = try await store.transferSnapshot(name: "格式")
        let data = try JSONEncoder().encode(document); let decoded = try JSONDecoder().decode(TransferDocument.self, from: data)
        XCTAssertEqual(decoded.pages[0].blocks[0].formatting, runs)
        XCTAssertTrue(HTMLTransfer.page(decoded.pages[0]).contains("<strong>"))
        XCTAssertTrue(HTMLTransfer.page(decoded.pages[0]).contains("color:#D93D3D"))
        XCTAssertTrue(try DocumentExporter.markdown(decoded.pages[0], assetDirectory: directory.appendingPathComponent("assets")).contains("***😀***"))
    }

    func testSelectedRangeFormattingDoesNotChangeUnselectedText() {
        let base = NSFont.systemFont(ofSize: 17)
        var callbackRuns: [TextStyleRun] = []
        let editor = NativeTextEditor(text: "one two three", font: base, onRichChange: { _, runs in callbackRuns = runs }, onChange: { _ in })
        let coordinator = NativeTextEditor.Coordinator(parent: editor)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100)); view.delegate = coordinator
        view.textStorage?.setAttributedString(RichTextFormatting.attributed(editor.text, runs: [], base: base))
        view.setSelectedRange(NSRange(location: 4, length: 3))
        coordinator.applyFormat(.bold, to: view); coordinator.applyFormat(.italic, to: view)
        coordinator.applyFormat(.size(24), to: view); coordinator.applyFormat(.color("2563EB"), to: view)
        XCTAssertEqual(view.string, "one two three")
        let runs = RichTextFormatting.runs(view.attributedString(), base: base)
        XCTAssertEqual(runs.count, 1); XCTAssertEqual(runs[0].location, 4); XCTAssertEqual(runs[0].length, 3)
        XCTAssertEqual(runs[0].style.bold, true); XCTAssertEqual(runs[0].style.italic, true)
        XCTAssertEqual(runs[0].style.color, "2563EB"); XCTAssertEqual(runs[0].style.fontSize, 24)
        XCTAssertFalse(callbackRuns.isEmpty)
        coordinator.applyFormat(.clear, to: view)
        XCTAssertTrue(RichTextFormatting.runs(view.attributedString(), base: base).isEmpty)
    }

    func testMarkdownInlineStylesAndInvalidRanges() throws {
        let document = try DocumentTransfer.markdown("# 标题\n\n这是 **加粗** 与 *斜体* 和 ~~删除线~~。", title: "文件")
        let block = try XCTUnwrap(document.pages[0].blocks.first)
        XCTAssertEqual(block.text, "这是 加粗 与 斜体 和 删除线。")
        XCTAssertTrue(block.formatting.contains { $0.style.bold == true })
        XCTAssertTrue(block.formatting.contains { $0.style.italic == true })
        XCTAssertTrue(block.formatting.contains { $0.style.strikethrough })
        XCTAssertNil(TextStyleRun(location: Int.max, length: 2, style: InlineTextStyle()).validRange(in: "text"))
        let legacy = Data(#"{"kind":"paragraph","text":"旧文件"}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(TransferBlock.self, from: legacy).formatting.isEmpty)
    }
}
