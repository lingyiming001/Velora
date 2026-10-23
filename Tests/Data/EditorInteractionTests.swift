import AppKit
import XCTest
import WebKit
import SwiftUI
@testable import Velora

@MainActor
final class EditorInteractionTests: XCTestCase {
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
        try await capture(MovePagePanel(model: model, page: page), size: NSSize(width: 528, height: 518), name: "move-polish.png")
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




    func testShiftEnterFromLongTextBlockFocusesParagraphBelowWholeBlock() async throws {
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let source = String(repeating: "这是很长的一行正文，需要保留完整内容。\n", count: 90)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(source, replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: source.utf16.count / 2, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
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
            window.contentView.flatMap { root in descendants(root).compactMap { $0 as? TableResizeGripView }
                .first { $0.identifier?.rawValue == "table-column-0" }?.bounds.height } ?? 0
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
        let (window, model, directory) = try await slashPopupFixture()
        defer { window.close(); try? FileManager.default.removeItem(at: directory) }
        let text = try XCTUnwrap(window.firstResponder as? NSTextView)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        text.keyDown(with: enter)
        for _ in 0..<200 where model.blocks.first?.kind != .table { try await Task.sleep(for: .milliseconds(5)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func grip(_ identifier: String) async throws -> TableResizeGripView {
            for _ in 0..<200 {
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
