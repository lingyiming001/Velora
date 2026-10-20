import XCTest
@testable import Velora

final class SQLiteStoreTests: XCTestCase {
    func testInsertBlockAfterKeepsOrderAfterReopen() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/BlockInsertion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")
        let store = try SQLiteStore(databaseURL: url)
        let page = try await store.createPage()
        let first = try await store.createBlock(pageID: page.id, kind: .paragraph)
        let last = try await store.createBlock(pageID: page.id, kind: .code)
        let middle = try await store.createBlock(pageID: page.id, kind: .paragraph, after: first)
        let next = try await store.createBlock(pageID: page.id, kind: .todo, after: first)
        let reopened = try SQLiteStore(databaseURL: url)
        let blocks = try await reopened.blocks(in: page.id)
        XCTAssertEqual(blocks.map(\.id), [first.id, next.id, middle.id, last.id])
        XCTAssertEqual(Set(blocks.map(\.order)).count, 4)
    }

    @MainActor
    func testAssistantCompletionURLs() throws {
        let cases = [
            (" https://maas.qianwenaiapi.com/compatible-mode/v1 ", "https://maas.qianwenaiapi.com/compatible-mode/v1/chat/completions"),
            ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
            ("https://example.com", "https://example.com/v1/chat/completions"),
            ("http://localhost:11434/v1", "http://localhost:11434/v1/chat/completions"),
            ("https://example.com/custom/chat/completions?api-version=1", "https://example.com/custom/chat/completions?api-version=1")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try AssistantService.completionURL(input).absoluteString, expected)
        }
        for input in ["", "not a URL", "http://example.com/v1", "https://user:password@example.com/v1"] {
            XCTAssertThrowsError(try AssistantService.completionURL(input))
        }
    }

    func testPageBlockPersistenceAndSearchAfterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")

        let first = try SQLiteStore(databaseURL: url)
        let page = try await first.createPage()
        try await first.renamePage(page.id, title: "研究笔记")
        let block = try await first.createBlock(pageID: page.id, kind: .paragraph)
        try await first.updateBlock(block.id, text: "本地优先知识管理")

        let reopened = try SQLiteStore(databaseURL: url)
        let pages = try await reopened.pages()
        let blocks = try await reopened.blocks(in: page.id)
        let found = try await reopened.search("知识管理")
        XCTAssertEqual(pages.first?.title, "研究笔记")
        XCTAssertEqual(blocks.first?.text, "本地优先知识管理")
        XCTAssertEqual(found.map(\.id), [page.id])
    }

    func testArchiveRemovesPageFromDefaultSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let page = try await store.createPage()
        let child = try await store.createPage(parentID: page.id)
        try await store.renamePage(page.id, title: "待归档")
        try await store.archivePage(page.id, archived: true)
        let found = try await store.search("待归档")
        XCTAssertTrue(found.isEmpty)
        let allPages = try await store.pages()
        XCTAssertTrue(allPages.first(where: { $0.id == page.id })?.archived == true)
        XCTAssertTrue(allPages.first(where: { $0.id == child.id })?.archived == true)
    }
}

