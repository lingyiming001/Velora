import AppKit
import Combine
import AVKit
import XCTest
import WebKit
import SwiftUI
@testable import Velora

@MainActor
final class EditorInteractionTests: XCTestCase {
    func testMCPTokenUsesPrivateFileAndRemainsStableUntilRotated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("mcp-token")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try MCPTokenStore.loadOrCreate(at: url)
        XCTAssertEqual(first.count, 72)
        XCTAssertEqual(try MCPTokenStore.loadOrCreate(at: url), first)
        let permissions = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        let rotated = try MCPTokenStore.rotate(at: url)
        XCTAssertNotEqual(rotated, first)
        XCTAssertEqual(try MCPTokenStore.loadOrCreate(at: url), rotated)
    }

    func testLongDocumentTitleCanSelectCopyWithoutBodySelectionStealingFocus() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "正文内容")
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let title = "《批判性思维工具》— Richard Paul / Linda Elder：" + String(repeating: "完整长标题复制验证", count: 9)
        model.renameSelectedPage(title)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var titleField: NSTextField?
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            titleField = window.contentView.flatMap { descendants($0).compactMap { $0 as? NSTextField }.first { $0.stringValue == title } }
            if titleField != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let field = try XCTUnwrap(titleField)
        model.selectAllBlocks()
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(5)) }
        field.selectText(nil)
        for _ in 0..<100 where !model.selectedBlockIDs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.selectedBlockIDs.isEmpty)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        XCTAssertFalse(DocumentSelectionView.copySelection(in: window))
        editor.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), title)
        XCTAssertNil(ClipboardDocument.blocks(from: .general))
        XCTAssertEqual(model.selectedPage?.title, title)
        XCTAssertGreaterThan(field.frame.height, 50, "Long title should wrap instead of clipping its ending")
        // Native field editors retain copy ownership even if a block selection
        // update has not yet reached SwiftUI's focus-state callback.
        let owner = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? DocumentSelectionView }.first })
        owner.selectionActive = true
        var bodyCopies = 0; owner.copy = { bodyCopies += 1 }
        XCTAssertFalse(DocumentSelectionView.copySelection(in: window))
        XCTAssertEqual(bodyCopies, 0)
        owner.selectionActive = false
        XCTAssertTrue(ClipboardDocument.copyTitle(title))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), title)
    }

    func testRawPythonCodeButtonPasteKeepsNativeCodeLinesAndLanguage() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "")
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let source = "from dotenv import load_dotenv\nfrom langchain_openai import ChatOpenAI\n\nload_dotenv()\nmodel = ChatOpenAI(\n    model=\"gpt-4o-mini\",\n    temperature=0\n)\nprint(model)"
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let editor = try XCTUnwrap(window.contentView.flatMap { descendants($0).compactMap { $0 as? CodeTextView }.first { $0.string.isEmpty } })
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string)
        editor.paste(nil)
        for _ in 0..<200 where model.blocks.first?.kind != .code { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.blocks[0].kind, .code)
        XCTAssertEqual(model.blocks[0].language.lowercased(), "python")
        XCTAssertEqual(model.blocks[0].text, source)
        await model.flushAll()
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await store.blocks(in: XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(saved[0].text, source)
        XCTAssertEqual(saved[0].language.lowercased(), "python")
    }

    func testImageTextCardPasteIsCompactEditableAndPersistsNativeLayout() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "")
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 160, height: 90))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 160, height: 90).fill()
        ("LangChain" as NSString).draw(at: NSPoint(x: 12, y: 30), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.systemTeal]); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))!
        let source = "data:image/png;base64," + bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
        let html = "<p>这是初学者经常混淆的三个概念。</p><div><img src='" + source + "'/><div><p><strong>LangChain</strong></p><p>主要用于构建 LLM 应用和 Agent，提供模型、工具、Middleware 等开发接口。</p><p>关键词：应用开发、模型集成、Agent</p></div></div>"
        model.pasteDocument(plain: nil, html: html, original: "", formatting: [], selection: NSRange(location: 0, length: 0), in: try XCTUnwrap(model.blocks.first))
        for _ in 0..<200 where model.blocks.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.map(\.kind), [.paragraph, .imageCard])
        let card = try XCTUnwrap(ImageTextCard.decode(model.blocks[1].text))
        XCTAssertEqual(card.title, "LangChain"); XCTAssertTrue(card.image.hasPrefix("data:"))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for _ in 0..<100 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(5)) }
        let root = try XCTUnwrap(window.contentView)
        let fields = descendants(root).compactMap { $0 as? NSTextField }
        XCTAssertTrue(fields.contains { $0.stringValue == "LangChain" })
        let titleField = try XCTUnwrap(fields.first { $0.stringValue == "LangChain" })
        let keyword = try XCTUnwrap(fields.first { $0.stringValue.contains("关键词：") })
        XCTAssertLessThan(abs(titleField.convert(titleField.bounds, to: root).midY - keyword.convert(keyword.bounds, to: root).midY), 140)
        let screenshot = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: screenshot)
        try screenshot.representation(using: .png, properties: [:])?.write(to: directory.deletingLastPathComponent().appendingPathComponent("image-text-card-native.png"))
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(ImageTextCard.decode(saved[1].text), card)
    }

    func testMCPStructuredAppendAndFileImportPreserveExistingBlocks() async throws {
        let (directory, store, model, original) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageID = original[0].pageID
        model.changeText("尚未保存的正文", in: model.blocks[0])
        let output = try await model.executeTool("append_document", arguments: ["page_id": pageID.uuidString, "format": "markdown", "content": "## 新标题\n\n1. Token\n\n说明\n\n2. Prompt\n\n```swift\nlet value = 2\n```"]) as! [String: Any]
        XCTAssertEqual(output["appended_blocks"] as? Int, 5)
        var loaded = try await store.blocks(in: pageID)
        XCTAssertEqual(Array(loaded.prefix(original.count)).map(\.id), original.map(\.id))
        XCTAssertEqual(loaded[0].text, "尚未保存的正文")
        XCTAssertEqual(Array(loaded.suffix(5)).map(\.kind), [.heading2, .numbered, .paragraph, .numbered, .code])
        XCTAssertEqual(loaded[loaded.count - 2].listStart, 2)
        _ = try await model.executeTool("append_document", arguments: ["page_id": pageID.uuidString, "format": "html", "content": "<h2>来自网页</h2><p><strong>加粗</strong></p>"])
        loaded = try await store.blocks(in: pageID)
        XCTAssertTrue(loaded.last!.formatting.contains { $0.style.bold == true })
        let file = directory.appendingPathComponent("import.md")
        try "### 文件标题\n\n文件正文".write(to: file, atomically: true, encoding: .utf8)
        _ = try await model.executeTool("import_file", arguments: ["page_id": pageID.uuidString, "path": file.path])
        loaded = try await store.blocks(in: pageID)
        XCTAssertEqual(loaded.last?.text, "文件正文")
        _ = try await model.executeTool("import_document", arguments: ["title": "外部新页", "format": "text", "content": "# 原样文字"])
        let imported = try await store.pages().first { $0.title == "外部新页" }
        XCTAssertNotNil(imported)
        let newBlocks = try await store.blocks(in: imported!.id)
        XCTAssertEqual(newBlocks.first?.kind, .paragraph)
        XCTAssertEqual(newBlocks.first?.text, "# 原样文字")
        let before = loaded
        do { _ = try await model.executeTool("append_document", arguments: ["page_id": pageID.uuidString, "format": "bad", "content": "无效"]); XCTFail("Must reject") } catch { }
        let after = try await store.blocks(in: pageID)
        XCTAssertEqual(before, after)
    }

    func testMCPHTTPAndStdioClientsCanAppendAndReadBack() async throws {
        let (directory, store, model, original) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "Velora-MCP-Test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "mcpEnabled"); defaults.set(false, forKey: "mcpAllowWrites")
        let port = UInt16.random(in: 30000...50000), token = UUID().uuidString
        let server = try LocalMCPServer(port: port, token: token, model: model, defaults: defaults)
        var ready = false
        server.onStatus = { if $0.contains("127.0.0.1") { ready = true } }
        server.start(); defer { server.stop() }
        for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ready)
        func request(_ method: String, _ params: [String: Any] = [:], bearer: String? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.setValue("Bearer " + (bearer ?? token), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }
        let unauthorized = try await request("tools/list", bearer: "wrong")
        XCTAssertEqual(unauthorized.0, 401)
        let initialization = try await request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        XCTAssertEqual(initialization.0, 200)
        let readOnly = try await request("tools/list")
        let tools = (readOnly.1["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["list_pages", "read_page"])
        let arguments = ["page_id": original[0].pageID.uuidString, "format": "markdown", "content": "## HTTP写入\n\n正文"]
        let denied = try await request("tools/call", ["name": "append_document", "arguments": arguments])
        XCTAssertEqual((denied.1["result"] as? [String: Any])?["isError"] as? Bool, true)
        let unchanged = try await store.blocks(in: original[0].pageID)
        XCTAssertEqual(unchanged.count, original.count)
        defaults.set(true, forKey: "mcpAllowWrites")
        let appended = try await request("tools/call", ["name": "append_document", "arguments": arguments])
        XCTAssertEqual((appended.1["result"] as? [String: Any])?["isError"] as? Bool, false)
        let process = Process(), input = Pipe(), output = Pipe()
        let bridge = try XCTUnwrap(Bundle.main.url(forResource: "velora_mcp_bridge", withExtension: "py"))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", bridge.path]
        var environment = ProcessInfo.processInfo.environment
        environment["VELORA_MCP_TOKEN"] = token; environment["VELORA_MCP_PORT"] = String(port)
        process.environment = environment; process.standardInput = input; process.standardOutput = output
        try process.run()
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "stdio-test", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "append_document", "arguments": ["page_id": original[0].pageID.uuidString, "content": "stdio 导入正文", "format": "text"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "read_page", "arguments": ["page_id": original[0].pageID.uuidString]]]
        ]
        for message in messages {
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message)); input.fileHandleForWriting.write(Data([10]))
        }
        try input.fileHandleForWriting.close()
        let bytes = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let replies = try String(decoding: bytes, as: UTF8.self).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(replies.count, 3)
        XCTAssertTrue(replies.allSatisfy { $0["error"] == nil })
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(token))
        let loaded = try await store.blocks(in: original[0].pageID)
        XCTAssertEqual(loaded.last?.text, "stdio 导入正文")
        XCTAssertEqual(loaded.count, original.count + 3)
    }

    func testMultiBlockCopyAndCutWinOverStaleNativeTextSelection() async throws {
        let (directory, _, model, original) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        let owner = DocumentSelectionView(frame: .zero)
        let text = CodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        root.addSubview(owner); root.addSubview(text)
        owner.copy = model.copySelectedBlocks
        var deleted = 0; owner.delete = { deleted += 1 }
        model.selectBlock(original[0].id)
        model.selectBlock(original[4].id, extend: true)
        owner.selectionActive = true
        text.string = "这里只选中一小段"
        text.setSelectedRange(NSRange(location: 0, length: 2))
        window.makeFirstResponder(text)
        text.copy(nil)
        let copied = try XCTUnwrap(ClipboardDocument.blocks(from: .general))
        XCTAssertEqual(copied.count, 5)
        XCTAssertEqual(copied.map(\.kind), original.map(\.kind))
        XCTAssertEqual(copied.map(\.text), model.blocks.map(\.text))
        let pasted = ClipboardDocument.inserting(copied, into: "", formatting: [], selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(pasted, copied, "Pasting must retain every copied block")
        let separate = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        separate.isReleasedWhenClosed = false
        XCTAssertFalse(DocumentSelectionView.copySelection(in: separate), "Selection cannot leak to another window")
        separate.close()
        text.cut(nil)
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(ClipboardDocument.blocks(from: .general)?.count, 5)
        XCTAssertEqual(text.string, "这里只选中一小段")
        // Ordinary native selection must still copy normally after clearing blocks.
        owner.selectionActive = false
        text.copy(nil)
        XCTAssertNil(ClipboardDocument.blocks(from: .general))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "这里")
    }

    func testDockReopenRaisesHiddenWorkspaceWithoutCreatingAnotherWindow() {
        let delegate = VeloraApplicationDelegate()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var opened = 0
        delegate.openWorkspaceWindow = { opened += 1 }
        delegate.registerWorkspaceWindow(window)
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(opened, 0)
        window.miniaturize(nil)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(opened, 0)
    }

    func testDockReopenAfterWorkspaceCloseRequestsSceneOnlyOnce() {
        let delegate = VeloraApplicationDelegate()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        delegate.registerWorkspaceWindow(window)
        window.close()
        XCTAssertNil(delegate.workspaceWindow)
        var opened = 0
        delegate.openWorkspaceWindow = { opened += 1 }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertEqual(opened, 1, "A settings window must not prevent reopening the workspace or cause duplicate scenes")
        delegate.registerWorkspaceWindow(window)
        XCTAssertFalse(delegate.reopening)
    }

    func testTextUndoIsIsolatedBetweenBlocksAndSurvivesClearingAnotherEditor() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let first = CodeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let second = CodeTextView(frame: NSRect(x: 0, y: 120, width: 200, height: 100))
        first.allowsUndo = true; second.allowsUndo = true
        host.addSubview(first); host.addSubview(second); window.contentView = host
        let firstUndo = try XCTUnwrap(first.undoManager)
        let secondUndo = try XCTUnwrap(second.undoManager)
        XCTAssertFalse(firstUndo === secondUndo)
        XCTAssertFalse(firstUndo === window.undoManager)
        first.insertText("第一块", replacementRange: NSRange(location: 0, length: 0))
        first.breakUndoCoalescing()
        second.insertText("第二块", replacementRange: NSRange(location: 0, length: 0))
        second.breakUndoCoalescing()
        XCTAssertTrue(firstUndo.canUndo); XCTAssertTrue(secondUndo.canUndo)
        first.clearEditingUndoHistory(); first.removeFromSuperview()
        XCTAssertFalse(firstUndo.canUndo)
        secondUndo.undo()
        XCTAssertEqual(second.string, "")
        XCTAssertEqual(first.string, "第一块")
        secondUndo.redo()
        XCTAssertEqual(second.string, "第二块")
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(second))
        // Test hosts cannot reliably acquire NSApp.keyWindow. Dispatch the same
        // menu selectors to the known responder instead of depending on global focus.
        XCTAssertTrue(NSApp.sendAction(Selector(("undo:")), to: second, from: nil))
        XCTAssertEqual(second.string, "", "The editor's undo action must use its own manager")
        XCTAssertTrue(NSApp.sendAction(Selector(("redo:")), to: second, from: nil))
        XCTAssertEqual(second.string, "第二块")
        let item = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        XCTAssertTrue(second.validateUserInterfaceItem(item))
        second.isEditable = false
        XCTAssertFalse(second.validateUserInterfaceItem(item))
        second.undo(nil)
        XCTAssertEqual(second.string, "第二块")
    }

    func testDismantledNativeEditorClearsUndoAndRedoTargets() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? CodeTextView)
        editor.insertText("撤销测试", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.breakUndoCoalescing()
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let native = NativeTextEditor(text: editor.string, font: .systemFont(ofSize: 16), onChange: { _ in })
        NativeTextEditor.dismantleNSView(scroll, coordinator: native.makeCoordinator())
        XCTAssertFalse(undo.canUndo); XCTAssertFalse(undo.canRedo)
        undo.undo(); undo.redo()
        await model.flushAll()
    }

    func testExternalTextReplacementInvalidatesNativeUndoRanges() throws {
        let font = NSFont.systemFont(ofSize: 16)
        let native = NativeTextEditor(text: "", font: font, onChange: { _ in })
        let coordinator = native.makeCoordinator()
        coordinator.lastBaseFont = font
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.allowsUndo = true; view.font = font
        view.insertText("很长的旧内容😀", replacementRange: NSRange(location: 0, length: 0))
        view.breakUndoCoalescing()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        let undo = try XCTUnwrap(view.undoManager)
        XCTAssertTrue(undo.canUndo)
        coordinator.parent.text = view.string
        coordinator.synchronize(view)
        XCTAssertTrue(undo.canUndo, "A native-edit acknowledgement must preserve undo")
        coordinator.parent.text = "短"
        coordinator.parent.contentRevision += 1
        coordinator.synchronize(view)
        XCTAssertEqual(view.string, "短")
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        undo.undo()
        XCTAssertEqual(view.string, "短")
    }

    override func record(_ issue: XCTIssue) {
        FileHandle.standardError.write(Data(("EDITOR TEST ISSUE: " + issue.compactDescription + "\n").utf8))
        super.record(issue)
    }

    func testGutterIndexTracksUnicodeEmptyAndEditedCode() {
        let view = CodeTextView(frame: .zero)
        view.updateGutterIndex()
        XCTAssertEqual(view.gutterLineStarts, [0])
        view.string = "中文😀\nlet x = 1\n"
        view.updateGutterIndex()
        XCTAssertEqual(view.gutterLineStarts, [0, 5, 15])
        view.string = "short"
        view.updateGutterIndex()
        XCTAssertEqual(view.gutterLineStarts, [0])
        view.string = "a\r\nb"
        view.updateGutterIndex()
        XCTAssertEqual(view.gutterLineStarts, [0, 3])
    }

    func testSidebarSelectionKeepsNativeSelectionWithQuietCustomHighlight() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/SidebarFocus-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = ApplicationServices(catalogURL: directory.appendingPathComponent("catalog.json"),
            legacyDatabaseURL: directory.appendingPathComponent("fixture.sqlite"), startBackgroundServices: false)
        let store = try XCTUnwrap(services.store), model = try XCTUnwrap(services.model)
        let first = try await store.createPage(), second = try await store.createPage()
        try await store.renamePage(first.id, title: "当前文档")
        try await store.renamePage(second.id, title: "其他文档")
        await model.refreshPages(); model.select(first.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WorkspaceView(services: services, model: model))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.selectionHighlightStyle, .none)
        XCTAssertEqual(table.numberOfSelectedRows, 1)
        model.select(second.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.selectedPageID, second.id)
        XCTAssertEqual(table.numberOfSelectedRows, 1)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = directory.deletingLastPathComponent().appendingPathComponent("sidebar-current-document.png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        await model.flushAll()
    }

    func testSettingsAndMovePanelIsolatedLayout() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/SidebarSettings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let services = ApplicationServices(catalogURL: directory.appendingPathComponent("catalog.json"),
            legacyDatabaseURL: directory.appendingPathComponent("fixture.sqlite"), startBackgroundServices: false)
        let model = try XCTUnwrap(services.model)
        let store = try XCTUnwrap(services.store)
        _ = try await store.createPage()
        let folder = try await store.createPage()
        _ = try await store.createPage(parentID: folder.id)
        await model.refreshPages()
        let page = try XCTUnwrap(model.pages.first)
        func capture<V: View>(_ view: V, size: NSSize, name: String) async throws {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            let content = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let output = directory.deletingLastPathComponent().appendingPathComponent(name)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)

        }
        try await capture(SettingsView(services: services), size: NSSize(width: 920, height: 680), name: "settings-polish.png")
        try await capture(MovePagePanel(model: model, services: services, page: page), size: NSSize(width: 548, height: 598), name: "move-polish.png")
        var recoveryCatalog = try XCTUnwrap(services.catalog)
        recoveryCatalog.workspaces[0].databasePath = directory.appendingPathComponent("deleted/velora.sqlite").path
        let recoveryURL = directory.appendingPathComponent("recovery.json")
        try recoveryCatalog.save(to: recoveryURL)
        let recovery = ApplicationServices(catalogURL: recoveryURL, startBackgroundServices: false)
        XCTAssertTrue(recovery.canCreateStartupWorkspace)
        try await capture(StartupRecoveryView(services: recovery), size: NSSize(width: 900, height: 650), name: "startup-recovery.png")
        await model.flushAll()
    }

    func testHeadingReturnSplitsIntoBodyAndPreservesImmediateTypingAndUnicode() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close() }
        let original = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.heading, in: original, text: "标题😀后半段")
        await model.flushAll()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var editor: CodeTextView?
        for _ in 0..<200 {
            editor = window.contentView.flatMap { descendants($0).compactMap { $0 as? CodeTextView }.first { $0.string == "标题😀后半段" } }
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let text = try XCTUnwrap(editor)
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 4, length: 0))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        text.keyDown(with: enter)
        XCTAssertEqual(model.blocks[0].kind, .heading)
        XCTAssertEqual(model.blocks[0].text, "标题😀")
        XCTAssertEqual(model.blocks[1].kind, .paragraph)
        XCTAssertEqual(model.blocks[1].text, "后半段")
        let body = model.blocks[1]
        model.changeText("立即输入后半段", in: body)
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: original.pageID)
        XCTAssertEqual(saved[0].text, "标题😀")
        XCTAssertEqual(saved[1].text, "立即输入后半段")
        XCTAssertEqual(saved[1].kind, .paragraph)
        XCTAssertEqual(model.editorFocusRequest?.blockID, body.id)
    }

    func testReturnAtStartOfHeadingInsertsParagraphBeforeAndPreservesHeading() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close() }
        let original = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.heading, in: original, text: "核心解决思想")
        await model.flushAll()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var editor: CodeTextView?
        for _ in 0..<200 {
            editor = window.contentView.flatMap { descendants($0).compactMap { $0 as? CodeTextView }.first { $0.string == "核心解决思想" } }
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let text = try XCTUnwrap(editor)
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        text.keyDown(with: enter)
        XCTAssertEqual(model.blocks.map(\.kind), [.paragraph, .heading])
        XCTAssertEqual(model.blocks.map(\.text), ["", "核心解决思想"])
        XCTAssertEqual(model.editorFocusRequest?.blockID, model.blocks[0].id)
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: original.pageID)
        XCTAssertEqual(saved.map(\.kind), [.paragraph, .heading])
        XCTAssertEqual(saved.map(\.text), ["", "核心解决思想"])
    }

    func testBackspaceAtParagraphStartJoinsBlocksAndPlacesCaretAtJoin() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "上一段😀")
        defer { window.close() }
        let first = try XCTUnwrap(model.blocks.first)
        model.addBlock(after: first, text: "标准答案：")
        for _ in 0..<200 where model.blocks.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let second = try XCTUnwrap(model.blocks.last)
        var bold = InlineTextStyle(); bold.bold = true
        model.changeRichText(second.text, formatting: [TextStyleRun(location: 0, length: second.text.utf16.count, style: bold)], in: second)
        var editor: CodeTextView?
        for _ in 0..<200 {
            editor = window.firstResponder as? CodeTextView
            if editor?.string == "标准答案：" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let target = try XCTUnwrap(editor)
        target.setSelectedRange(NSRange(location: 0, length: 0))
        let backspace = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        target.keyDown(with: backspace)
        XCTAssertEqual(model.blocks.map(\.text), ["上一段😀标准答案："])
        XCTAssertEqual(model.editorFocusRequest?.blockID, first.id)
        XCTAssertEqual(model.editorFocusRequest?.offset, first.text.utf16.count)
        for _ in 0..<200 {
            editor = window.firstResponder as? CodeTextView
            if editor?.string == "上一段😀标准答案：" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let joined = try XCTUnwrap(editor)
        XCTAssertEqual(joined.selectedRange(), NSRange(location: first.text.utf16.count, length: 0))
        joined.insertText("连接处", replacementRange: joined.selectedRange())
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: first.pageID)
        XCTAssertEqual(saved.map(\.text), ["上一段😀连接处标准答案："])
        XCTAssertEqual(saved.first?.id, first.id)
        XCTAssertTrue(saved.first?.formatting.contains { $0.style.bold == true } == true)
    }

    func testBackspaceUnwrapsListBeforeJoiningAndKeepsMediaBoundary() async throws {
        let (_, _, model, original) = try await fixture()
        for kind in [BlockKind.bullet, .numbered, .todo, .quote, .callout, .toggle, .heading] {
            let block = try XCTUnwrap(model.blocks.first)
            var style = InlineTextStyle(); style.italic = true
            model.insertSlashCommand(kind, in: block, text: "保留内容", formatting: [TextStyleRun(location: 0, length: 4, style: style)])
            XCTAssertTrue(model.backspaceAtStart(of: try XCTUnwrap(model.blocks.first)), kind.rawValue)
            XCTAssertEqual(model.blocks.first?.kind, .paragraph, kind.rawValue)
            XCTAssertEqual(model.blocks.first?.text, "保留内容", kind.rawValue)
            XCTAssertEqual(model.blocks.first?.formatting.first?.style.italic, true, kind.rawValue)
        }
        let last = try XCTUnwrap(model.blocks.last)
        XCTAssertTrue(model.backspaceAtStart(of: last))
        XCTAssertEqual(model.selectedBlockIDs, [original[3].id])
        XCTAssertEqual(model.blocks.last?.text, last.text)
        await model.flushAll()
    }

    func testBackspaceInsideParagraphDeletesCharactersSelectionsAndLineBreaks() async throws {
        let (window, model, _) = try await slashPopupFixture(command: "前😀后\n下一行")
        defer { window.close() }
        let editor = try XCTUnwrap(window.firstResponder as? CodeTextView)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.keyDown(with: event)
        XCTAssertEqual(editor.string, "前后\n下一行")
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        editor.keyDown(with: event)
        XCTAssertEqual(editor.string, "\n下一行")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.keyDown(with: event)
        XCTAssertEqual(model.blocks.map(\.text), ["下一行"])
        await model.flushAll()
    }

    func testRapidBackspaceJoinsPendingParagraphEditsWithoutDuplicatingText() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/BackspaceJoin-" + UUID().uuidString)
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let page = try await store.createPage()
        for _ in 0..<3 { _ = try await store.createBlock(pageID: page.id, kind: .paragraph) }
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<200 where model.blocks.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        let original = model.blocks
        for (index, block) in original.enumerated() { model.changeText("段\(index)😀", in: block) }
        XCTAssertTrue(model.backspaceAtStart(of: original[1]))
        XCTAssertTrue(model.backspaceAtStart(of: original[2]))
        model.changeText(model.blocks[0].text + "立即输入", in: model.blocks[0])
        await model.flushAll()
        let saved = try await store.blocks(in: page.id)
        XCTAssertEqual(saved.map(\.text), ["段0😀段1😀段2😀立即输入"])
        XCTAssertEqual(saved.first?.id, original[0].id)
        XCTAssertFalse(model.saving)
        XCTAssertNil(model.errorMessage)
    }

    func testFailedBackspaceMergeRestoresBothUnsavedParagraphs() async throws {
        let (directory, store, model, original) = try await fixture()
        let first = original[0]
        // Make adjacent prose blocks in the model, then change persistent order
        // externally to exercise the atomic merge's refusal and rollback.
        model.insertSlashCommand(.paragraph, in: original[1], text: "第二段")
        await model.flushAll()
        let second = model.blocks[1]
        _ = try await store.createBlock(pageID: first.pageID, kind: .divider, after: first)
        model.changeText("第一段未保存", in: first)
        model.changeText("第二段未保存", in: second)
        XCTAssertTrue(model.backspaceAtStart(of: second))
        await model.flushAll()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.blocks.prefix(2).map(\.text), ["第一段未保存", "第二段未保存"])
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("store.sqlite"))
        let saved = try await reopened.blocks(in: first.pageID)
        XCTAssertEqual(saved.first(where: { $0.id == first.id })?.text, "第一段未保存")
        XCTAssertEqual(saved.first(where: { $0.id == second.id })?.text, "第二段未保存")
        XCTAssertEqual(saved.count, original.count + 1)
    }

    func testHostedParagraphShiftReturnSoftBreakAndReturnSplitsBlock() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "第一段")
        defer { window.close() }
        let text = try XCTUnwrap(window.firstResponder as? CodeTextView)
        func pressReturn(_ modifiers: NSEvent.ModifierFlags) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            text.keyDown(with: event)
        }
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        try pressReturn(.shift)
        XCTAssertEqual(model.blocks.map(\.text), ["第一段\n"])
        text.insertText("第二行", replacementRange: text.selectedRange())
        try pressReturn([])
        for _ in 0..<200 where (window.firstResponder as? CodeTextView) === text { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(model.blocks.map(\.text), ["第一段\n第二行", ""])
        let next = try XCTUnwrap(window.firstResponder as? CodeTextView)
        XCTAssertFalse(next === text)
        next.insertText("新段落", replacementRange: next.selectedRange())
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: try XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(saved.map(\.text), ["第一段\n第二行", "新段落"])
    }

    func testStyledParagraphReturnAtStartCreatesBlankBlockAndRetainsFormatting() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "标准答案：")
        defer { window.close() }
        let editor = try XCTUnwrap(window.firstResponder as? CodeTextView)
        editor.textStorage?.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 17),
                                        range: NSRange(location: 0, length: editor.string.utf16.count))
        editor.didChangeText()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: enter)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.blocks.map(\.text), ["", "标准答案："])
        XCTAssertEqual(model.editorFocusRequest?.blockID, model.blocks[1].id)
        XCTAssertEqual((window.firstResponder as? CodeTextView)?.selectedRange(), NSRange(location: 0, length: 0))
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: try XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(saved.map(\.text), ["", "标准答案："])
        XCTAssertTrue(saved.last?.formatting.contains { $0.style.bold == true } == true)
    }

    func testParagraphReturnSplitsUnicodeSelectionAndEmptyParagraph() async throws {
        let (_, store, model, _) = try await fixture()
        let block = model.blocks[0]
        let source = "中文😀待替换第二句。"
        var style = InlineTextStyle(); style.italic = true
        let runs = [TextStyleRun(location: 0, length: source.utf16.count, style: style)]
        model.changeRichText(source, formatting: runs, in: block)
        XCTAssertTrue(model.returnFromSingleLineBlock(block, text: source, formatting: runs,
            selection: (source as NSString).range(of: "待替换")))
        XCTAssertEqual(Array(model.blocks.prefix(2)).map(\.text), ["中文😀", "第二句。"])
        XCTAssertEqual(model.blocks[0].formatting.first?.length, "中文😀".utf16.count)
        XCTAssertEqual(model.blocks[1].formatting.first?.location, 0)
        let second = model.blocks[1]
        model.changeText("", in: second)
        XCTAssertTrue(model.returnFromSingleLineBlock(second, text: "", formatting: [], selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(Array(model.blocks.prefix(3)).map(\.text), ["中文😀", "", ""])
        XCTAssertEqual(model.editorFocusRequest?.blockID, model.blocks[2].id)
        await model.flushAll()
        let saved = try await store.blocks(in: block.pageID)
        XCTAssertEqual(saved.map(\.text), model.blocks.map(\.text))
    }

    func testSelectedBlockReturnContinuesAfterLastSelectedBlock() async throws {
        let (_, store, model, _) = try await fixture()
        let divider = try XCTUnwrap(model.blocks.first { $0.kind == .divider })
        model.selectBlock(divider.id)
        model.continueAfterSelectedBlocks()
        for _ in 0..<200 where model.blocks.count == 5 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.selectedBlockIDs.isEmpty)
        let index = try XCTUnwrap(model.blocks.firstIndex { $0.id == divider.id })
        XCTAssertEqual(model.blocks[index + 1].kind, .paragraph)
        XCTAssertEqual(model.editorFocusRequest?.blockID, model.blocks[index + 1].id)
        let saved = try await store.blocks(in: divider.pageID)
        XCTAssertEqual(saved.count, 6)
        let keyboard = DocumentSelectionView(frame: .zero)
        var inserted = false
        keyboard.insertAfter = { inserted = true }
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        keyboard.keyDown(with: enter)
        XCTAssertTrue(inserted)
    }

    func testReturnRoutingCoversEveryBlockKind() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/ReturnKinds-" + UUID().uuidString)
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let page = try await store.createPage()
        for kind in BlockKind.allCases {
            let block = try await store.createBlock(pageID: page.id, kind: kind)
            try await store.updateBlock(block.id, text: kind == .table ? kind.initialText : "内容")
        }
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<200 where model.blocks.count != BlockKind.allCases.count { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.count, BlockKind.allCases.count)
        let original = model.blocks
        let splitKinds: Set<BlockKind> = [.paragraph, .heading, .heading2, .heading3, .bullet, .numbered, .todo]
        let mediaKinds: Set<BlockKind> = [.image, .video, .audio, .file, .bookmark]
        for block in original {
            let expected = splitKinds.contains(block.kind) || mediaKinds.contains(block.kind)
            let handled = model.returnFromSingleLineBlock(block, text: block.text, formatting: [],
                selection: NSRange(location: block.text.utf16.count, length: 0))
            XCTAssertEqual(handled, expected, block.kind.rawValue)
        }
        await model.flushAll()
    }

    func testTableCellReturnInsertsNewlineInsteadOfLeavingCell() async throws {
        let (window, model, _) = try await slashPopupFixture()
        defer { window.close() }
        let command = try XCTUnwrap(window.firstResponder as? NSTextView)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        command.keyDown(with: enter)
        for _ in 0..<200 where model.blocks.first?.kind != .table { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<200 {
            if let responder = window.firstResponder as? NSTextView, responder !== command { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let cell = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(cell === command)
        cell.insertText("第一行", replacementRange: cell.selectedRange())
        cell.keyDown(with: enter)
        cell.insertText("第二行", replacementRange: cell.selectedRange())
        await model.flushAll()
        let table = try XCTUnwrap(model.blocks.first)
        let rows = try JSONDecoder().decode([[String]].self, from: Data(table.text.utf8))
        XCTAssertEqual(rows[0][0], "第一行\n第二行")
    }

    func testRichSourceStaysEditableAfterFirstCharacterAndReturn() async throws {
        for kind in [BlockKind.equation, .markdown] {
            let (window, model, _) = try await slashPopupFixture(command: "")
            let original = try XCTUnwrap(model.blocks.first)
            model.insertSlashCommand(kind, in: original)
            await model.flushAll()
            var editor: CodeTextView?
            for _ in 0..<200 {
                editor = window.firstResponder as? CodeTextView
                if editor?.window === window, editor?.textContainerInset.width == 18 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let source = try XCTUnwrap(editor)
            source.insertText("x", replacementRange: source.selectedRange())
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertTrue(source.window === window, kind.rawValue)
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            source.keyDown(with: enter)
            source.insertText("y", replacementRange: source.selectedRange())
            XCTAssertEqual(model.blocks.first?.text, "x\ny", kind.rawValue)
            await model.flushAll()
            window.close()
        }
    }

    func testQuoteCalloutAndToggleReturnOnEmptyLineExitsAfterMultilineInput() async throws {
        let (window, model, _) = try await slashPopupFixture(command: "")
        defer { window.close() }
        for kind in [BlockKind.quote, .callout, .warning, .success, .toggle] {
            let original = try XCTUnwrap(model.blocks.first)
            model.insertSlashCommand(kind, in: original, text: "首行")
            await model.flushAll()
            var editor: CodeTextView?
            for _ in 0..<200 {
                editor = window.firstResponder as? CodeTextView
                if editor != nil, editor?.string == "首行" { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let source = try XCTUnwrap(editor)
            source.setSelectedRange(NSRange(location: source.string.utf16.count, length: 0))
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            source.keyDown(with: enter)
            XCTAssertEqual(model.blocks.first?.text, "首行\n", kind.rawValue)
            source.keyDown(with: enter)
            for _ in 0..<200 where (window.firstResponder as? CodeTextView) === source {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(model.blocks.first?.text, "首行", kind.rawValue)
            XCTAssertEqual(model.blocks[1].kind, .paragraph)
            XCTAssertEqual((window.firstResponder as? CodeTextView)?.string, "")
        }
        await model.flushAll()
    }

    func testMultilineProseEmptyLineReturnExitsWithoutLeavingTrailingNewline() async throws {
        let (_, store, model, _) = try await fixture()
        for kind in [BlockKind.quote, .callout, .warning, .success, .toggle] {
            let source = model.blocks[0]
            model.insertSlashCommand(kind, in: source, text: "首行😀\n")
            await model.flushAll()
            let current = model.blocks[0]
            // A cursor within the body and an active selection must not exit.
            XCTAssertFalse(model.returnFromSingleLineBlock(current, text: current.text, formatting: [], selection: NSRange(location: 1, length: 0)))
            XCTAssertFalse(model.returnFromSingleLineBlock(current, text: current.text, formatting: [], selection: NSRange(location: 0, length: 1)))
            let before = model.blocks.count
            XCTAssertTrue(model.returnFromSingleLineBlock(current, text: current.text, formatting: [], selection: NSRange(location: current.text.utf16.count, length: 0)))
            for _ in 0..<200 where model.blocks.count == before && model.blocks[1].kind != .paragraph { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(model.blocks[0].text, "首行😀", kind.rawValue)
            XCTAssertEqual(model.blocks[1].kind, .paragraph)
            XCTAssertEqual(model.editorFocusRequest?.blockID, model.blocks[1].id)
            let count = model.blocks.count
            // Reuse the existing blank body block on subsequent exits.
            XCTAssertTrue(model.returnFromSingleLineBlock(model.blocks[0], text: "", formatting: [], selection: NSRange(location: 0, length: 0)))
            XCTAssertEqual(model.blocks.count, count)
            await model.flushAll()
            let saved = try await store.blocks(in: current.pageID)
            XCTAssertEqual(saved.map(\.text), model.blocks.map(\.text))
        }
    }

    func testSingleLineBlockReturnRulesPreserveMultilineCodeAndExitEmptyList() async throws {
        let (_, _, model, _) = try await fixture()
        let code = try XCTUnwrap(model.blocks.first { $0.kind == .code })
        XCTAssertFalse(model.returnFromSingleLineBlock(code, text: code.text, formatting: [], selection: NSRange(location: 0, length: 0)))
        let original = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.bullet, in: original, text: "")
        await model.flushAll()
        XCTAssertTrue(model.returnFromSingleLineBlock(model.blocks[0], text: "", formatting: [], selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(model.blocks[0].kind, .paragraph)
        await model.flushAll()
    }

    func testMediaSourceAcceptsLocalAndNetworkAndRejectsUnsafeSchemes() {
        XCTAssertEqual(MediaSource.url(" /tmp/a b.mp4 ")?.path, "/tmp/a b.mp4")
        XCTAssertTrue(MediaSource.url("file:///tmp/a.wav")?.isFileURL == true)
        XCTAssertEqual(MediaSource.url("https://example.com/media.mp4")?.host, "example.com")
        for source in ["javascript:alert(1)", "data:text/html,hi", "https://user:password@example.com/a", "file://remote-host/a", "not a URL"] {
            XCTAssertNil(MediaSource.url(source), source)
        }
    }

    func testLocalAudioBlockBuildsPlayerAndKeepsWithinNarrowPage() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close() }
        let url = directory.appendingPathComponent("sample.wav")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
            buffer.frameLength = 800
            buffer.floatChannelData?[0].initialize(repeating: 0, count: 800)
            try file.write(from: buffer)
        }
        let original = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.audio, in: original, text: url.absoluteString)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var player: AVPlayerView?
        for _ in 0..<200 {
            player = window.contentView.flatMap { descendants($0).compactMap { $0 as? AVPlayerView }.first }
            if player?.player?.currentItem != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let view = try XCTUnwrap(player)
        XCTAssertEqual((view.player?.currentItem?.asset as? AVURLAsset)?.url, url)
        XCTAssertEqual(view.player?.rate, 0, "Inserting media must not autoplay")
        for _ in 0..<200 where view.player?.currentItem?.status == .unknown { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(view.player?.currentItem?.status, .readyToPlay)
        window.setContentSize(NSSize(width: 480, height: 700))
        try await Task.sleep(for: .milliseconds(100))
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let rect = view.convert(view.bounds, to: root)
        XCTAssertLessThanOrEqual(rect.maxX, root.bounds.maxX + 1)
        XCTAssertGreaterThanOrEqual(rect.minX, -1)
        await model.flushAll()
    }

    func testLongCodeRemainsWithinNarrowPageWidth() async throws {
        let (window, model, _) = try await slashPopupFixture()
        defer { window.close() }
        let original = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.code, in: original, text: String(repeating: "LongIdentifier", count: 100))
        window.setContentSize(NSSize(width: 480, height: 700))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var editor: CodeTextView?
        for _ in 0..<200 {
            editor = window.contentView.flatMap { descendants($0).compactMap { $0 as? CodeTextView }.first { $0.copySelectionAsText } }
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(editor?.enclosingScrollView)
        let rect = scroll.convert(scroll.bounds, to: root)
        XCTAssertLessThanOrEqual(rect.maxX, root.bounds.maxX + 1)
        XCTAssertGreaterThanOrEqual(rect.minX, -1)
        await model.flushAll()
    }

    func testWarningAndWideImageFitNarrowDocumentContent() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close() }
        window.setContentSize(NSSize(width: 480, height: 700))
        let block = try XCTUnwrap(model.blocks.first)
        let warning = String(repeating: "提示内容需要在页面内自动换行。", count: 8)
        model.insertSlashCommand(.warning, in: block, text: warning)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var text: CodeTextView?
        for _ in 0..<200 {
            text = window.contentView.flatMap { descendants($0).compactMap { $0 as? CodeTextView }.first { $0.string == warning } }
            if text != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(text?.enclosingScrollView)
        let rect = scroll.convert(scroll.bounds, to: root)
        XCTAssertLessThanOrEqual(rect.maxX, root.bounds.maxX - 32 + 1)
        XCTAssertGreaterThanOrEqual(rect.minX, 90)
        func capture(_ name: String) throws {
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.deletingLastPathComponent().appendingPathComponent(name))
        }
        try capture("warning-width.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2400, height: 240)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        model.insertSlashCommand(.image, in: block, text: try ImageSource.embedded(png))
        try await Task.sleep(for: .milliseconds(200))
        root.layoutSubtreeIfNeeded()
        try capture("image-width.png")
        await model.flushAll()
    }

    func testDragIndicatorPublishesOnlyChangesAndCleanupCannotEndNewSession() async throws {
        let state = PageDragState()
        let source = UUID(), target = UUID()
        state.begin(source, mouseIsDown: { true })
        var publications = 0
        let observation = state.objectWillChange.sink { publications += 1 }
        let indicator = PageDropIndicator(pageID: target, placement: .before)
        for _ in 0..<500 { state.indicator = indicator }
        XCTAssertEqual(publications, 1, "Hovering one drop zone must not rebuild the List for every event")
        state.finishAfterTracking()
        XCTAssertEqual(state.sourceID, source, "Drop callback must retain its row until native tracking returns")
        state.begin(target, mouseIsDown: { true })
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(state.sourceID, target, "Queued cleanup belongs to the previous drag session")
        state.finish()
        observation.cancel()
    }

    func testPageMoveWaitsForTrackingAndPreservesLiveEditorAndCache() async throws {
        let (_, store, model, _) = try await fixture()
        let first = try XCTUnwrap(model.selectedPage)
        let second = try await store.createPage()
        _ = try await store.createBlock(pageID: second.id, kind: .paragraph)
        await model.refreshPages()
        let originalIDs = model.blocks.map(\.id)
        model.changeText("拖动前尚未保存的正文", in: model.blocks[0])
        let originalOrder = model.pages.map(\.id)
        model.move(second, by: -1)
        func pumpNativeTracking() { _ = RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02)) }
        pumpNativeTracking()
        XCTAssertEqual(model.pages.map(\.id), originalOrder)
        for _ in 0..<300 where model.pages.first?.id != second.id || model.automationBusy {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.pages.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.selectedPageID, first.id)
        XCTAssertEqual(model.blocks.map(\.id), originalIDs)
        XCTAssertEqual(model.blocks.first?.text, "拖动前尚未保存的正文")
        let saved = try await store.blocks(in: first.id)
        XCTAssertEqual(saved.first?.text, model.blocks.first?.text)
        // Cache the selected page, then reorder while another page is open.
        model.select(second.id)
        for _ in 0..<200 where model.blocks.first?.pageID != second.id { try await Task.sleep(for: .milliseconds(5)) }
        model.move(first, by: -1)
        for _ in 0..<300 where model.pages.first?.id != first.id || model.automationBusy { try await Task.sleep(for: .milliseconds(5)) }
        model.select(first.id)
        XCTAssertEqual(model.blocks.map(\.id), originalIDs, "A structural reorder must keep visited-page cache")
        await model.flushAll()
    }

    func testCancelledPageDragClearsIndicatorAndDoesNotLeakIntoNextSession() async throws {
        let state = PageDragState()
        var pressed = true
        let first = UUID(), second = UUID()
        state.begin(first, mouseIsDown: { pressed })
        state.indicator = PageDropIndicator(pageID: second, placement: .before)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(state.sourceID, first)
        XCTAssertNotNil(state.indicator)
        pressed = false // release outside all destinations / cancel
        for _ in 0..<30 where state.sourceID != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(state.sourceID)
        XCTAssertNil(state.indicator)
        state.begin(second, mouseIsDown: { true })
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(state.sourceID, second)
        XCTAssertNil(state.indicator)
        state.finish()
        XCTAssertNil(state.sourceID)
    }

    func testCodeTextSelectionCopiesAsLiteralTextEvenWithMarkdownSyntax() throws {
        let board = NSPasteboard.general
        defer { board.clearContents() }
        let source = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        source.copySelectionAsText = true
        source.string = "before **literal**\n```swift\n    let x = 1\n``` after"
        source.setSelectedRange(NSRange(location: 7, length: source.string.utf16.count - 13))
        let expected = (source.string as NSString).substring(with: source.selectedRange())
        source.copy(nil)
        XCTAssertEqual(board.string(forType: .string), expected)
        XCTAssertNotNil(board.data(forType: ClipboardDocument.textSelectionType))
        XCTAssertNil(ClipboardDocument.blocks(from: board))
        let target = CodeTextView(frame: source.frame)
        target.string = "AB"; target.setSelectedRange(NSRange(location: 1, length: 0))
        var converted = false
        target.pasteDocument = { _, _, _, _ in converted = true; return true }
        target.paste(nil)
        XCTAssertFalse(converted, "A code selection must bypass Markdown/HTML guessing")
        XCTAssertEqual(target.string, "A" + expected + "B")
    }

    func testExternalSmallRTFPasteMatchesBodyFontAndSubsequentTyping() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "正文：")
        defer { window.close(); NSPasteboard.general.clearContents() }
        let editor = try XCTUnwrap(window.firstResponder as? CodeTextView)
        let base = try XCTUnwrap(editor.pasteBaseFont)
        let source = NSMutableAttributedString(string: "小号链接", attributes: [
            .font: NSFont(name: "Times New Roman", size: 8)!,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .link: URL(string: "https://example.com")!
        ])
        source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 8), range: NSRange(location: 0, length: 2))
        let rtf = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(rtf, forType: .rtf) // Rich-only clipboards must also work.
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.paste(nil)
        editor.insertText("继续", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "正文：小号链接继续")
        for offset in 3..<editor.string.utf16.count {
            let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, base.pointSize, accuracy: 0.1)
        }
        let runs = try XCTUnwrap(model.blocks.first?.formatting)
        // AppKit may record the system font's Chinese fallback family. The
        // foreign Times/Songti family and 8pt sizing must not survive the paste.
        XCTAssertFalse(runs.contains { $0.style.fontSize != nil || $0.style.fontFamily?.contains("Times") == true || $0.style.fontFamily?.contains("Songti") == true }, "\(runs)")
        XCTAssertTrue(runs.contains { $0.style.bold == true && $0.style.underline && $0.style.link == "https://example.com" })
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: try XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(saved.first?.formatting, runs)
    }

    func testExternalSmallHTMLPasteMatchesHeadingAndCodeTypography() async throws {
        let (window, model, _) = try await slashPopupFixture(command: "")
        defer { window.close(); NSPasteboard.general.clearContents() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for kind in [BlockKind.paragraph, .heading, .code] {
            model.insertSlashCommand(kind, in: try XCTUnwrap(model.blocks.first), text: "目标")
            await model.flushAll()
            var found: CodeTextView?
            for _ in 0..<200 {
                found = window.contentView.flatMap { descendants($0).compactMap { $0 as? CodeTextView }.first { $0.string == "目标" } }
                if let found, window.firstResponder === found { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let editor = try XCTUnwrap(found)
            let base = try XCTUnwrap(editor.pasteBaseFont)
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            NSPasteboard.general.clearContents()
            let pasted = kind == .code ? "  粘贴😀" : "粘贴😀"
            NSPasteboard.general.setString(pasted, forType: .string)
            NSPasteboard.general.setString("<span style=\"font-family:Times New Roman;font-size:8px\">\(pasted)</span>", forType: .html)
            editor.paste(nil)
            XCTAssertEqual(editor.string, pasted, kind.rawValue)
            let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, base.pointSize, accuracy: 0.1, kind.rawValue)
            if kind == .code { XCTAssertTrue(font.isFixedPitch) }
            if kind == .heading { XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask)) }
        }
        await model.flushAll()
    }

    func testInternalRichTextCopyAndCutKeepIntentionalFontSize() throws {
        defer { NSPasteboard.general.clearContents() }
        let source = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        source.isRichText = true
        source.textStorage?.setAttributedString(NSAttributedString(string: "自定义", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)]))
        source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
        for cut in [false, true] {
            if cut { source.cut(nil) } else { source.copy(nil) }
            let target = CodeTextView(frame: source.frame)
            target.isRichText = true
            target.font = .systemFont(ofSize: 17)
            var converted = false
            target.pasteDocument = { _, _, _, _ in converted = true; return true }
            target.paste(nil)
            XCTAssertFalse(converted, "An internal inline selection must not be reinterpreted as document blocks")
            XCTAssertEqual(target.string, "自定义")
            let font = try XCTUnwrap(target.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, 24)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        }
    }

    func testPasteAndMatchStyleDropsSourceSizesAndEmphasis() throws {
        defer { NSPasteboard.general.clearContents() }
        let source = NSAttributedString(string: "tiny", attributes: [.font: NSFont.boldSystemFont(ofSize: 8)])
        let rtf = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(rtf, forType: .rtf)
        let target = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        target.isRichText = true
        target.font = .systemFont(ofSize: 21)
        target.pasteAsPlainText(nil)
        XCTAssertEqual(target.string, "tiny")
        let font = try XCTUnwrap(target.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 21)
        XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    func testCopiedCodeBlockPastesWithLanguageAndExactWhitespaceAndSurroundingText() async throws {
        let (_, store, model, _) = try await fixture()
        let target = try XCTUnwrap(model.blocks.first)
        let code = TransferBlock(.code, "    let value = `raw`\n\n        // **literal**\n", language: "Swift")
        XCTAssertTrue(ClipboardDocument.copyBlocks([code]))
        defer { NSPasteboard.general.clearContents() }
        let blocks = try XCTUnwrap(ClipboardDocument.blocks(from: .general))
        XCTAssertEqual(blocks, [code])
        XCTAssertNil(NSPasteboard.general.data(forType: ClipboardDocument.textSelectionType))
        model.pasteDocument(plain: code.text, html: nil, original: target.text, formatting: [],
                            selection: NSRange(location: 1, length: 0), in: target, copiedBlocks: blocks)
        for _ in 0..<100 where model.blocks.first?.id == target.id { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Array(model.blocks.prefix(3).map(\.kind)), [.paragraph, .code, .paragraph])
        XCTAssertEqual(model.blocks[0].text, "内")
        XCTAssertEqual(model.blocks[1].text, code.text)
        XCTAssertEqual(model.blocks[1].language, "Swift")
        XCTAssertEqual(model.blocks[2].text, "容")
        let saved = try await store.blocks(in: target.pageID)
        XCTAssertEqual(saved[1].text, code.text)
        XCTAssertEqual(saved[1].language, "Swift")
    }

    func testDuplicatePageIncludesPendingEditsAndOpensIndependentCopy() async throws {
        let (_, store, model, _) = try await fixture()
        let source = try XCTUnwrap(model.selectedPage)
        let block = model.blocks[0]
        model.changeText("复制时尚未自动保存的正文😀", in: block)
        try await model.duplicatePage(source)
        let copyID = try XCTUnwrap(model.selectedPageID)
        XCTAssertNotEqual(copyID, source.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.first?.text, "复制时尚未自动保存的正文😀")
        XCTAssertNotEqual(model.blocks.first?.id, block.id)
        XCTAssertFalse(model.automationBusy)
        let saved = try await store.blocks(in: source.id)
        XCTAssertEqual(saved.first?.text, model.blocks.first?.text)
        let count = model.pages.count
        var stale = source
        stale = Page(id: UUID(), parentID: stale.parentID, title: stale.title, order: stale.order, archived: false, updatedAt: Date())
        do { try await model.duplicatePage(stale); XCTFail("Stale page must fail") } catch { }
        XCTAssertEqual(model.pages.count, count)
        XCTAssertFalse(model.automationBusy)
    }

    func testCreatePageImmediatelyProvidesCommittedInputAndRetainsPreviousPageCache() async throws {
        let (_, store, model, _) = try await fixture()
        let previousID = try XCTUnwrap(model.selectedPageID)
        let previousBlocks = model.blocks
        model.changeText("新建前尚未保存的正文", in: previousBlocks[0])
        model.createPage(parentID: previousID)
        for _ in 0..<200 where model.selectedPageID == previousID { try await Task.sleep(for: .milliseconds(5)) }
        let newID = try XCTUnwrap(model.selectedPageID)
        XCTAssertNotEqual(newID, previousID)
        XCTAssertEqual(model.selectedPage?.parentID, previousID)
        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.blocks[0].kind, .paragraph)
        XCTAssertEqual(model.editorFocusRequest?.blockID, model.blocks[0].id)
        let saved = try await store.blocks(in: newID)
        XCTAssertEqual(saved, model.blocks)
        model.select(previousID)
        XCTAssertEqual(model.blocks.map(\.id), previousBlocks.map(\.id), "New page creation must keep the previous page's immediate cache")
        XCTAssertEqual(model.blocks.first?.text, "新建前尚未保存的正文")
        await model.flushAll()
        let stored = try await store.blocks(in: previousID)
        XCTAssertEqual(stored.first?.text, "新建前尚未保存的正文")
    }

    func testSidebarTreeCacheReusesLargeHierarchyAndInvalidatesForRealInputs() throws {
        let suite = "Velora.SidebarCache." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SidebarExpansionState(workspaceID: "test", defaults: defaults)
        let root = Page(id: UUID(), title: "根页面", order: 0, archived: false, updatedAt: Date())
        var pages = [root]
        for index in 0..<2000 {
            pages.append(Page(id: UUID(), parentID: root.id, title: "页面 \(index)", order: Int64(index), archived: false, updatedAt: Date()))
        }
        var index = SidebarPageIndex(pages: pages)
        var revision = UUID()
        for _ in 0..<200 {
            let rows = state.visibleRows(index: index, revision: revision, filter: "")
            XCTAssertEqual(rows.count, 2001)
            XCTAssertEqual(rows.last?.page.id, pages.last?.id)
        }
        XCTAssertEqual(state.treeBuildCount, 1, "Editor and autosave updates must reuse the tree")
        state.collapsed = [root.id]
        XCTAssertEqual(state.visibleRows(index: index, revision: revision, filter: "").count, 1)
        XCTAssertEqual(state.treeBuildCount, 2)
        let filtered = state.visibleRows(index: index, revision: revision, filter: "页面 1999")
        XCTAssertEqual(filtered.map(\.page.id), [root.id, pages.last!.id])
        XCTAssertEqual(filtered.map(\.depth), [0, 1])
        XCTAssertEqual(state.treeBuildCount, 3)
        pages[pages.count - 1].archived = true
        index = SidebarPageIndex(pages: pages); revision = UUID()
        XCTAssertTrue(state.visibleRows(index: index, revision: revision, filter: "页面 1999").isEmpty)
        XCTAssertNil(index.children[pages.last!.id])
        XCTAssertEqual(state.treeBuildCount, 4)
    }

    func testSidebarIndexRevisionDoesNotChangeWhileTypingOrSwitchingPages() async throws {
        let (_, _, model, original) = try await fixture()
        let revision = model.sidebarPageRevision
        model.changeText("正文输入不应重建页面树", in: model.blocks[0])
        await model.flushAll()
        XCTAssertEqual(model.sidebarPageRevision, revision)
        XCTAssertNotNil(model.sidebarPageIndex.byID[original[0].pageID])
        model.select(nil)
        XCTAssertEqual(model.sidebarPageRevision, revision)
        await model.refreshPages()
        // Saving text updates page metadata in storage; the refreshed title/tree
        // index must accurately reflect the newly loaded page snapshot.
        XCTAssertEqual(model.sidebarPageIndex.byID[original[0].pageID], model.pages.first { $0.id == original[0].pageID })
    }

    func testSidebarExpansionPersistsPerWorkspaceAndBulkActionsRespectHierarchy() throws {
        let suite = "Velora.SidebarExpansion." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func page(_ parent: UUID? = nil, archived: Bool = false) -> Page {
            Page(id: UUID(), parentID: parent, title: "Fixture", order: 0, archived: archived, updatedAt: Date())
        }
        let root = page(), otherRoot = page()
        let child = page(root.id), leaf = page(), otherChild = page(otherRoot.id)
        let grandchild = page(child.id), archivedChild = page(leaf.id, archived: true)
        let pages = [root, child, grandchild, otherRoot, otherChild, leaf, archivedChild]
        let first = SidebarExpansionState(workspaceID: "first", defaults: defaults)
        first.collapsed = [root.id, child.id]
        let reopened = SidebarExpansionState(workspaceID: "first", defaults: defaults)
        XCTAssertEqual(reopened.collapsed, [root.id, child.id])
        let second = SidebarExpansionState(workspaceID: "second", defaults: defaults)
        XCTAssertTrue(second.collapsed.isEmpty)
        second.collapsed = [otherRoot.id]
        reopened.collapseAll(pages)
        XCTAssertEqual(reopened.collapsed, [root.id, child.id, otherRoot.id], "Only active branches should collapse")
        let afterRestart = SidebarExpansionState(workspaceID: "first", defaults: defaults)
        XCTAssertEqual(afterRestart.collapsed, reopened.collapsed)
        afterRestart.reveal(grandchild.id, in: pages)
        XCTAssertEqual(afterRestart.collapsed, [otherRoot.id], "Selecting a hidden page opens only its ancestors")
        XCTAssertEqual(SidebarExpansionState(workspaceID: "second", defaults: defaults).collapsed, [otherRoot.id])
        afterRestart.expandAll()
        XCTAssertTrue(SidebarExpansionState(workspaceID: "first", defaults: defaults).collapsed.isEmpty)
    }

    func testRapidPageSelectionKeepsLastPageAndPendingEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let first = try await store.createPage()
        let second = try await store.createPage()
        let original = try await store.createBlock(pageID: first.id, kind: .paragraph)
        _ = try await store.createBlock(pageID: second.id, kind: .paragraph)
        let model = WorkspaceModel(store: store)
        await model.refreshPages()
        model.select(first.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.first?.id, original.id)
        model.changeText("pending edit", in: original)
        for _ in 0..<50 { model.select(second.id); model.select(first.id) }
        model.select(second.id)
        XCTAssertEqual(model.selectedPageID, second.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.blocks.isEmpty)
        XCTAssertTrue(model.blocks.allSatisfy { $0.pageID == second.id })
        await model.flushAll()
        let stored = try await store.blocks(in: first.id)
        XCTAssertEqual(stored.first?.text, "pending edit")
        let ids = model.blocks.map(\.id)
        model.select(second.id)
        XCTAssertEqual(model.blocks.map(\.id), ids, "Repeated selection must preserve the live editor")
        model.select(first.id)
        XCTAssertEqual(model.blocks.first?.id, original.id, "Visited page must be available synchronously")
        XCTAssertEqual(model.blocks.first?.text, "pending edit")
        model.select(second.id)
        XCTAssertEqual(model.blocks.map(\.id), ids)
        model.select(first.id); model.select(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.selectedPageID)
        XCTAssertTrue(model.blocks.isEmpty, "A stale load must not repopulate a closed page")
    }

    func testPageCacheInvalidatesAfterStoreRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let first = try await store.createPage()
        let second = try await store.createPage()
        let original = try await store.createBlock(pageID: first.id, kind: .paragraph)
        _ = try await store.createBlock(pageID: second.id, kind: .paragraph)
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(first.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        model.select(second.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await store.updateBlock(original.id, text: "changed outside the editor")
        await model.refreshPages()
        model.select(first.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.first?.text, "changed outside the editor")
    }

    func testRowSnapshotsOnlyInvalidateAffectedEditors() {
        let pageID = UUID()
        func block(_ kind: BlockKind, _ text: String, _ order: Int) -> Block {
            Block(id: UUID(), pageID: pageID, kind: kind, text: text, order: Int64(order), checked: false)
        }
        var blocks = [block(.heading, "Heading", 0), block(.paragraph, "Text", 1),
                      block(.numbered, "One", 2), block(.numbered, "Two", 3),
                      block(.tableOfContents, "", 4)]
        func snapshots(selection: Set<UUID> = [], focus: EditorFocusRequest? = nil) -> [EditorRowSnapshot] {
            EditorRowSnapshot.make(blocks: blocks, selection: selection, focus: focus)
        }
        let before = snapshots()
        blocks[1].text = "Typing in this editor"
        let afterTyping = snapshots()
        XCTAssertNotEqual(before[1], afterTyping[1])
        for index in [0, 2, 3, 4] { XCTAssertEqual(before[index], afterTyping[index]) }
        let focused = snapshots(focus: EditorFocusRequest(blockID: blocks[1].id, offset: 0))
        for index in [0, 2, 3, 4] { XCTAssertEqual(afterTyping[index], focused[index]) }
        let selected = snapshots(selection: [blocks[2].id])
        XCTAssertNotEqual(afterTyping[2], selected[2])
        XCTAssertEqual(afterTyping[3], selected[3])
        XCTAssertEqual(afterTyping[2].number, 1)
        XCTAssertEqual(afterTyping[3].number, 2)
        blocks[2].kind = .paragraph
        XCTAssertEqual(snapshots()[3].number, 1, "List numbering must still update downstream")
        blocks[0].text = "Renamed heading"
        let renamed = snapshots()
        XCTAssertNotEqual(afterTyping[4], renamed[4], "Contents must follow heading edits")
        XCTAssertEqual(afterTyping[1], renamed[1])
    }

    func testNativeTypingIgnoresOlderModelAcknowledgementsAndConsumesInitialFocus() {
        let request = EditorFocusRequest(blockID: UUID(), offset: 0)
        let font = NSFont.systemFont(ofSize: 17)
        var reported: [String] = []
        let editor = NativeTextEditor(text: "", font: font, focusRequest: request, onChange: { reported.append($0) })
        let coordinator = NativeTextEditor.Coordinator(parent: editor)
        coordinator.lastBaseFont = font
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.font = font
        func type(_ source: String) {
            view.string = source
            view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        }
        type("/"); type("/t"); type("/table")
        XCTAssertEqual(coordinator.lastFocusRequest, request.id)
        coordinator.parent.text = "/"
        coordinator.synchronize(view)
        XCTAssertEqual(view.string, "/table")
        XCTAssertEqual(view.selectedRange().location, 6)
        coordinator.parent.text = "/t"
        coordinator.synchronize(view)
        XCTAssertEqual(view.string, "/table")
        coordinator.parent.text = "/table"
        coordinator.synchronize(view)
        XCTAssertEqual(view.selectedRange().location, 6)
        coordinator.parent.text = "" // An actual external command is still applied.
        coordinator.synchronize(view)
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(reported, ["/", "/t", "/table"])
    }

    func testSlashCommandUsesLiveNativeTextAndExactTableMatch() {
        XCTAssertEqual(SlashCommandMenu.matches("/table").first, .table)
        XCTAssertEqual(SlashCommandMenu.matches("/tableOfContents").first, .tableOfContents)
        XCTAssertTrue(SlashCommandMenu.matches("/no-such-block").isEmpty)
        var command: BlockKind?
        let editor = NativeTextEditor(text: "/", font: .systemFont(ofSize: 17), onCommand: { _, source in
            command = SlashCommandMenu.matches(source).first; return command != nil
        }, onChange: { _ in })
        let coordinator = NativeTextEditor.Coordinator(parent: editor)
        let view = NSTextView(); view.string = "/table"
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(command, .table)
    }

    func testSlashTableConvertsImmediatelyAndPersistsGrid() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let page = try await store.createPage()
        let block = try await store.createBlock(pageID: page.id, kind: .paragraph)
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        model.changeText("/table", in: block)
        model.insertSlashCommand(.table, in: block)
        XCTAssertEqual(model.blocks.first?.kind, .table)
        let json = try XCTUnwrap(model.blocks.first?.text.data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode([[String]].self, from: json), [["", ""], ["", ""]])
        await model.flushAll()
        for _ in 0..<200 {
            if try await store.blocks(in: page.id).first?.kind == .table { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let saved = try await store.blocks(in: page.id)
        XCTAssertEqual(saved.first?.kind, .table)
        XCTAssertEqual(saved.first?.text, model.blocks.first?.text)
    }

    func testCommandResetClearsSlashEvenWhenModelValueReturnsToBaseline() {
        let font = NSFont.systemFont(ofSize: 17)
        let editor = NativeTextEditor(text: "", font: font, onChange: { _ in })
        let coordinator = NativeTextEditor.Coordinator(parent: editor)
        coordinator.lastBaseFont = font
        let view = NSTextView(); view.font = font
        for kind in BlockKind.allCases where kind.acceptsTextInput {
            view.string = "/" + kind.rawValue
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
            // The model went empty -> /command -> empty before SwiftUI delivered
            // any intermediate update. A revision still forces the command reset.
            coordinator.parent.text = ""
            coordinator.parent.contentRevision += 1
            coordinator.synchronize(view)
            XCTAssertEqual(view.string, "", kind.rawValue)
            XCTAssertEqual(view.selectedRange().location, 0, kind.rawValue)
            view.string = "new content"
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
            coordinator.synchronize(view)
            XCTAssertEqual(view.string, "new content", "Typing protection must survive the explicit reset")
            let revision = coordinator.parent.contentRevision
            coordinator.parent.contentRevision = revision - 1
            coordinator.parent.text = "/" + kind.rawValue
            coordinator.synchronize(view)
            XCTAssertEqual(view.string, "new content", "Pre-command snapshots must not restore the slash query")
            coordinator.parent.contentRevision = revision
            coordinator.parent.text = ""
        }
    }

    func testEveryBlockCommandAndAliasHasAnExactMatch() {
        for kind in BlockKind.allCases {
            for alias in kind.slashAliases {
                XCTAssertEqual(SlashCommandMenu.matches("/" + alias).first, kind, alias)
            }
        }
    }

    func testAllBlockKindsConvertImmediatelyAndPersistDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let page = try await store.createPage()
        let original = try await store.createBlock(pageID: page.id, kind: .paragraph)
        try await store.setChecked(original.id, checked: true)
        try await store.setBlockOptions(original.id, language: "mermaid", collapsed: true)
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        for kind in BlockKind.allCases {
            model.changeText("/" + kind.rawValue, in: original)
            model.insertSlashCommand(kind, in: original)
            let current = try XCTUnwrap(model.blocks.first)
            XCTAssertEqual(current.kind, kind)
            XCTAssertEqual(current.text, kind.initialText)
            XCTAssertFalse(current.collapsed)
            XCTAssertFalse(current.checked)
            XCTAssertTrue(current.formatting.isEmpty)
            XCTAssertEqual(current.language, "Plain Text")
            XCTAssertGreaterThan(model.editorContentRevisions[original.id] ?? 0, 0)
            if kind.acceptsTextInput || kind == .table {
                XCTAssertEqual(model.editorFocusRequest?.blockID, current.id)
            } else { XCTAssertNil(model.editorFocusRequest) }
            await model.flushAll()
            let saved = try await store.blocks(in: page.id)
            XCTAssertEqual(saved.first, current, kind.rawValue)
            XCTAssertFalse(model.saving)
        }
    }

    func testTypingImmediatelyAfterConsecutiveCommandsIsNotOverwrittenByConversion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let page = try await store.createPage()
        let original = try await store.createBlock(pageID: page.id, kind: .paragraph)
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        model.insertSlashCommand(.code, in: original)
        model.insertSlashCommand(.quote, in: original)
        model.changeText("Typing immediately after the command", in: original)
        await model.flushAll()
        let saved = try await store.blocks(in: page.id)
        XCTAssertEqual(saved.first?.kind, .quote)
        XCTAssertEqual(saved.first?.text, "Typing immediately after the command")
        XCTAssertFalse(model.saving)
    }

    func testToolbarInsertionCreatesEveryBlockKindWithValidDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let page = try await store.createPage()
        _ = try await store.createBlock(pageID: page.id, kind: .paragraph)
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        for kind in BlockKind.allCases {
            let count = model.blocks.count
            model.addBlock(kind)
            for _ in 0..<200 where model.blocks.count == count { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(model.blocks.count, count + 1, kind.rawValue)
            XCTAssertEqual(model.blocks.last?.kind, kind)
            XCTAssertEqual(model.blocks.last?.text, kind.initialText)
        }
        let saved = try await store.blocks(in: page.id)
        XCTAssertEqual(saved, model.blocks)
    }

    private func slashPopupFixture(command: String = "/table", defaults: UserDefaults = .standard) async throws -> (NSWindow, WorkspaceModel, URL) {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/SlashPopup-" + UUID().uuidString)
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let page = try await store.createPage()
        let block = try await store.createBlock(pageID: page.id, kind: .paragraph)
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PageEditorView(model: model, page: page).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        model.requestFocus(block.id, offset: 0)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var editor: NSTextView?
        for _ in 0..<200 {
            editor = window.contentView.flatMap { descendants($0).compactMap { $0 as? NSTextView }.first { $0.delegate is NativeTextEditor.Coordinator } }
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let text = try XCTUnwrap(editor)
        window.makeFirstResponder(text)
        text.insertText(command, replacementRange: NSRange(location: 0, length: 0))
        for _ in 0..<200 {
            if window.childWindows?.contains(where: { $0 is EditorPopupPanel && $0.isVisible }) == true { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, model, directory)
    }

    func testLiteralReplacementPreservesUTF16AndSurroundingInlineStyles() {
        var bold = InlineTextStyle(); bold.bold = true
        var italic = InlineTextStyle(); italic.italic = true
        let value = RichInlineContent.replacing("前😀目标后目标尾", runs: [
            TextStyleRun(location: 3, length: 2, style: bold), TextStyleRun(location: 5, length: 4, style: italic)
        ], ranges: [NSRange(location: 3, length: 2), NSRange(location: 6, length: 2)], with: "ABCD")
        XCTAssertEqual(value.text, "前😀ABCD后ABCD尾")
        XCTAssertEqual(RichInlineContent.segments(value.text, runs: value.runs).map(\.text).joined(), value.text)
        XCTAssertTrue(value.runs.contains { $0.location == 3 && $0.length == 4 && $0.style.bold == true })
        for position in 7..<13 { XCTAssertTrue(value.runs.contains { $0.location <= position && $0.location + $0.length > position && $0.style.italic == true }) }
        let deleted = RichInlineContent.replacing("😀abc尾", runs: [TextStyleRun(location: 2, length: 4, style: bold)],
            ranges: [NSRange(location: 2, length: 3)], with: "")
        XCTAssertEqual(deleted.text, "😀尾")
        XCTAssertEqual(deleted.runs, [TextStyleRun(location: 2, length: 1, style: bold)])
    }

    func testReplaceAllPreservesBlockKindsTableLayoutPersistsAndCanUndo() async throws {
        let (_, store, model, original) = try await fixture()
        model.renameSelectedPage("目标页")
        model.changeText("目标😀目标", in: original[0])
        model.changeText("\t目标\n", in: original[1])
        model.insertSlashCommand(.table, in: original[4])
        await model.flushAll()
        let table = try XCTUnwrap(model.blocks.last)
        model.changeText(#"[["`目标`","列名"],["目标","`保留`"]]"#, in: table)
        model.changeTableLayout(TableLayout(columnWidths: [120, 230], rowHeights: [44, 80]), in: table)
        let before = model.blocks
        model.performDocumentFind(.replace)
        model.documentFindQuery = "目标"; model.documentReplacement = "`新|😀`"
        XCTAssertEqual(model.documentFindMatches.count, 6)
        model.replaceDocumentMatches(all: true)
        XCTAssertEqual(model.documentReplacementCount, 6)
        XCTAssertTrue(model.documentFindMatches.isEmpty)
        XCTAssertEqual(model.blocks.map(\.kind), before.map(\.kind))
        XCTAssertEqual(model.blocks[1].text, "\t`新|😀`\n")
        let changedTable = try XCTUnwrap(model.blocks.last)
        let cells = try JSONDecoder().decode([[String]].self, from: Data(changedTable.text.utf8))
        XCTAssertEqual(cells, [["`新|😀`", "列名"], ["`新|😀`", "保留"]])
        XCTAssertTrue(changedTable.tableLayout.cellsArePlain)
        XCTAssertEqual(changedTable.tableLayout.columnWidths, [120, 230])
        XCTAssertEqual(changedTable.tableLayout.rowHeights, [44, 80])
        XCTAssertEqual(model.selectedPage?.title, "`新|😀`页")
        XCTAssertTrue(model.canUndoDocumentReplacement)
        await model.flushAll()
        let saved = try await store.blocks(in: table.pageID)
        XCTAssertEqual(saved, model.blocks)
        model.undoDocumentReplacement()
        XCTAssertEqual(model.blocks, before)
        XCTAssertEqual(model.selectedPage?.title, "目标页")
        XCTAssertFalse(model.canUndoDocumentReplacement)
        await model.flushAll()
        let restored = try await store.blocks(in: table.pageID)
        XCTAssertEqual(restored, before)
        let pages = try await store.pages()
        XCTAssertEqual(pages.first { $0.id == table.pageID }?.title, "目标页")
    }

    func testReplaceCurrentSkipsInsertedMatchesAndUndoDoesNotOverwriteLaterEdits() async throws {
        let (_, _, model, original) = try await fixture()
        model.changeText("x x", in: original[0])
        model.performDocumentFind(.replace)
        model.documentFindQuery = "x"; model.documentReplacement = "xx"
        model.replaceDocumentMatches(all: false)
        XCTAssertEqual(model.blocks[0].text, "xx x")
        XCTAssertEqual(model.currentDocumentFindMatch?.range.location, 3)
        model.documentReplacement = ""
        model.replaceDocumentMatches(all: false)
        XCTAssertEqual(model.blocks[0].text, "xx ")
        XCTAssertEqual(model.currentDocumentFindMatch?.range.location, 0)
        model.changeText("用户后续修改", in: original[0])
        XCTAssertFalse(model.canUndoDocumentReplacement)
        model.undoDocumentReplacement()
        XCTAssertEqual(model.blocks[0].text, "用户后续修改")
        model.documentFindQuery = ""
        model.replaceDocumentMatches(all: true)
        XCTAssertEqual(model.documentReplacementCount, 0)
        await model.flushAll()
    }

    func testHostedReplaceShortcutUpdatesNativeTextWithoutInterpretingMarkdown() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? CodeTextView)
        editor.insertText("目标 目标", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(editor.performKeyEquivalent(with: event))
        XCTAssertTrue(model.documentReplacePresented)
        model.documentFindQuery = "目标"; model.documentReplacement = "# **字面量**"
        model.replaceDocumentMatches(all: true)
        for _ in 0..<100 where editor.string != "# **字面量** # **字面量**" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(editor.string, "# **字面量** # **字面量**")
        XCTAssertEqual(model.blocks[0].kind, .paragraph)
        model.undoDocumentReplacement()
        for _ in 0..<100 where editor.string != "目标 目标" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(editor.string, "目标 目标")
        await model.flushAll()
    }

    func testDocumentFindUsesUTF16RangesAndSearchesVisibleTableCells() async throws {
        let (_, _, model, original) = try await fixture()
        var text = original[0]; text.text = "😀Café CAFÉ café"
        var table = original[1]; table.kind = .table
        table.text = #"[["`café`","literal"],["Café","other"]]"#
        var image = original[3]; image.text = "https://example.com/cafe.png"
        let hits = DocumentFindMatch.search("cafe", title: "Cafe", blocks: [text, table, image])
        XCTAssertEqual(hits.count, 6)
        XCTAssertNil(hits[0].blockID)
        XCTAssertEqual(hits[1].range, NSRange(location: 2, length: 4))
        XCTAssertEqual(hits[4].row, 0); XCTAssertEqual(hits[4].column, 0)
        XCTAssertEqual(hits[4].range, NSRange(location: 0, length: 4), "Search visible text, not legacy code delimiters")
        XCTAssertEqual(hits[5].row, 1)
        XCTAssertTrue(DocumentFindMatch.search("", title: "", blocks: model.blocks).isEmpty)
    }

    func testDocumentFindWrapsUpdatesLiveAndResetsWhenSwitchingPage() async throws {
        let (_, store, model, original) = try await fixture()
        model.changeText("目标😀目标", in: original[0])
        model.documentFindQuery = "目标"
        model.performDocumentFind(.show)
        XCTAssertEqual(model.documentFindMatches.count, 2)
        XCTAssertEqual(model.documentFindIndex, 0)
        model.performDocumentFind(.previous); XCTAssertEqual(model.documentFindIndex, 1)
        model.performDocumentFind(.next); XCTAssertEqual(model.documentFindIndex, 0)
        model.changeText("已删除", in: original[0])
        XCTAssertTrue(model.documentFindMatches.isEmpty)
        model.changeText("新目标", in: original[0])
        XCTAssertEqual(model.currentDocumentFindMatch?.range, NSRange(location: 1, length: 2))
        model.closeDocumentFind(); XCTAssertTrue(model.documentFindMatches.isEmpty)
        model.performDocumentFind(.show); XCTAssertEqual(model.documentFindMatches.count, 1)
        let other = try await store.createPage()
        model.select(other.id)
        XCTAssertFalse(model.documentFindPresented); XCTAssertTrue(model.documentFindMatches.isEmpty)
        await model.flushAll()
    }

    func testHostedDocumentFindShortcutHighlightsWithoutChangingContentOrFocus() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? CodeTextView)
        editor.insertText("开😀目标 目标", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let caret = editor.selectedRange()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(editor.performKeyEquivalent(with: event))
        XCTAssertTrue(model.documentFindPresented)
        model.documentFindQuery = "目标"
        for _ in 0..<100 where window.firstResponder === editor { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.documentFindMatches.count, 2)
        XCTAssertNotNil(editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 3, effectiveRange: nil))
        XCTAssertEqual(editor.selectedRange(), caret)
        XCTAssertFalse(window.firstResponder === editor, "Find must leave typing focus in the find field")
        func captureFindBar(_ name: String) throws {
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.deletingLastPathComponent().appendingPathComponent(name))
        }
        try captureFindBar("findbar-compact-native.png")
        model.documentReplacePresented = true
        try await Task.sleep(for: .milliseconds(80))
        try captureFindBar("findbar-compact-replace-native.png")
        model.documentReplacePresented = false
        model.performDocumentFind(.next)
        XCTAssertEqual(model.documentFindIndex, 1)
        model.closeDocumentFind()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 3, effectiveRange: nil))
        XCTAssertEqual(editor.string, "开😀目标 目标")
        XCTAssertFalse(model.blocks[0].formatting.contains { $0.style.highlight != nil })
        await model.flushAll()
    }

    func testHostedListBlockPastePreservesKindsFormattingAndNumbering() async throws {
        for kind in [BlockKind.paragraph, .bullet, .numbered] {
            let (window, model, directory) = try await slashPopupFixture()
            let original = try XCTUnwrap(model.blocks.first)
            model.insertSlashCommand(kind, in: original, text: "目标")
            await model.flushAll()
            try await Task.sleep(for: .milliseconds(80))
            let editor = try XCTUnwrap(window.firstResponder as? CodeTextView)
            var style = InlineTextStyle(); style.bold = true
            let copied = [TransferBlock(.bullet, "项目\n续行", formatting: [TextStyleRun(location: 0, length: 2, style: style)]),
                          TransferBlock(.numbered, "第一项"), TransferBlock(.numbered, "第二项")]
            XCTAssertTrue(ClipboardDocument.copyBlocks(copied))
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            editor.paste(nil)
            for _ in 0..<200 where model.blocks.first?.id == original.id { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(Array(model.blocks.prefix(3).map(TransferBlock.init)), copied, "Destination: \(kind)")
            let rows = EditorRowSnapshot.make(blocks: model.blocks, selection: [], focus: nil)
            XCTAssertEqual(Array(rows.prefix(3).map(\.number)), [1, 1, 2])
            await model.flushAll()
            let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
            let saved = try await reopened.blocks(in: try XCTUnwrap(model.selectedPageID))
            XCTAssertEqual(Array(saved.prefix(3).map(TransferBlock.init)), copied)
            window.close(); NSPasteboard.general.clearContents()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testListPasteSplitsDestinationWithoutLosingItsKindOrStyles() {
        var style = InlineTextStyle(); style.italic = true
        let destination = TransferBlock(.todo, "前😀后", checked: true,
                                        formatting: [TextStyleRun(location: 0, length: 4, style: style)])
        let copied = [TransferBlock(.numbered, "一"), TransferBlock(.numbered, "二")]
        let result = ClipboardDocument.inserting(copied, into: destination.text, formatting: destination.formatting,
                                                 selection: NSRange(location: 1, length: 2), destination: destination)
        XCTAssertEqual(result.map(\.kind), [.todo, .numbered, .numbered, .todo])
        XCTAssertEqual(result.map(\.text), ["前", "一", "二", "后"])
        XCTAssertTrue(result[0].checked); XCTAssertTrue(result[3].checked)
        XCTAssertEqual(result[3].formatting, [TextStyleRun(location: 0, length: 1, style: style)])
    }

    func testClipboardHTMLGroupsConsecutiveListItems() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let blocks = [TransferBlock(.numbered, "甲"), TransferBlock(.numbered, "乙"),
                      TransferBlock(.bullet, "丙"), TransferBlock(.bullet, "丁"),
                      TransferBlock(.paragraph, "分隔"), TransferBlock(.numbered, "戊")]
        XCTAssertTrue(ClipboardDocument.copyBlocks(blocks, to: board))
        XCTAssertEqual(ClipboardDocument.blocks(from: board), blocks)
        let html = board.string(forType: .html) ?? ""
        XCTAssertTrue(html.contains("<ol><li>甲</li>\n<li>乙</li></ol>"))
        XCTAssertTrue(html.contains("<ul><li>丙</li>\n<li>丁</li></ul>"))
        XCTAssertTrue(html.contains("<ol><li>戊</li></ol>"))
    }

    func testHostedPasteDistinguishesLiteralCodeSelectionFromWholeCodeBlock() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); NSPasteboard.general.clearContents(); try? FileManager.default.removeItem(at: directory) }
        let target = try XCTUnwrap(window.firstResponder as? CodeTextView)
        target.setSelectedRange(NSRange(location: 0, length: target.string.utf16.count))
        let source = CodeTextView(frame: target.frame)
        source.copySelectionAsText = true
        source.string = "# 一、本章学习目标"
        source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
        source.copy(nil)
        target.paste(nil)
        XCTAssertEqual(target.string, source.string)
        XCTAssertEqual(model.blocks.first?.kind, .paragraph)
        XCTAssertEqual(model.blocks.first?.text, source.string)
        let code = TransferBlock(.code, "    let x = 1\n\n", language: "Swift")
        ClipboardDocument.copyBlocks([code])
        target.setSelectedRange(NSRange(location: 0, length: target.string.utf16.count))
        target.paste(nil)
        for _ in 0..<200 where model.blocks.first?.kind != .code { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.first?.kind, .code)
        XCTAssertEqual(model.blocks.first?.text, code.text)
        XCTAssertEqual(model.blocks.first?.language, "Swift")
        await model.flushAll()
    }

    func testHostedMarkdownHeadingShortcutConsumesMarkerAndSavesImmediateTyping() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("# ", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.blocks.first?.kind, .heading)
        XCTAssertEqual(editor.string, "")
        editor.insertText("一、本章学习目标", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.blocks.first?.text, "一、本章学习目标")
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: try XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(saved.first?.kind, .heading)
        XCTAssertEqual(saved.first?.text, "一、本章学习目标")
        for (prefix, kind) in [("## ", BlockKind.heading2), ("### ", .heading3)] {
            let block = try XCTUnwrap(model.blocks.first)
            model.insertSlashCommand(.paragraph, in: block)
            XCTAssertTrue(model.applyMarkdownHeading(prefix + "章节", formatting: [], in: block))
            XCTAssertEqual(model.blocks.first?.kind, kind)
            XCTAssertEqual(model.blocks.first?.text, "章节")
            await model.flushAll()
        }
        let current = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.paragraph, in: current)
        for literal in ["#hashtag", "text # heading", "#### title", "# title\nbody"] {
            XCTAssertFalse(model.applyMarkdownHeading(literal, formatting: [], in: current))
        }
        await model.flushAll()
    }

    func testCodeTypographyPreferenceAndLocalSelectAll() async throws {
        let defaults = UserDefaults.standard
        let oldSize = defaults.object(forKey: "codeFontSize")
        defaults.set(13.0, forKey: "codeFontSize")
        defer {
            if let oldSize { defaults.set(oldSize, forKey: "codeFontSize") }
            else { defaults.removeObject(forKey: "codeFontSize") }
        }
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let block = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.code, in: block, text: "let value = 1\nprint(value)")
        var style = InlineTextStyle(); style.fontSize = 11; style.fontFamily = "Times New Roman"
        model.changeRichText(model.blocks[0].text,
            formatting: [TextStyleRun(location: 0, length: 3, style: style)], in: model.blocks[0])
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var found: CodeTextView?
        for _ in 0..<200 {
            found = window.contentView.flatMap { descendants($0).compactMap { $0 as? CodeTextView }.first { $0.copySelectionAsText } }
            if found != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let editor = try XCTUnwrap(found)
        window.makeFirstResponder(editor)
        defaults.set(18.0, forKey: "codeFontSize")
        for _ in 0..<200 where (editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize != 18 {
            try await Task.sleep(for: .milliseconds(5))
        }
        for index in [0, 5] {
            let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, 18)
            XCTAssertTrue(font.isFixedPitch)
        }
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.selectAll(nil)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(model.selectedBlockIDs.isEmpty)
        await model.flushAll()
    }

    func testHeadingShortcutThroughWindowKeyEquivalent() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? CodeTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("章节内容", replacementRange: editor.selectedRange())
        for (key, level) in [(UInt16(18), 1), (19, 2), (20, 3)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .option], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: String(level), charactersIgnoringModifiers: String(level),
                isARepeat: false, keyCode: key))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(model.blocks[0].kind, level == 1 ? .heading : level == 2 ? .heading2 : .heading3)
            XCTAssertEqual(model.blocks[0].text, "章节内容")
            try await Task.sleep(for: .milliseconds(30))
        }
        await model.flushAll()
    }

    func testShiftEnterExitsCodeBlockWithoutChangingSourceAndReusesBlankParagraph() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let original = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.code, in: original, text: "let value = 1")
        var editor: CodeTextView?
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for _ in 0..<200 {
            editor = window.contentView.flatMap { descendants($0).compactMap { $0 as? CodeTextView }.first { $0.copySelectionAsText } }
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let code = try XCTUnwrap(editor)
        window.makeFirstResponder(code)
        code.setSelectedRange(NSRange(location: 3, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        code.keyDown(with: event)
        for _ in 0..<200 where model.blocks.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.count, 2)
        XCTAssertEqual(model.blocks[0].text, "let value = 1")
        XCTAssertEqual(model.blocks[1].kind, .paragraph)
        XCTAssertEqual(model.blocks[1].text, "")
        for _ in 0..<200 where (window.firstResponder as? NSTextView)?.string != "" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual((window.firstResponder as? NSTextView)?.string, "")
        model.exitBlock(model.blocks[0])
        XCTAssertEqual(model.blocks.count, 2, "Reuse the empty paragraph rather than inserting another")
        XCTAssertEqual(model.editorFocusRequest?.blockID, model.blocks[1].id)
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: original.pageID)
        XCTAssertEqual(saved.map(\.kind), [.code, .paragraph])
        XCTAssertEqual(saved[0].text, "let value = 1")
    }

    func testCopyingOnlyLaterListItemRetainsItsDisplayedNumber() async throws {
        let (_, _, model, _) = try await fixture()
        model.insertSlashCommand(.numbered, in: model.blocks[0], text: "first")
        model.insertSlashCommand(.numbered, in: model.blocks[1], text: "second")
        await model.flushAll()
        let second = model.blocks[1]
        let copied = model.clipboardBlocks([second.id])
        XCTAssertEqual(copied.first?.listStart, 2)
        XCTAssertEqual(ListNumbering.numbers(copied), [2])
        let together = model.clipboardBlocks([model.blocks[0].id, second.id])
        XCTAssertEqual(together.map(\.listStart), [nil, nil])
        XCTAssertEqual(ListNumbering.numbers(together), [1, 2])
    }

    func testContinueListNumberingRepairsOldContentAndReturnContinuesExplicitStart() async throws {
        let (_, store, model, _) = try await fixture()
        model.insertSlashCommand(.numbered, in: model.blocks[0], text: "Token")
        await model.flushAll()
        let count = model.blocks.count
        model.addBlock(.numbered, after: model.blocks.last, text: "Prompt")
        for _ in 0..<200 where model.blocks.count == count { try await Task.sleep(for: .milliseconds(5)) }
        let prompt = try XCTUnwrap(model.blocks.last)
        XCTAssertEqual(EditorRowSnapshot.make(blocks: model.blocks, selection: [], focus: nil).last?.number, 1)
        try await model.continueListNumbering(in: prompt)
        XCTAssertEqual(EditorRowSnapshot.make(blocks: model.blocks, selection: [], focus: nil).last?.number, 2)
        try await model.setListStart(7, in: prompt)
        XCTAssertTrue(model.returnFromSingleLineBlock(prompt, text: "Prompt", formatting: [], selection: NSRange(location: 6, length: 0)))
        let rows = EditorRowSnapshot.make(blocks: model.blocks, selection: [], focus: nil)
        XCTAssertEqual(rows.suffix(2).map(\.number), [7, 8])
        await model.flushAll()
        let saved = try await store.blocks(in: prompt.pageID)
        XCTAssertEqual(saved.suffix(2).map(\.listStart), [7, nil])
    }

    func testHostedChatGPTBadgePasteKeepsOneEditorAndVisibleInlineCodeBackground() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "")
        defer { window.close() }
        let title = "23. MySQL 索引为什么会失效？什么是最左前缀原则？"
        let html = "<h3>" + title + "</h3><p><code>难度 ★★★★☆</code></p><blockquote><strong>重要程度：★★★★★</strong></blockquote><h3>一、标准答案</h3>"
        model.pasteDocument(plain: title + "\n难度 ★★★★☆ 重要程度：★★★★★\n一、标准答案", html: html,
            original: "", formatting: [], selection: NSRange(location: 0, length: 0), in: try XCTUnwrap(model.blocks.first))
        for _ in 0..<200 where model.blocks.count != 3 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.map(\.kind), [.heading3, .paragraph, .heading3])
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var row: CodeTextView?
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            row = window.contentView.flatMap { descendants($0).compactMap { $0 as? CodeTextView }.first { $0.string.contains("难度") && $0.string.contains("重要程度") } }
            if row != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let editor = try XCTUnwrap(row)
        let range = (editor.string as NSString).range(of: "难度")
        XCTAssertNotNil(editor.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
        let root = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.deletingLastPathComponent().appendingPathComponent("chatgpt-inline-badge-native.png"))
        await model.flushAll()
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await store.blocks(in: XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(saved.map(\.kind), [.heading3, .paragraph, .heading3])
    }

    func testImageResizeUsesNativeDragAndPersistsCustomWidthAndReset() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "")
        defer { window.close() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 200, height: 100).fill()
        NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill()
        NSGraphicsContext.restoreGraphicsState()
        let source = try ImageSource.embedded(XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
        model.insertSlashCommand(.image, in: try XCTUnwrap(model.blocks.first), text: source)
        await model.flushAll()
        let block = try XCTUnwrap(model.blocks.first)
        model.selectBlock(block.id)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var grip: TableResizeGripView?
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            grip = window.contentView.flatMap { descendants($0).compactMap { $0 as? TableResizeGripView }.first { $0.identifier?.rawValue == "image-column-0" && $0.bounds.height > 0 } }
            if grip != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Wait for image decode and its actual fitted bounds, not the placeholder.
        try await Task.sleep(for: .milliseconds(100))
        let handle = try XCTUnwrap(grip)
        let raw = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let origin = NSPoint(x: raw.x.rounded(), y: raw.y.rounded())
        let end = NSPoint(x: origin.x + 120, y: origin.y)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseUp, end), atStart: true)
        NSApp.postEvent(try event(.leftMouseDragged, end), atStart: true)
        window.sendEvent(try event(.leftMouseDown, origin))
        for _ in 0..<200 where model.blocks.first?.imageWidth == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(try XCTUnwrap(model.blocks.first?.imageWidth), 320, accuracy: 2)
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: block.pageID)
        XCTAssertEqual(saved.first?.imageWidth, model.blocks.first?.imageWidth)
        XCTAssertEqual(saved.first?.text, source)
        func capture(_ host: NSView, name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = directory.deletingLastPathComponent().appendingPathComponent(name)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        try capture(XCTUnwrap(window.contentView), name: "image-resize-native.png")
        let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false
        previewWindow.contentView = NSHostingView(rootView: ImageZoomPreview(source: source))
        previewWindow.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        try capture(XCTUnwrap(previewWindow.contentView), name: "image-preview-native.png")
        previewWindow.close()
        try await model.resizeImage(nil, in: block)
        XCTAssertNil(model.blocks.first?.imageWidth)
    }

    func testInlineImageStaysCompactWithoutUpscalingOrDistortingAspectRatio() async throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".agents/test")
        for size in [NSSize(width: 200, height: 400), NSSize(width: 800, height: 200), NSSize(width: 400, height: 1600)] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
            NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: size.width, height: size.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            let source = try ImageSource.embedded(XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
            let host = NSHostingView(rootView: MediaImageView(source: source).frame(width: 560).fixedSize(horizontal: false, vertical: true))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 1200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host; window.orderFront(nil)
            let scale = min(1, 560 / size.width, 420 / size.height)
            let expected = size.height * scale
            for _ in 0..<200 {
                host.layoutSubtreeIfNeeded()
                if abs(host.fittingSize.height - expected) < 2 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(host.fittingSize.width, 560, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, expected, accuracy: 2, "Image should keep its natural size or shrink to fit the compact bounds")
            host.setFrameSize(host.fittingSize)
            if let capture = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: capture)
                try capture.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(size.height > size.width ? "image-inline-portrait.png" : "image-inline-landscape.png"))
            }
            window.close()
        }
    }

    func testHostedImageSlashCommandOpensPickerAndCancelKeepsWritableImageBlock() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "/image")
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close(); try? FileManager.default.removeItem(at: directory)
        }
        let text = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(SlashCommandMenu.matches(text.string).first, .image)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        text.keyDown(with: enter)
        for _ in 0..<200 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.first?.kind, .image)
        XCTAssertEqual(model.blocks.first?.text, "")
        let sheet = try XCTUnwrap(window.attachedSheet, "The /image command must open the image source picker")
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        sheet.performKeyEquivalent(with: escape)
        for _ in 0..<200 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.blocks[0].kind, .image)
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: try XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(saved.first?.kind, .image)
        XCTAssertEqual(saved.first?.text, "")
    }

    func testHostedH1CommandUsesHeadingFontForSubsequentTyping() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "/h1")
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: enter)
        for _ in 0..<200 where editor.string != "" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.first?.kind, .heading)
        editor.insertText("一、本章学习目标", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 28, "Typing after /h1 must inherit the heading font")
        XCTAssertFalse(model.blocks[0].formatting.contains { $0.style.fontSize != nil })
        await model.flushAll()
    }

    func testHeadingKeyboardAndMenuConversionPreserveTextAndReplaceBodySize() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("已有章节内容", replacementRange: editor.selectedRange())
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
        editor.keyDown(with: event)
        for _ in 0..<200 where editor.font?.pointSize != 28 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks[0].kind, .heading)
        XCTAssertEqual(model.blocks[0].text, "已有章节内容")
        XCTAssertEqual(editor.font?.pointSize, 28)
        let block = model.blocks[0]
        var style = InlineTextStyle(); style.fontSize = 19; style.italic = true
        model.changeRichText(block.text, formatting: [TextStyleRun(location: 0, length: block.text.utf16.count, style: style)], in: block)
        model.changeKind(.heading, of: block)
        XCTAssertEqual(model.blocks[0].text, block.text)
        XCTAssertNil(model.blocks[0].formatting.first?.style.fontSize)
        XCTAssertEqual(model.blocks[0].formatting.first?.style.italic, true)
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: block.pageID)
        XCTAssertEqual(saved[0].kind, .heading)
        XCTAssertEqual(saved[0].text, block.text)
        XCTAssertNil(saved[0].formatting.first?.style.fontSize)
    }

    func testHashThenSpaceConvertsExistingTextToVisiblyLargeHeading() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("一、本章学习目标", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("#", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.blocks[0].kind, .paragraph)
        editor.insertText(" ", replacementRange: editor.selectedRange())
        for _ in 0..<200 where editor.font?.pointSize != 28 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks[0].kind, .heading)
        XCTAssertEqual(model.blocks[0].text, "一、本章学习目标")
        XCTAssertEqual(editor.string, "一、本章学习目标")
        XCTAssertEqual((editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 28)
        XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.pointSize, 28)
        XCTAssertEqual(editor.selectedRange().location, 0, "Removing # must keep the caret before the existing text")
        editor.insertText("新增", replacementRange: editor.selectedRange())
        XCTAssertFalse(model.blocks[0].formatting.contains { $0.style.fontSize != nil })
        await model.flushAll()
        let current = model.blocks[0]
        model.changeKind(.heading2, of: current)
        XCTAssertTrue(model.applyMarkdownHeading("# 改为一级", formatting: [], in: current))
        XCTAssertEqual(model.blocks[0].kind, .heading)
        await model.flushAll()
    }




    func testEnterAtEndOfLongParagraphFocusesNewBlock() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let source = String(repeating: "这是很长的一行正文，需要保留完整内容。\n", count: 90)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(source, replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        editor.keyDown(with: event)
        for _ in 0..<300 where model.blocks.count < 2 || (window.firstResponder as? NSTextView)?.string != "" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.blocks.count, 2)
        XCTAssertEqual(model.blocks[0].text, source)
        let paragraph = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(paragraph.string, "")
        XCTAssertFalse(paragraph === editor)
        XCTAssertGreaterThan(paragraph.visibleRect.height, 0)
        paragraph.insertText("继续写作", replacementRange: paragraph.selectedRange())
        XCTAssertEqual(model.blocks[1].text, "继续写作")
        await model.flushAll()
    }

    func testChangingFontKeepsLiveFormatPopoverHostAndSelectionStable() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let source = "这里的 5 表示最多保留五条普通消息，不是五轮对话。\n一轮普通问答一般包含：😀"
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(source, replacementRange: editor.selectedRange())
        let selection = NSRange(location: 0, length: source.utf16.count)
        editor.setSelectedRange(selection)
        let coordinator = try XCTUnwrap(editor.delegate as? NativeTextEditor.Coordinator)
        for _ in 0..<200 where !coordinator.formatPopover.isShown { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(coordinator.formatPopover.isShown)
        let host = try XCTUnwrap(coordinator.formatPopover.contentViewController)
        for _ in 0..<6 {
            for family in ["Songti SC", "Menlo", "PingFang SC", "系统字体"] {
                coordinator.applyFormat(.family(family), to: editor)
                coordinator.applyFormat(.size(12), to: editor)
                try await Task.sleep(for: .milliseconds(5))
                XCTAssertTrue(coordinator.formatPopover.contentViewController === host)
                XCTAssertEqual(editor.string, source)
                XCTAssertEqual(editor.selectedRange(), selection)
            }
        }
        coordinator.applyFormat(.family("Songti SC"), to: editor)
        try await Task.sleep(for: .milliseconds(10))
        let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 12)
        XCTAssertTrue(font.familyName?.contains("Songti") == true)
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: try XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(saved.first?.text, source)
        XCTAssertTrue(saved.first?.formatting.contains { $0.style.fontFamily?.contains("Songti") == true && $0.style.fontSize == 12 } == true)
        coordinator.formatPopover.close()
    }

    func testStyleClipboardKeyboardAppliesAcrossBlocksWithoutChangingTextAndSupportsUndo() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        let board = NSPasteboard(name: .init("Velora.StyleTest." + UUID().uuidString))
        defer { board.clearContents(); window.close(); try? FileManager.default.removeItem(at: directory) }
        let clipboard = TextStyleClipboard(pasteboard: board)
        let source = try XCTUnwrap(window.firstResponder as? CodeTextView)
        let sourceCoordinator = try XCTUnwrap(source.delegate as? NativeTextEditor.Coordinator)
        sourceCoordinator.styleClipboard = clipboard
        source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
        source.insertText("源样式文字", replacementRange: source.selectedRange())
        source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
        for action in [TextFormatAction.family("Songti SC"), .size(24), .bold, .underline, .color("2563EB"), .highlight("FFF1A8")] {
            sourceCoordinator.applyFormat(action, to: source)
        }
        source.textStorage?.addAttribute(.link, value: "https://source.example", range: source.selectedRange())
        source.didChangeText()
        let contentClipboardRevision = NSPasteboard.general.changeCount
        func shortcut(_ key: String, code: UInt16, in editor: CodeTextView) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            editor.keyDown(with: event)
        }
        try shortcut("c", code: 8, in: source)
        XCTAssertEqual(NSPasteboard.general.changeCount, contentClipboardRevision)
        XCTAssertNil(clipboard.read()?.link)
        XCTAssertEqual(clipboard.read()?.fontSize, 24)
        model.addBlock(after: try XCTUnwrap(model.blocks.first), text: "左 TARGET 右")
        for _ in 0..<200 where (window.firstResponder as? NSTextView)?.string != "左 TARGET 右" {
            try await Task.sleep(for: .milliseconds(5))
        }
        let target = try XCTUnwrap(window.firstResponder as? CodeTextView)
        XCTAssertFalse(target === source)
        let coordinator = try XCTUnwrap(target.delegate as? NativeTextEditor.Coordinator)
        coordinator.styleClipboard = clipboard
        let selection = NSRange(location: 2, length: 6)
        target.textStorage?.addAttributes([.link: "https://target.example", .foregroundColor: NSColor.red], range: selection)
        target.didChangeText(); target.setSelectedRange(selection)
        let beforeFont = target.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        try await Task.sleep(for: .milliseconds(20))
        let host = coordinator.formatPopover.contentViewController
        try shortcut("v", code: 9, in: target)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(target.string, "左 TARGET 右")
        XCTAssertEqual(source.string, "源样式文字")
        XCTAssertEqual(target.selectedRange(), selection)
        XCTAssertTrue(coordinator.formatPopover.contentViewController === host)
        let attributes = try XCTUnwrap(target.textStorage?.attributes(at: 2, effectiveRange: nil))
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        XCTAssertEqual(font.pointSize, 24)
        XCTAssertTrue(font.familyName?.contains("Songti") == true)
        XCTAssertEqual(RichTextFormatting.hex(try XCTUnwrap(attributes[.foregroundColor] as? NSColor)), "2563EB")
        XCTAssertEqual(RichTextFormatting.hex(try XCTUnwrap(attributes[.backgroundColor] as? NSColor)), "FFF1A8")
        XCTAssertEqual((attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String, "https://target.example")
        XCTAssertEqual((target.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, beforeFont?.pointSize)
        XCTAssertEqual(NSPasteboard.general.changeCount, contentClipboardRevision)
        await model.flushAll()
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await store.blocks(in: try XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(saved.last?.text, "左 TARGET 右")
        XCTAssertTrue(saved.last?.formatting.contains { $0.style.fontSize == 24 && $0.style.color == "2563EB" && $0.style.link == "https://target.example" } == true)
        let undo = try XCTUnwrap(target.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(target.string, "左 TARGET 右")
        XCTAssertEqual((target.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize, beforeFont?.pointSize)
        undo.redo()
        XCTAssertEqual((target.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize, 24)
        await model.flushAll()
        coordinator.formatPopover.close(); sourceCoordinator.formatPopover.close()
    }

    func testCopiedSystemAndMonospacedStylesResolveToTheirOriginalFonts() throws {
        let board = NSPasteboard(name: .init("Velora.FontStyleTest." + UUID().uuidString))
        defer { board.clearContents() }
        let clipboard = TextStyleClipboard(pasteboard: board)
        let fonts = [NSFont.systemFont(ofSize: 19), NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                     try XCTUnwrap(NSFont(name: "Songti SC", size: 24))]
        for font in fonts {
            clipboard.copy(attributes: [.font: font], base: font)
            let style = try XCTUnwrap(clipboard.read())
            let resolved = try XCTUnwrap(RichTextFormatting.attributes(style, base: .systemFont(ofSize: 28, weight: .bold))[.font] as? NSFont)
            XCTAssertEqual(resolved.familyName, font.familyName)
            XCTAssertEqual(resolved.pointSize, font.pointSize)
        }
    }

    func testPastingAbsentStyleDoesNotChangeTextOrFormatting() {
        let board = NSPasteboard(name: .init("Velora.EmptyStyleTest." + UUID().uuidString))
        defer { board.clearContents() }
        var changes = 0
        let parent = NativeTextEditor(text: "目标", font: .systemFont(ofSize: 17), onChange: { _ in changes += 1 })
        let coordinator = NativeTextEditor.Coordinator(parent: parent)
        coordinator.styleClipboard = TextStyleClipboard(pasteboard: board)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        view.string = "目标"; view.font = parent.font
        view.setSelectedRange(NSRange(location: 0, length: 2))
        let original = NSAttributedString(attributedString: view.attributedString())
        coordinator.applyFormat(.pasteStyle, to: view)
        XCTAssertEqual(view.attributedString(), original)
        XCTAssertEqual(changes, 0)
    }

    func testCodeBlockShrinksToContentAndLineNumberPreferenceUpdatesLive() async throws {
        let suite = "Velora.CodeDisplay." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "codeLineNumbers")
        defaults.set(false, forKey: "codeLineCount")
        let (window, model, directory) = try await slashPopupFixture(defaults: defaults)
        defer { window.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let block = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.code, in: block, text: "let value = 1")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var editor: CodeTextView?
        for _ in 0..<200 {
            editor = window.contentView.flatMap { descendants($0).compactMap { $0 as? CodeTextView }.first { $0.showsLineNumbers } }
            if editor?.string == "let value = 1" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let text = try XCTUnwrap(editor)
        try await Task.sleep(for: .milliseconds(60))
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let singleHeight = scroll.frame.height
        XCTAssertLessThan(singleHeight, 50, "A single line must not reserve the old 72pt editor height")
        model.changeText(String(repeating: "let value = 1\n", count: 8), in: block)
        for _ in 0..<200 where scroll.frame.height < 100 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(scroll.frame.height, 100)
        model.changeText("let value = 1", in: block)
        for _ in 0..<200 where scroll.frame.height > singleHeight + 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertLessThanOrEqual(scroll.frame.height, singleHeight + 1)
        defaults.set(false, forKey: "codeLineNumbers")
        for _ in 0..<200 where text.showsLineNumbers { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(text.showsLineNumbers)
        XCTAssertEqual(text.textContainerInset.width, 18)
        XCTAssertEqual(text.string, "let value = 1")
        try await Task.sleep(for: .milliseconds(60))
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.deletingLastPathComponent().appendingPathComponent("code-block-compact.png"))
        }
        await model.flushAll()
    }

    func testHostedSlashPopupEnterReallyInsertsTable() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let panel = try XCTUnwrap(window.childWindows?.first { $0 is EditorPopupPanel })
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.canBecomeKey, "Menu must leave keyboard input in the text editor")
        let text = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(text.string, "/table")
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        text.keyDown(with: enter)
        for _ in 0..<200 where model.blocks.first?.kind != .table { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.first?.kind, .table)
        await model.flushAll()
        for _ in 0..<200 where panel.isVisible { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(panel.isVisible)
    }

    func testHostedSlashPopupKeepsTypingAndTabUsesUpdatedFilter() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let panel = try XCTUnwrap(window.childWindows?.first { $0 is EditorPopupPanel })
        let text = try XCTUnwrap(window.firstResponder as? NSTextView)
        text.insertText("OfContents", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        for _ in 0..<200 where model.blocks.first?.text != "/tableOfContents" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.first?.text, "/tableOfContents")
        XCTAssertTrue(window.firstResponder === text)
        XCTAssertTrue(panel.isVisible)
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        text.keyDown(with: tab)
        for _ in 0..<200 where model.blocks.first?.kind != .tableOfContents { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.first?.kind, .tableOfContents)
        await model.flushAll()
    }

    func testHostedSlashPopupOwnsClickRegionAndTableButtonWorks() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let panel = try XCTUnwrap(window.childWindows?.first { $0 is EditorPopupPanel })
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        // The first filtered row is centered 68pt below the top of the popup.
        // Send real AppKit mouse events, not the model's conversion method.
        let local = NSPoint(x: content.bounds.midX, y: content.isFlipped ? 68 : content.bounds.height - 68)
        let hit = try XCTUnwrap(content.hitTest(local))
        XCTAssertTrue(hit.window === panel, "Below-row menu clicks must belong to the popup, not the next paragraph")
        let point = content.convert(local, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: time, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: time + 0.01, windowNumber: panel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        panel.sendEvent(down)
        for _ in 0..<200 where model.blocks.first?.kind != .table { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.blocks.first?.kind, .table)
        await model.flushAll()
    }

    func testTableEdgeAppendUsesLiveCellsAndPreservesDimensions() async throws {
        let (_, store, model, original) = try await fixture()
        model.insertSlashCommand(.table, in: original[0])
        await model.flushAll()
        let table = try XCTUnwrap(model.blocks.first)
        model.changeText(#"[["`方法`","说明"],["数据","内容"]]"#, in: table)
        model.changeTableLayout(TableLayout(columnWidths: [240, 300], rowHeights: [60, 80]), in: table)
        model.appendTableAxes(row: false, column: true, in: table)
        model.appendTableAxes(row: true, column: false, in: table)
        model.appendTableAxes(row: true, column: true, in: table)
        let current = try XCTUnwrap(model.blocks.first)
        let cells = try JSONDecoder().decode([[String]].self, from: Data(current.text.utf8))
        XCTAssertEqual(cells.count, 4)
        XCTAssertTrue(cells.allSatisfy { $0.count == 4 })
        XCTAssertEqual(cells[0], ["方法", "说明", "", ""])
        XCTAssertEqual(current.tableLayout.columnWidths, [240, 300, 160, 160])
        XCTAssertEqual(current.tableLayout.rowHeights, [60, 80, 44, 44])
        XCTAssertTrue(current.tableLayout.cellsArePlain)
        await model.flushAll()
        let saved = try await store.blocks(in: table.pageID)
        XCTAssertEqual(saved.first, current)
    }

    func testCommonCodeLanguagesAliasesAndLanguageSpecificTokens() {
        for (alias, language) in [("py", "Python"), ("ts", "TypeScript"), ("cpp", "C++"), ("cs", "C#"),
                                  ("sh", "Bash"), ("yml", "YAML"), ("ps1", "PowerShell"), ("objc", "Objective-C")] {
            XCTAssertEqual(CodeLanguage.canonical(alias), language)
        }
        func pieces(_ source: String, _ language: String, _ kind: String) -> [String] {
            CodeSyntax.tokens(source, language: language).filter { $0.kind == kind }.map { (source as NSString).substring(with: $0.range) }
        }
        XCTAssertEqual(pieces("select 'http://x--y' -- comment", "SQL", "comment"), ["-- comment"])
        XCTAssertEqual(pieces("select true", "sql", "keyword"), ["select"])
        XCTAssertEqual(pieces("const url = \"http://x/#y\"; // note", "js", "comment"), ["// note"])
        XCTAssertEqual(pieces("def f():\n  return \"# text\" # note", "py", "comment"), ["# note"])
        XCTAssertEqual(pieces("interface User { readonly name: string }", "ts", "keyword"), ["interface", "readonly", "string"])
        XCTAssertEqual(pieces("<!-- note --><div>Hello</div>", "HTML", "markup"), ["<div>", "</div>"])
        XCTAssertEqual(pieces("FROM alpine\n# build\nRUN echo ok", "dockerfile", "keyword"), ["FROM", "RUN"])
        XCTAssertEqual(pieces("-- comment\nlocal x = nil", "Lua", "comment"), ["-- comment"])
        XCTAssertTrue(CodeSyntax.tokens("let x = 42", language: "txt").isEmpty)
        let languages = CodeLanguage.groups.flatMap(\.languages)
        XCTAssertEqual(Set(languages).count, languages.count)
        for language in languages where language != "Plain Text" {
            XCTAssertFalse(CodeSyntax.tokens("# Title\n// note\n-- note\nlet value = \"text\";\n123", language: language).isEmpty, language)
        }
    }

    func testHostedTableReferenceFocusAndRailsRender() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let original = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.table, in: original)
        model.changeTableCells([["", ""], ["", ""]], in: original)
        model.changeTableLayout(TableLayout(columnWidths: [320, 320], rowHeights: [70, 70], cellsArePlain: true), in: original)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var editors: [CodeTextView] = []
        for _ in 0..<100 {
            editors = window.contentView.map { descendants($0).compactMap { $0 as? CodeTextView } } ?? []
            if editors.count >= 4 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(editors.count, 4)
        try await Task.sleep(for: .milliseconds(100))
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(editors[2]))
        try await Task.sleep(for: .milliseconds(100))
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/table-reference-native.png")
        try data.write(to: output)
        await model.flushAll()
    }

    func testTableLayoutLimitsAndStructureChanges() throws {
        let layout = TableLayout(columnWidths: [240, -20, .infinity], rowHeights: [96, -5, .nan])
        XCTAssertEqual(layout.columnWidths, [240, 72, 160])
        XCTAssertEqual(layout.rowHeights, [96, 36, 44])
        let fitted = layout.fitted(rows: 2, columns: 4)
        XCTAssertEqual(fitted.columnWidths, [240, 72, 160, 160])
        XCTAssertEqual(fitted.rowHeights, [96, 36])
        let old = try JSONDecoder().decode(TransferBlock.self, from: Data(#"{"kind":"table","text":"[[\"A\",\"B\"]]"}"#.utf8))
        XCTAssertEqual(old.tableLayout.column(0), 160)
        XCTAssertEqual(old.tableLayout.row(0), 44)
    }

    func testNativeTableContextMenuIncludesAxisDeletionWithoutReplacingTextActions() throws {
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var rowDeleted = false, columnDeleted = false
        view.deleteTableRowAction = { rowDeleted = true }
        view.deleteTableColumnAction = { columnDeleted = true }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(view.menu(for: event))
        let row = try XCTUnwrap(menu.items.first { $0.action == #selector(CodeTextView.deleteTableRowFromMenu(_:)) })
        let column = try XCTUnwrap(menu.items.first { $0.action == #selector(CodeTextView.deleteTableColumnFromMenu(_:)) })
        XCTAssertTrue(row.target === view); XCTAssertTrue(column.target === view)
        XCTAssertTrue(menu.items.contains { $0.action == #selector(NSText.paste(_:)) })
        view.perform(try XCTUnwrap(row.action), with: row)
        view.perform(try XCTUnwrap(column.action), with: column)
        XCTAssertTrue(rowDeleted); XCTAssertTrue(columnDeleted)
    }

    func testDeleteArbitraryTableAxesPreservesCellsDimensionsAndPersistence() async throws {
        let (_, store, model, _) = try await fixture()
        let original = try XCTUnwrap(model.blocks.first)
        model.insertSlashCommand(.table, in: original)
        await model.flushAll()
        let table = try XCTUnwrap(model.blocks.first)
        model.changeTableCells([["甲", "乙", "丙"], ["1", "2", "3"], ["`literal`", "a|b", "余下"]], in: table)
        model.changeTableLayout(TableLayout(columnWidths: [100, 200, 300], rowHeights: [40, 80, 120], cellsArePlain: true), in: table)
        // Use the same stale view snapshot repeatedly; mutations must read live state.
        model.deleteTableRow(1, in: table)
        model.deleteTableColumn(1, in: table)
        var current = try XCTUnwrap(model.blocks.first)
        XCTAssertEqual(current.text, #"[["甲","丙"],["`literal`","余下"]]"#)
        XCTAssertEqual(current.tableLayout.columnWidths, [100, 300])
        XCTAssertEqual(current.tableLayout.rowHeights, [40, 120])
        XCTAssertTrue(current.tableLayout.cellsArePlain)
        model.deleteTableRow(-1, in: table); model.deleteTableColumn(99, in: table)
        XCTAssertEqual(model.blocks.first, current)
        model.deleteTableRow(0, in: table); model.deleteTableColumn(0, in: table)
        current = try XCTUnwrap(model.blocks.first)
        XCTAssertEqual(current.text, #"[["余下"]]"#)
        XCTAssertEqual(current.tableLayout.columnWidths, [300])
        XCTAssertEqual(current.tableLayout.rowHeights, [120])
        model.deleteTableRow(0, in: table); model.deleteTableColumn(0, in: table)
        XCTAssertEqual(model.blocks.first, current, "Keep at least one cell")
        await model.flushAll()
        let saved = try await store.blocks(in: current.pageID)
        XCTAssertEqual(saved.first, current)
    }

    func testTableLiteralCharactersStayPlainAfterEditingResizeAndReopen() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/TableCellText-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let page = try await store.createPage()
        let table = try await store.createBlock(pageID: page.id, kind: .table)
        try await store.updateBlock(table.id, text: #"[["方法","作用"],["` add() `","添加消息"]]"#)
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(TableCellContent.visible("` add() `", layout: model.blocks[0].tableLayout), "add()")
        model.changeTableCells([["方法", "作用"], ["`literal`", "a|b"]], in: table)
        model.resizeTable(column: 0, size: 240, in: table)
        await model.flushAll()
        let saved = try await store.blocks(in: page.id)
        XCTAssertTrue(saved[0].tableLayout.cellsArePlain)
        XCTAssertEqual(saved[0].tableLayout.column(0), 240)
        let rows = try JSONDecoder().decode([[String]].self, from: Data(saved[0].text.utf8))
        XCTAssertEqual(rows[1], ["`literal`", "a|b"])
        XCTAssertEqual(TableCellContent.visible(rows[1][0], layout: saved[0].tableLayout), "`literal`")
        let decoded = try JSONDecoder().decode(TransferBlock.self, from: JSONEncoder().encode(TransferBlock(saved[0])))
        XCTAssertTrue(decoded.tableLayout.cellsArePlain)
        XCTAssertTrue(decoded.tableLayout.fitted(rows: 3, columns: 3).cellsArePlain)
    }

    func testTableDimensionsSurviveTypingSwitchReopenAndJSONImport() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/TableLayout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.sqlite")
        let store = try SQLiteStore(databaseURL: file)
        let page = try await store.createPage()
        let other = try await store.createPage()
        let original = try await store.createBlock(pageID: page.id, kind: .table)
        try await store.updateBlock(original.id, text: BlockKind.table.initialText)
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<200 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let layout = TableLayout(columnWidths: [280, 112], rowHeights: [80, 120])
        model.changeTableLayout(layout, in: original)
        model.changeText(#"[["First","Second"],["Body","Value"]]"#, in: original)
        model.select(other.id)
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: file)
        let saved = try await reopened.blocks(in: page.id)
        XCTAssertEqual(saved.first?.tableLayout, layout)
        XCTAssertTrue(saved.first?.text.contains("Value") == true)
        let snapshot = try await reopened.transferSnapshot(name: "layout", pageID: page.id)
        let decoded = try JSONDecoder().decode(TransferDocument.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.pages.first?.blocks.first?.tableLayout, layout)
        let ids = try await reopened.importTransfer(decoded)
        let imported = try await reopened.blocks(in: XCTUnwrap(ids.first))
        XCTAssertEqual(imported.first?.tableLayout, layout)
        let replaced = try await reopened.replaceBlock(original.id, pageID: page.id, with: decoded.pages[0].blocks)
        XCTAssertEqual(replaced.first?.tableLayout, layout)
    }

    func testTableContentReflowsAndRowHeightFollowsColumnWidth() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close() }
        let input = try XCTUnwrap(window.firstResponder as? NSTextView)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        input.keyDown(with: enter)
        for _ in 0..<200 where model.blocks.first?.kind != .table { try await Task.sleep(for: .milliseconds(5)) }
        let block = try XCTUnwrap(model.blocks.first)
        let source = String(repeating: "表格内容应随宽度自动换行，不丢失文字。", count: 5)
        model.changeTableCells([[source, "相邻列"], ["正文", "保留"]], in: block)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func cellHeight() -> CGFloat {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentView.flatMap { root in descendants(root).compactMap { $0 as? TableResizeGripView }
                .filter { $0.identifier?.rawValue == "table-column-0" }.map { $0.bounds.height }.max() } ?? 0
        }
        model.resizeTable(column: 0, size: 90, in: block)
        for _ in 0..<200 where cellHeight() < 100 { try await Task.sleep(for: .milliseconds(5)) }
        let narrow = cellHeight()
        XCTAssertGreaterThan(narrow, 100)
        model.resizeTable(column: 0, size: 480, in: block)
        for _ in 0..<200 where cellHeight() >= narrow { try await Task.sleep(for: .milliseconds(5)) }
        let wide = cellHeight()
        XCTAssertGreaterThanOrEqual(wide, 44)
        XCTAssertLessThan(wide, narrow)
        model.resizeTable(row: 0, size: 400, in: block)
        for _ in 0..<200 where cellHeight() < 400 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(cellHeight(), 400)
        model.resizeTable(row: 0, size: 36, in: block)
        for _ in 0..<200 where cellHeight() >= 400 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(cellHeight(), 36, "Row cannot clip wrapped content when manually reduced")
        XCTAssertTrue(model.blocks[0].text.contains(source))
        await model.flushAll()
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await store.blocks(in: block.pageID)
        XCTAssertEqual(saved.first?.text, model.blocks.first?.text)
        if let root = window.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.deletingLastPathComponent().appendingPathComponent("table-responsive.png"))
        }
    }

    func testHostedTableResizeUsesRealDragEventsAndPersistsBothAxes() async throws {
        let (window, model, directory) = try await slashPopupFixture(command: "")
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        // This test exercises resize tracking, not popup focus. Build its table
        // directly so another app gaining focus cannot cancel fixture setup.
        model.insertSlashCommand(.table, in: try XCTUnwrap(model.blocks.first))
        await model.flushAll()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func grip(_ identifier: String) async throws -> TableResizeGripView {
            for _ in 0..<200 {
                window.contentView?.layoutSubtreeIfNeeded()
                if let root = window.contentView, let view = descendants(root).compactMap({ $0 as? TableResizeGripView }).first(where: { $0.identifier?.rawValue == identifier }) { return view }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw NSError(domain: "Missing resize grip", code: 1)
        }
        func drag(_ view: TableResizeGripView, dx: CGFloat, dy: CGFloat) throws {
            let raw = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            // Synthetic window events snap fractional positions; use a whole-point
            // origin so the requested drag distance remains exact.
            let origin = NSPoint(x: raw.x.rounded(), y: raw.y.rounded())
            let end = NSPoint(x: origin.x + dx, y: origin.y + dy)
            let time = ProcessInfo.processInfo.systemUptime
            func event(_ type: NSEvent.EventType, _ point: NSPoint, _ offset: Double) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time + offset,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            NSApp.postEvent(try event(.leftMouseUp, end, 0.02), atStart: true)
            NSApp.postEvent(try event(.leftMouseDragged, end, 0.01), atStart: true)
            window.sendEvent(try event(.leftMouseDown, origin, 0))
        }
        let column = try await grip("table-column-0")
        try drag(column, dx: 64, dy: 0)
        let resizedWidth = try XCTUnwrap(model.blocks.first?.tableLayout.column(0))
        XCTAssertEqual(resizedWidth, 224, accuracy: 1, "Window event conversion can quantize a drag by one point")
        let row = try await grip("table-row-0")
        try drag(row, dx: 0, dy: -32)
        XCTAssertEqual(try XCTUnwrap(model.blocks.first?.tableLayout.row(0)), 76, accuracy: 1)
        XCTAssertEqual(model.blocks.first?.tableLayout.column(0), resizedWidth, "A subsequent row drag must preserve the column width exactly")
        XCTAssertEqual(model.blocks.first?.tableLayout.column(1), 160)
        XCTAssertEqual(model.blocks.first?.tableLayout.row(1), 44)
        await model.flushAll()
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: XCTUnwrap(model.selectedPageID))
        XCTAssertEqual(saved.first?.tableLayout, model.blocks.first?.tableLayout)
        try await Task.sleep(for: .milliseconds(80))
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.deletingLastPathComponent().appendingPathComponent("table-resize.png"))
        }
    }

    func testVerticalScrollPassesNestedEditorAndPreviewButPreservesHorizontalAndSidebar() throws {
        let router = DocumentScrollRoutingView()
        let page = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1600))
        page.documentView = content
        content.addSubview(router)
        let editor = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        let text = NSTextView(frame: editor.bounds)
        editor.documentView = text; content.addSubview(editor)
        let preview = WKWebView(frame: NSRect(x: 0, y: 200, width: 500, height: 200))
        content.addSubview(preview)
        func wheel(_ x: Int32, _ y: Int32, pixels: Bool = true) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: pixels ? .pixel : .line,
                                          wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        for precise in [true, false] {
            for delta: Int32 in [-20, 20] {
                let event = try wheel(0, delta, pixels: precise)
                XCTAssertTrue(router.verticalScrollTarget(for: event, hit: text, page: page) === page)
                XCTAssertTrue(router.verticalScrollTarget(for: event, hit: preview, page: page) === page)
                XCTAssertTrue(router.verticalScrollTarget(for: event, hit: content, page: page) === page)
            }
        }
        XCTAssertNil(router.verticalScrollTarget(for: try wheel(20, 1), hit: preview, page: page))
        XCTAssertNil(router.verticalScrollTarget(for: try wheel(0, 20), hit: NSView(), page: page))
        // Zero-delta gesture endings still reach the page after a vertical scroll.
        _ = router.verticalScrollTarget(for: try wheel(0, -20), hit: text, page: page)
        XCTAssertTrue(router.verticalScrollTarget(for: try wheel(0, 0), hit: text, page: page) === page)
        router.stopMonitoring()
    }

    func testHostedPageActuallyScrollsOverAutoSizedTextEditor() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/Scroll-" + UUID().uuidString)
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let page = try await store.createPage()
        let block = try await store.createBlock(pageID: page.id, kind: .paragraph)
        try await store.updateBlock(block.id, text: String(repeating: "SCROLL_FIXTURE long paragraph\n", count: 120))
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<100 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PageEditorView(model: model, page: page))
        window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(host)
        let router = try XCTUnwrap(views.compactMap { $0 as? DocumentScrollRoutingView }.first)
        let outer = try XCTUnwrap(router.enclosingScrollView)
        let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { $0.string.contains("SCROLL_FIXTURE") })
        XCTAssertGreaterThan(try XCTUnwrap(outer.documentView).bounds.height, outer.contentView.bounds.height)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -160, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        let target = try XCTUnwrap(router.verticalScrollTarget(for: event, hit: text, page: outer))
        let before = outer.contentView.bounds.origin.y
        target.scrollWheel(with: event)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotEqual(outer.contentView.bounds.origin.y, before)
    }

    func testHostedBottomTableRepeatedScrollingSettlesWithoutHeightFeedback() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/BottomTable-" + UUID().uuidString)
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let page = try await store.createPage()
        var previous: Block?
        for index in 0..<8 {
            let block = try await store.createBlock(pageID: page.id, kind: .paragraph, after: previous)
            try await store.updateBlock(block.id, text: String(repeating: "滚动测试 \(index) 长正文\n", count: 20))
            previous = block
        }
        let table = try await store.createBlock(pageID: page.id, kind: .table, after: previous)
        let cells = (0..<8).map { row in (0..<4).map { "第\(row)行第\($0)列\n" + String(repeating: "多行内容\n", count: row == 7 ? 5 : 1) } }
        let text = String(decoding: try JSONEncoder().encode(cells), as: UTF8.self)
        try await store.updateBlock(table.id, text: text, tableLayout: TableLayout(cellsArePlain: true))
        let model = WorkspaceModel(store: store)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<100 where model.blocks.count < 9 { try await Task.sleep(for: .milliseconds(5)) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PageEditorView(model: model, page: page))
        window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let router = try XCTUnwrap(descendants(host).compactMap { $0 as? DocumentScrollRoutingView }.first)
        let outer = try XCTUnwrap(router.enclosingScrollView)
        let document = try XCTUnwrap(outer.documentView)
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0))
        let wheel = try XCTUnwrap(NSEvent(cgEvent: cg))
        var heights: [CGFloat] = []
        for step in 0..<30 {
            host.layoutSubtreeIfNeeded()
            let bottom = max(0, document.bounds.height - outer.contentView.bounds.height)
            outer.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
            outer.reflectScrolledClipView(outer.contentView)
            outer.scrollWheel(with: wheel)
            try await Task.sleep(for: .milliseconds(40))
            if step >= 20 { heights.append(document.bounds.height) }
        }
        XCTAssertLessThanOrEqual((heights.max() ?? 0) - (heights.min() ?? 0), 2)
        XCTAssertTrue(descendants(host).compactMap { $0 as? CodeTextView }.contains { $0.string.contains("第7行") })
        let rowEditor = try XCTUnwrap(descendants(host).compactMap { $0 as? CodeTextView }.first { $0.string.hasPrefix("第1行第0列") })
        rowEditor.deleteTableRowFromMenu(nil)
        try await Task.sleep(for: .milliseconds(100))
        let updated = try XCTUnwrap(model.blocks.first { $0.id == table.id })
        XCTAssertEqual(try JSONDecoder().decode([[String]].self, from: Data(updated.text.utf8)).count, 7)
        for _ in 0..<10 {
            let bottom = max(0, document.bounds.height - outer.contentView.bounds.height)
            outer.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
            outer.reflectScrolledClipView(outer.contentView)
            try await Task.sleep(for: .milliseconds(30))
        }
        let lastCell = try XCTUnwrap(descendants(host).compactMap { $0 as? CodeTextView }.first { $0.string.hasPrefix("第7行第0列") })
        XCTAssertGreaterThan(try XCTUnwrap(lastCell.enclosingScrollView).frame.height, 80)
        await model.flushAll()
    }

    func testEmptyBlocksHideControlsAndStructuralBlocksRemainUsable() {
        var block = Block(id: UUID(), pageID: UUID(), kind: .paragraph, text: " \n\t", order: 1024, checked: false)
        XCTAssertFalse(block.hasContent)
        block.text = "内容"; XCTAssertTrue(block.hasContent)
        block.kind = .table; block.text = #"[["", " "], ["", ""]]"#
        XCTAssertFalse(block.hasContent)
        block.text = #"[["名称", ""], ["", ""]]"#; XCTAssertTrue(block.hasContent)
        block.text = ""; block.kind = .divider; XCTAssertTrue(block.hasContent)
        block.kind = .tableOfContents; XCTAssertTrue(block.hasContent)
    }

    func testHeightMeasurementSkipsUnchangedContentAndInvalidatesForWidthAndText() {
        var heights: [CGFloat] = []
        let font = NSFont.systemFont(ofSize: 17)
        let editor = NativeTextEditor(text: "内容", font: font, onHeightChange: { heights.append($0) }, onChange: { _ in })
        let coordinator = NativeTextEditor.Coordinator(parent: editor)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.font = font; view.string = "内容"
        view.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        coordinator.measure(view)
        for _ in 0..<100 { coordinator.measure(view) }
        XCTAssertEqual(heights.count, 1)
        view.string = String(repeating: "更多内容", count: 100)
        coordinator.measure(view)
        XCTAssertEqual(heights.count, 2)
        XCTAssertGreaterThan(heights[1], heights[0])
        view.textContainer?.containerSize.width = 150
        coordinator.measure(view)
        XCTAssertEqual(heights.count, 3)
        XCTAssertGreaterThan(heights[2], heights[1])
    }

    func testOfflineMarkdownAndLaTeXRendering() async throws {
        let loaded = expectation(description: "Local renderer loaded")
        let loader = RenderTestLoader(loaded)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(loader, name: "layout")
        configuration.userContentController.add(loader, name: "copy")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 200), configuration: configuration)
        view.navigationDelegate = loader
        let url = try XCTUnwrap(RichBlockPreview.documentURL)
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        await fulfillment(of: [loaded], timeout: 20)
        XCTAssertNil(loader.failure)
        let sample = #"""
        ## 数学笔记
        行内公式 \(x^2 + y^2\)，以及 $E=mc^2$。

        \[
        \int_0^1 x^2\,dx=\frac{1}{3}
        \]

        | 项目 | 数值 |
        | --- | --- |
        | 结果 | 1/3 |

        ```python
        print("<script> and $literal$")
        ```
        <script>window.attacked=true</script>
        <img src="https://example.invalid/tracker" onerror="window.attacked=true">
        """#
        _ = try await view.callAsyncJavaScript("return renderContent(source, false, true, 17)", arguments: ["source": sample], in: nil, contentWorld: .page)
        let value = try await view.evaluateJavaScript("({math:document.querySelectorAll('.katex').length, tables:document.querySelectorAll('.table-scroll table').length, code:document.querySelector('pre code').textContent, scripts:document.querySelectorAll('#content script').length, images:document.querySelectorAll('#content img').length, attacked:!!window.attacked,dark:document.documentElement.classList.contains('dark'),height:document.querySelector('#content').getBoundingClientRect().height})")
        let result = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(result["math"] as? Int, 3)
        XCTAssertEqual(result["tables"] as? Int, 1)
        XCTAssertTrue((result["code"] as? String)?.contains("$literal$") == true)
        XCTAssertEqual(result["scripts"] as? Int, 0)
        XCTAssertEqual(result["images"] as? Int, 1)
        XCTAssertEqual(result["attacked"] as? Bool, false)
        XCTAssertEqual(result["dark"] as? Bool, true)
        XCTAssertGreaterThan(result["height"] as? Double ?? 0, 100)
        let resized = try await view.callAsyncJavaScript("""
            const code = document.querySelector('pre code');
            const rendered = await renderContent(source, false, true, 22);
            return rendered && code === document.querySelector('pre code')
                && getComputedStyle(document.body).fontSize === '22px';
            """, arguments: ["source": sample], in: nil, contentWorld: .page)
        XCTAssertEqual(resized as? Bool, true, "Changing only font size should preserve the rendered content")

        let superseded = try await view.callAsyncJavaScript("""
            const code = document.querySelector('pre code');
            const oldRender = renderContent('Superseded text', false, false, 17);
            const latestRender = renderContent(source, false, true, 17);
            return (await oldRender) === false && (await latestRender)
                && code === document.querySelector('pre code');
            """, arguments: ["source": sample], in: nil, contentWorld: .page)
        XCTAssertEqual(superseded as? Bool, true, "Queued renders should skip superseded content")

        _ = try await view.callAsyncJavaScript("return renderContent(source, true, false, 17)", arguments: ["source": #"\[\begin{pmatrix}a&b\\c&d\end{pmatrix}\]"#], in: nil, contentWorld: .page)
        let matrix = try await view.evaluateJavaScript("document.querySelectorAll('.katex .mtable').length")
        XCTAssertGreaterThan(matrix as? Int ?? 0, 0)
        _ = try await view.callAsyncJavaScript("return renderContent(source, true, false, 17)", arguments: ["source": #"\frac{"#], in: nil, contentWorld: .page)
        let invalid = try await view.evaluateJavaScript("document.querySelector('#content').textContent")
        XCTAssertTrue((invalid as? String)?.contains("公式语法错误") == true)
        _ = try await view.callAsyncJavaScript("return renderContent(source, false, false, 17, 'en')", arguments: ["source": "```swift\nprint(1)\n```"], in: nil, contentWorld: .page)
        let copyLabel = try await view.evaluateJavaScript("document.querySelector('.code-header button').textContent")
        XCTAssertEqual(copyLabel as? String, "Copy code")
        _ = try await view.evaluateJavaScript("document.querySelector('.code-header button').click()")
        for _ in 0..<100 where loader.copies.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(loader.copies.last?["language"] as? String, "swift")
        XCTAssertEqual(loader.copies.last?["text"] as? String, "print(1)\n")
        _ = try await view.evaluateJavaScript("""
        (()=>{const node=document.querySelector('pre code');const range=document.createRange();range.selectNodeContents(node);
        window.getSelection().removeAllRanges();window.getSelection().addRange(range);
        document.dispatchEvent(new Event('copy',{cancelable:true}));})()
        """)
        for _ in 0..<100 where loader.copies.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(loader.copies.last?["selection"] as? Bool, true)
        XCTAssertEqual(loader.copies.last?["text"] as? String, "print(1)\n")

        _ = try await view.callAsyncJavaScript("return renderContent(source, true, false, 17, 'en')", arguments: ["source": #"\frac{"#], in: nil, contentWorld: .page)
        let englishError = try await view.evaluateJavaScript("document.querySelector('#content').textContent")
        XCTAssertTrue((englishError as? String)?.hasPrefix("Equation syntax error:") == true)
        view.stopLoading()
        configuration.userContentController.removeAllScriptMessageHandlers()
    }

    func testMathAndCalloutMarkdownRoundTrip() async throws {
        let source = #"""
        # 公式笔记

        $$
        \frac{a}{b}
        $$

        结论为 \(x^2\)，**注意**量纲。

        > [!WARNING]
        > 请检查单位

        > [!TIP]
        > 已完成验证
        """#
        let document = try DocumentTransfer.markdown(source, title: "fallback")
        XCTAssertEqual(document.pages[0].blocks.map(\.kind), [.equation, .markdown, .warning, .success])
        XCTAssertEqual(document.pages[0].blocks[0].text, #"\frac{a}{b}"#)
        let exported = try DocumentExporter.markdown(document.pages[0], assetDirectory: URL(fileURLWithPath: "/unused"))
        let restored = try DocumentTransfer.markdown(exported, title: "fallback")
        XCTAssertEqual(restored.pages[0].blocks, document.pages[0].blocks)
        let json = try JSONDecoder().decode(TransferDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(json.pages[0].blocks, document.pages[0].blocks)
    }

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

    func testDuplicateSelectionFlushesEditsPreservesTypesAndSelectsCopies() async throws {
        let (_, store, model, original) = try await fixture()
        model.changeText("尚未自动保存", in: model.blocks[0])
        let ids: Set<UUID> = [original[0].id, original[1].id, original[3].id]
        try await model.duplicateBlocks(ids)
        XCTAssertEqual(model.blocks.count, original.count + ids.count)
        let copies = model.blocks.filter { model.selectedBlockIDs.contains($0.id) }
        XCTAssertEqual(copies.map(\.kind), [.paragraph, .code, .image])
        XCTAssertEqual(copies.first?.text, "尚未自动保存")
        XCTAssertTrue(model.selectedBlockIDs.isDisjoint(with: ids))
        let saved = try await store.blocks(in: original[0].pageID)
        XCTAssertEqual(saved, model.blocks)
        let snapshot = model.blocks
        do { try await model.duplicateBlocks([UUID()]); XCTFail("Stale selection must fail") } catch { }
        let unchanged = try await store.blocks(in: original[0].pageID)
        XCTAssertEqual(unchanged, snapshot)
    }

    func testBlockConversionProtectsStructuredPayloads() async throws {
        let (_, _, model, _) = try await fixture()
        let code = model.blocks[1]
        model.changeKind(.table, of: code)
        XCTAssertEqual(model.blocks[1], code)
        for source in BlockKind.allCases {
            for target in BlockKind.allCases {
                XCTAssertEqual(source.canConvert(to: target), source == target ||
                    (source.supportsProseConversion && target.supportsProseConversion) || (source == .code && target == .paragraph))
            }
        }
        let paragraph = model.blocks[0]
        model.changeKind(.quote, of: paragraph)
        XCTAssertEqual(model.blocks[0].kind, .quote)
        XCTAssertEqual(model.blocks[0].text, paragraph.text)
        await model.flushAll()
    }

    func testUnchangedTextDoesNotStartAutosave() async throws {
        let (_, _, model, _) = try await fixture()
        let block = try XCTUnwrap(model.blocks.first)
        XCTAssertFalse(model.saving)
        model.changeRichText(block.text, formatting: block.formatting, in: block)
        XCTAssertFalse(model.saving)
        model.changeText("新内容", in: block)
        XCTAssertTrue(model.saving)
        await model.flushAll()
        XCTAssertFalse(model.saving)
    }

    func testStructuredPasteCreatesNativeBlocksAndPreservesInlineText() async throws {
        let (_, store, model, _) = try await fixture()
        let target = try XCTUnwrap(model.blocks.first)
        model.pasteDocument(plain: "**加粗**", html: nil, original: target.text, formatting: [], selection: NSRange(location: 1, length: 0), in: target)
        for _ in 0..<100 where model.blocks.first?.id == target.id { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.blocks.first?.kind, .paragraph)
        XCTAssertEqual(model.blocks.first?.text, "内加粗容")
        XCTAssertTrue(model.blocks.first?.formatting.first?.style.bold == true)
        let restored = try await store.blocks(in: target.pageID)
        XCTAssertEqual(restored.first?.kind, .paragraph)
        XCTAssertEqual(restored.first?.text, "内加粗容")

        let second = try XCTUnwrap(model.blocks.first)
        let document = #"""
        # ChatGPT 标题

        正文包含 **重点**。

        - 第一项
        - 第二项

        $$
        \frac{a}{b}
        $$

        ```mermaid
        flowchart LR
          A --> B
        ```
        """#
        model.pasteDocument(plain: document, html: nil, original: second.text, formatting: second.formatting,
                            selection: NSRange(location: 0, length: second.text.utf16.count), in: second)
        for _ in 0..<100 where model.blocks.first?.kind != .heading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Array(model.blocks.prefix(6).map(\.kind)), [.heading, .paragraph, .bullet, .bullet, .equation, .code])
        XCTAssertEqual(model.blocks.first?.text, "ChatGPT 标题")
        XCTAssertTrue(model.blocks[1].formatting.contains { $0.style.bold == true })
        XCTAssertEqual(model.blocks[4].text, #"\frac{a}{b}"#)
        XCTAssertEqual(model.blocks[5].language.lowercased(), "mermaid")
        let persisted = try await store.blocks(in: target.pageID)
        XCTAssertEqual(persisted.map(\.kind), model.blocks.map(\.kind))
    }

    func testBlockDragRangeCanReverseShrinkAndCopyMixedKindsInDocumentOrder() async throws {
        let (_, store, model, original) = try await fixture()
        defer { NSPasteboard.general.clearContents() }
        model.selectBlockRange(from: original[4].id, through: original[0].id)
        XCTAssertEqual(model.selectedBlockIDs, Set(original.map(\.id)))
        model.selectBlockRange(from: original[4].id, through: original[2].id)
        XCTAssertEqual(model.selectedBlockIDs, Set(original[2...4].map(\.id)))
        model.copySelectedBlocks()
        let copied = try XCTUnwrap(ClipboardDocument.blocks(from: .general))
        XCTAssertEqual(copied.map(\.kind), [.divider, .image, .paragraph])
        model.selectBlockRange(from: original[1].id, through: original[3].id)
        XCTAssertEqual(model.selectedBlockIDs, Set(original[1...3].map(\.id)))
        model.copySelectedBlocks()
        XCTAssertEqual(ClipboardDocument.blocks(from: .general)?.map(\.kind), [.code, .divider, .image])
        try await model.deleteSelectedBlocks()
        let saved = try await store.blocks(in: original[0].pageID)
        XCTAssertEqual(saved.map(\.id), [original[0].id, original[4].id])
        XCTAssertTrue(model.selectedBlockIDs.isEmpty)
    }

    func testDocumentDragRouterKeepsLocalTextSelectionAndCrossesRowBoundaries() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let page = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let document = FlippedSelectionTestView(frame: NSRect(x: 0, y: 0, width: 600, height: 1000))
        page.documentView = document
        window.contentView = page
        let router = DocumentRangeSelectionView(frame: document.bounds)
        document.addSubview(router)
        let ids = [UUID(), UUID(), UUID()]
        var anchors: [DocumentBlockSelectionAnchorView] = []
        for index in 0..<3 {
            let text = CodeTextView(frame: NSRect(x: 80, y: CGFloat(20 + index * 90), width: 450, height: 60))
            text.string = "row \(index)"
            document.addSubview(text)
            let anchor = DocumentBlockSelectionAnchorView(frame: NSRect(x: 0, y: CGFloat(10 + index * 90), width: 600, height: 80))
            anchor.blockID = ids[index]
            document.addSubview(anchor)
            anchors.append(anchor)
        }
        window.makeKeyAndOrderFront(nil)
        page.contentView.scroll(to: .zero)
        var ranges: [(UUID, UUID)] = []
        router.selectRange = { ranges.append(($0, $1)) }
        func event(_ type: NSEvent.EventType, row: Int, x: CGFloat = 120) throws -> NSEvent {
            let point = anchors[row].convert(NSPoint(x: x, y: 30), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        XCTAssertNotNil(router.route(try event(.leftMouseDown, row: 0)))
        XCTAssertNotNil(router.route(try event(.leftMouseDragged, row: 0, x: 160)))
        XCTAssertTrue(ranges.isEmpty)
        XCTAssertNil(router.route(try event(.leftMouseDragged, row: 2)))
        XCTAssertTrue(router.selectingBlocks)
        XCTAssertEqual(ranges.last?.0, ids[0]); XCTAssertEqual(ranges.last?.1, ids[2])
        XCTAssertNil(router.route(try event(.leftMouseDragged, row: 1)))
        XCTAssertEqual(ranges.last?.0, ids[0]); XCTAssertEqual(ranges.last?.1, ids[1])
        XCTAssertNotNil(router.route(try event(.leftMouseUp, row: 1)))
        XCTAssertFalse(router.selectingBlocks)
        ranges.removeAll()
        XCTAssertNotNil(router.route(try event(.leftMouseDown, row: 0)))
        DocumentRangeSelectionView.finishNativeTracking(in: window, at: window.mouseLocationOutsideOfEventStream)
        XCTAssertTrue(ranges.isEmpty, "A click without pointer motion must not become a block drag")
        _ = router.route(try event(.leftMouseDown, row: 0))
        _ = router.route(try event(.leftMouseDragged, row: 2))
        let belowViewport = document.convert(NSPoint(x: 120, y: 500), to: nil)
        let edge = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: belowViewport, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(router.autoscrollSelection(with: edge))
        XCTAssertGreaterThan(page.contentView.bounds.minY, 0, "Dragging past the page edge should scroll the outer document")
        router.endDrag()
        page.contentView.scroll(to: .zero)
        let clickPoint = document.convert(try event(.leftMouseDown, row: 0).locationInWindow, from: nil)
        let button = NSButton(frame: NSRect(x: clickPoint.x - 10, y: clickPoint.y - 10, width: 120, height: 30))
        document.addSubview(button)
        ranges.removeAll()
        XCTAssertNotNil(router.route(try event(.leftMouseDown, row: 0)))
        XCTAssertNotNil(router.route(try event(.leftMouseDragged, row: 2)))
        XCTAssertTrue(ranges.isEmpty, "Buttons must retain their own click/drag interaction")
        router.stopMonitoring()
    }

    func testHostedRowGeometrySelectsAcrossHeadingCodeAndImage() async throws {
        let (window, model, _) = try await slashPopupFixture(command: "拖选起点")
        defer { window.close() }
        for (kind, text) in [(BlockKind.heading, "标题"), (.code, "let x = 1"), (.image, ""), (.paragraph, "拖选终点")] {
            let count = model.blocks.count
            model.addBlock(kind, after: model.blocks.last, text: text)
            for _ in 0..<200 where model.blocks.count == count { try await Task.sleep(for: .milliseconds(5)) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var anchors: [DocumentBlockSelectionAnchorView] = []
        for _ in 0..<200 {
            anchors = DocumentBlockSelectionAnchorView.visibleAnchors.allObjects.filter { $0.window === window }
            if anchors.count == model.blocks.count { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let router = try XCTUnwrap(descendants(root).compactMap { $0 as? DocumentRangeSelectionView }.first)
        let source = try XCTUnwrap(descendants(root).compactMap { $0 as? CodeTextView }.first { $0.string == "拖选起点" })
        let last = try XCTUnwrap(anchors.first { $0.blockID == model.blocks.last?.id })
        window.makeFirstResponder(source)
        func event(_ type: NSEvent.EventType, point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let down = try event(.leftMouseDown, point: source.convert(NSPoint(x: 5, y: 8), to: nil))
        let endpoint = last.convert(NSPoint(x: 150, y: 20), to: nil)
        XCTAssertNotNil(router.route(down))
        // NSTextView's completion hands its final pointer position to the page.
        router.finishNativeTracking(at: endpoint)
        // Finish our synthetic gesture explicitly. The user may be holding the
        // real mouse button while these hosted tests run on the desktop.
        _ = router.route(try event(.leftMouseUp, point: endpoint))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.selectedBlockIDs, Set(model.blocks.map(\.id)))
        XCTAssertFalse(router.selectingBlocks)
        await model.flushAll()
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

    func testSelectAllCanCopyWholeDocumentAsPlainAndHTML() async throws {
        let (_, _, model, original) = try await fixture()
        model.selectAllBlocks()
        XCTAssertEqual(model.selectedBlockIDs, Set(original.map(\.id)))
        model.copySelectedBlocks()
        let plain = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        let html = try XCTUnwrap(NSPasteboard.general.string(forType: .html))
        XCTAssertTrue(plain.contains("内容"))
        XCTAssertTrue(html.contains("<article>"))
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
        let markdown = RichInlineContent.markdown("A😀中文", runs: runs)
        let parsed = RichInlineContent.parseMarkdown(markdown)
        XCTAssertEqual(parsed.text, "A😀中文")
        XCTAssertTrue(parsed.runs.contains { $0.style.bold == true && $0.style.italic == true  })
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

@MainActor
private final class FlippedSelectionTestView: NSView {
    override var isFlipped: Bool { true }
}

private final class RenderTestLoader: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let loaded: XCTestExpectation
    var failure: Error?
    var copies: [[String: Any]] = []
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error; loaded.fulfill()
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "copy", let value = message.body as? [String: Any] { copies.append(value) }
    }
}