@MainActor
final class WorkspaceManagementTests: XCTestCase {
    private func fixture() throws -> (URL, ApplicationServices) {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/WorkspaceManagement-" + UUID().uuidString)
        let services = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"),
            legacyDatabaseURL: directory.appendingPathComponent("legacy/velora.sqlite"), startBackgroundServices: false)
        XCTAssertNil(services.startupError)
        return (directory, services)
    }

    func testCreateSwitchFlushEditAndRestart() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let originalStore = try XCTUnwrap(services.store)
        let originalModel = try XCTUnwrap(services.model)
        let page = try await originalStore.createPage()
        let block = try await originalStore.createBlock(pageID: page.id, kind: .paragraph)
        await originalModel.refreshPages()
        originalModel.select(page.id)
        // Allow the editor's asynchronous block loading to finish before editing.
        for _ in 0..<100 where !originalModel.blocks.contains(where: { $0.id == block.id }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(originalModel.blocks.contains(where: { $0.id == block.id }))
        originalModel.changeText("切换前尚未防抖保存的正文", in: block)
        XCTAssertTrue(originalModel.saving)
        try await services.createWorkspace(name: "  研发  ", summary: "项目资料", symbol: "briefcase.fill", color: "blue")
        let created = try XCTUnwrap(services.currentWorkspace)
        XCTAssertEqual(created.name, "研发")
        XCTAssertNotEqual(created.databasePath, original.databasePath)
        let newPages = try await XCTUnwrap(services.store).pages()
        XCTAssertTrue(newPages.isEmpty)
        let saved = try await originalStore.blocks(in: page.id)
        XCTAssertEqual(saved.first?.text, "切换前尚未防抖保存的正文")
        XCTAssertFalse(originalModel.saving)
        var edited = created
        edited.name = "产品研发"; edited.summary = "团队知识库"; edited.symbol = "book.fill"; edited.color = "green"
        edited.databasePath = "/must-not-change.sqlite"
        try services.updateWorkspace(edited)
        XCTAssertEqual(services.currentWorkspace?.databasePath, created.databasePath)
        try await services.switchWorkspace(original.id)
        let originalPages = try await XCTUnwrap(services.store).pages()
        XCTAssertEqual(originalPages.map(\.id), [page.id])
        let restarted = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"),
            legacyDatabaseURL: directory.appendingPathComponent("ignored.sqlite"), startBackgroundServices: false)
        XCTAssertEqual(restarted.currentWorkspace?.id, original.id)
        let persisted = try XCTUnwrap(restarted.workspaces.first { $0.id == created.id })
        XCTAssertEqual(persisted.name, "产品研发")
        XCTAssertEqual(persisted.summary, "团队知识库")
        XCTAssertEqual(persisted.symbol, "book.fill")
        XCTAssertEqual(persisted.color, "green")
    }

    func testDeleteActivePreservesDataAndRejectsLastWorkspace() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        try await services.createWorkspace(name: "临时空间", summary: "", symbol: "star.fill", color: "orange")
        let created = try XCTUnwrap(services.currentWorkspace)
        let createdStore = try XCTUnwrap(services.store)
        let page = try await createdStore.createPage()
        try await services.deleteWorkspace(created.id)
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
        XCTAssertEqual(services.workspaces.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.databasePath))
        let preserved = try await createdStore.pages()
        XCTAssertEqual(preserved.map(\.id), [page.id])
        XCTAssertEqual(services.catalog?.removedWorkspaces.first?.id, created.id)
        do { try await services.deleteWorkspace(original.id); XCTFail("Last workspace deletion should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("至少")) }
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
    }

    func testMissingDatabaseSwitchLeavesCurrentWorkspaceUsable() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        try await services.createWorkspace(name: "第二空间", summary: "", symbol: "house.fill", color: "pink")
        let second = try XCTUnwrap(services.currentWorkspace)
        var catalog = try XCTUnwrap(services.catalog)
        let index = try XCTUnwrap(catalog.workspaces.firstIndex { $0.id == original.id })
        let missing = directory.appendingPathComponent("missing/velora.sqlite").path
        catalog.workspaces[index].databasePath = missing
        try catalog.save(to: directory.appendingPathComponent("workspaces.json"))
        let reopened = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"),
            legacyDatabaseURL: directory.appendingPathComponent("ignored.sqlite"), startBackgroundServices: false)
        do { try await reopened.switchWorkspace(original.id); XCTFail("Missing database should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不存在")) }
        XCTAssertEqual(reopened.currentWorkspace?.id, second.id)
        XCTAssertFalse(reopened.busy)
        XCTAssertFalse(try XCTUnwrap(reopened.model).workspaceTransitioning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
        _ = try await XCTUnwrap(reopened.store).createPage()
    }

    func testValidationAndInactiveDeletion() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let catalog = try XCTUnwrap(services.catalog)
        var invalid = original
        invalid.name = " \n "
        XCTAssertThrowsError(try catalog.validated(invalid))
        invalid.name = String(repeating: "名", count: 61)
        XCTAssertThrowsError(try catalog.validated(invalid))
        invalid.name = "有效名称"; invalid.summary = String(repeating: "字", count: 501)
        XCTAssertThrowsError(try catalog.validated(invalid))
        try await services.createWorkspace(name: "第二空间", summary: "", symbol: "house.fill", color: "pink")
        var duplicate = try XCTUnwrap(services.currentWorkspace)
        duplicate.name = original.name
        XCTAssertThrowsError(try services.updateWorkspace(duplicate))
        let selected = services.currentWorkspace?.id
        let model = services.model
        try await services.deleteWorkspace(original.id)
        XCTAssertEqual(services.currentWorkspace?.id, selected)
        XCTAssertTrue(services.model === model)
        XCTAssertEqual(services.workspaces.count, 1)
    }

    func testCatalogSaveFailureKeepsActiveWorkspace() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let url = directory.appendingPathComponent("workspaces.json")
        try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("saved-catalog.json"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            try await services.createWorkspace(name: "无法保存", summary: "", symbol: "book.fill", color: "green")
            XCTFail("Manifest write failure should fail creation")
        } catch { }
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
        XCTAssertEqual(services.workspaces.count, 1)
        XCTAssertFalse(services.busy)
        XCTAssertFalse(try XCTUnwrap(services.model).workspaceTransitioning)
        _ = try await XCTUnwrap(services.store).createPage()
    }

    func testCorruptCatalogIsNotOverwritten() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/WorkspaceManagement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("workspaces.json")
        let corrupt = Data("invalid-json".utf8)
        try corrupt.write(to: url)
        let services = ApplicationServices(catalogURL: url, legacyDatabaseURL: directory.appendingPathComponent("velora.sqlite"), startBackgroundServices: false)
        XCTAssertNotNil(services.startupError)
        XCTAssertNil(services.model)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}
