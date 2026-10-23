import XCTest
import SQLite3
import CryptoKit
@testable import Velora

final class SQLiteStoreTests: XCTestCase {
    func testTableLayoutMigrationPreservesVersionFourData() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/TableMigration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.sqlite")
        let pageID = UUID(), blockID = UUID()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE pages(id TEXT PRIMARY KEY,parent_id TEXT,title TEXT NOT NULL,sort_order INTEGER NOT NULL,archived INTEGER NOT NULL DEFAULT 0,updated_at REAL NOT NULL,trash_batch TEXT);
        CREATE TABLE blocks(id TEXT PRIMARY KEY,page_id TEXT NOT NULL,kind TEXT NOT NULL,body TEXT NOT NULL,sort_order INTEGER NOT NULL,checked INTEGER NOT NULL DEFAULT 0,language TEXT NOT NULL DEFAULT 'Plain Text',collapsed INTEGER NOT NULL DEFAULT 0,formatting TEXT NOT NULL DEFAULT '[]');
        INSERT INTO pages(id,title,sort_order,updated_at) VALUES('\(pageID.uuidString)','Existing page',0,0);
        INSERT INTO blocks(id,page_id,kind,body,sort_order) VALUES('\(blockID.uuidString)','\(pageID.uuidString)','table','[["Header","Value"]]',0);
        PRAGMA user_version=4;
        """
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
        XCTAssertEqual(code, SQLITE_OK)
        let migrated = try SQLiteStore(databaseURL: file)
        let blocks = try await migrated.blocks(in: pageID)
        XCTAssertEqual(blocks.first?.id, blockID)
        XCTAssertEqual(blocks.first?.text, #"[["Header","Value"]]"#)
        XCTAssertEqual(blocks.first?.tableLayout, TableLayout())
        let layout = TableLayout(columnWidths: [256, 180], rowHeights: [88])
        try await migrated.updateBlock(blockID, text: blocks[0].text, tableLayout: layout)
        let reopened = try SQLiteStore(databaseURL: file)
        let saved = try await reopened.blocks(in: pageID)
        XCTAssertEqual(saved.first?.tableLayout, layout)
    }

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

    func testMoveBlockPreservesContentAndPersistsPosition() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/BlockMove-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")
        let store = try SQLiteStore(databaseURL: url)
        let page = try await store.createPage()
        let first = try await store.createBlock(pageID: page.id, kind: .equation)
        let last = try await store.createBlock(pageID: page.id, kind: .markdown)
        try await store.updateBlock(first.id, text: "x^2")
        _ = try await store.moveBlock(last.id, pageID: page.id, offset: -1)
        let reopened = try SQLiteStore(databaseURL: url)
        let blocks = try await reopened.blocks(in: page.id)
        XCTAssertEqual(blocks.map(\.id), [last.id, first.id])
        XCTAssertEqual(blocks.last?.text, "x^2")
        XCTAssertEqual(blocks.last?.kind, .equation)
        let unchanged = try await reopened.moveBlock(last.id, pageID: page.id, offset: -1)
        XCTAssertEqual(unchanged.map(\.id), blocks.map(\.id))
    }

    func testPageDragHierarchyReorderAndCycleProtection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Velora-Hierarchy-" + UUID().uuidString)
        let store = try SQLiteStore(databaseURL: folder.appendingPathComponent("store.sqlite"))
        let first = try await store.createPage()
        let second = try await store.createPage()
        let third = try await store.createPage()
        let child = try await store.createPage(parentID: first.id)
        let initial = try await store.pages().filter { $0.parentID == nil }
        XCTAssertEqual(initial.map(\.id), [first.id, second.id, third.id])
        XCTAssertLessThan(first.order, second.order)
        XCTAssertLessThan(second.order, third.order)

        try await store.movePage(third.id, toParent: nil, before: first.id)
        var pages = try await store.pages().filter { !$0.archived }
        XCTAssertEqual(pages.filter { $0.parentID == nil }.map(\.id), [third.id, first.id, second.id])

        try await store.movePage(second.id, toParent: first.id, before: child.id)
        pages = try await store.pages().filter { !$0.archived }
        XCTAssertEqual(pages.filter { $0.parentID == first.id }.map(\.id), [second.id, child.id])

        do {
            try await store.movePage(first.id, toParent: child.id)
            XCTFail("Moving a page below its descendant must fail")
        } catch StoreError.invalidMove { }
        pages = try await store.pages().filter { !$0.archived }
        XCTAssertNil(pages.first { $0.id == first.id }?.parentID)
        XCTAssertEqual(pages.first { $0.id == child.id }?.parentID, first.id)
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
        catch { XCTAssertTrue(error.localizedDescription.contains(L10n.text("至少需要保留一个工作空间"))) }
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
        catch { XCTAssertTrue(error.localizedDescription.contains(L10n.text("工作空间数据库不存在："))) }
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

@MainActor
final class BackupAndLocalizationTests: XCTestCase {
    private func fixture() throws -> (URL, ApplicationServices) {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/Backup-" + UUID().uuidString)
        let services = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"),
            legacyDatabaseURL: directory.appendingPathComponent("original/velora.sqlite"), startBackgroundServices: false)
        XCTAssertNil(services.startupError)
        return (directory, services)
    }

    func testCompressedBackupRestoresHierarchyTrashFormattingAndEmbeddedAssetsWithoutOverwrite() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let store = try XCTUnwrap(services.store)
        let parent = try await store.createPage()
        let child = try await store.createPage(parentID: parent.id)
        try await store.renamePage(parent.id, title: "中文 English")
        let block = try await store.createBlock(pageID: parent.id, kind: .code)
        let content = String(repeating: "中文内容 English \n", count: 400)
        var style = InlineTextStyle(); style.bold = true
        let runs = [TextStyleRun(location: 0, length: 4, style: style)]
        try await store.updateBlock(block.id, text: content, formatting: runs)
        try await store.setBlockOptions(block.id, language: "Swift", collapsed: true)
        let image = try await store.createBlock(pageID: child.id, kind: .image)
        try await store.updateBlock(image.id, text: "data:image/png;base64,aGVsbG8=")
        let table = try await store.createBlock(pageID: child.id, kind: .table)
        let tableLayout = TableLayout(columnWidths: [280, 120], rowHeights: [80, 96])
        try await store.updateBlock(table.id, text: BlockKind.table.initialText, tableLayout: tableLayout)
        let trash = try await store.createPage()
        try await store.archivePage(trash.id, archived: true)
        let archive = try await services.createBackup(in: directory)
        XCTAssertEqual(archive.pathExtension, "zip")
        let bytes = try Data(contentsOf: archive)
        // Raw DEFLATE in the ZIP local header, rather than a renamed uncompressed database.
        XCTAssertEqual(bytes[8], 8)
        let unpacked = try WorkspaceBackup.read(archive)
        XCTAssertLessThan(bytes.count, unpacked.database.count)
        try await store.renamePage(parent.id, title: "备份后的改动")
        try await services.restoreBackup(from: archive)
        let restoredProfile = try XCTUnwrap(services.currentWorkspace)
        XCTAssertNotEqual(restoredProfile.id, original.id)
        XCTAssertNotEqual(restoredProfile.databasePath, original.databasePath)
        XCTAssertEqual(services.workspaces.count, 2)
        let restored = try XCTUnwrap(services.store)
        let pages = try await restored.pages()
        XCTAssertEqual(pages.first { $0.id == parent.id }?.title, "中文 English")
        XCTAssertEqual(pages.first { $0.id == child.id }?.parentID, parent.id)
        XCTAssertTrue(pages.first { $0.id == trash.id }?.archived == true)
        let blocks = try await restored.blocks(in: parent.id)
        XCTAssertEqual(blocks.first?.text, content)
        XCTAssertEqual(blocks.first?.formatting, runs)
        XCTAssertEqual(blocks.first?.language, "Swift")
        XCTAssertEqual(blocks.first?.collapsed, true)
        let assets = try await restored.blocks(in: child.id)
        XCTAssertEqual(assets.first?.text, "data:image/png;base64,aGVsbG8=")
        XCTAssertEqual(assets.first(where: { $0.id == table.id })?.tableLayout, tableLayout)
        let originalPages = try await store.pages()
        XCTAssertEqual(originalPages.first { $0.id == parent.id }?.title, "备份后的改动")
        try await services.restoreBackup(from: archive)
        XCTAssertEqual(Set(services.workspaces.map(\.name)).count, 3)
        let reopened = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"),
            legacyDatabaseURL: directory.appendingPathComponent("ignored.sqlite"), startBackgroundServices: false)
        XCTAssertEqual(reopened.currentWorkspace?.id, services.currentWorkspace?.id)
    }

    func testInvalidArchiveAndChecksumKeepCurrentWorkspaceAndReleaseBusyState() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let archive = try await services.createBackup(in: directory)
        var package = try ZIPPackage.decode(Data(contentsOf: archive), maximumSize: WorkspaceBackup.maximumSize)
        package["workspace.sqlite"] = Data("invalid database".utf8)
        let bad = directory.appendingPathComponent("bad.zip")
        try ZIPPackage.encode(package.map { ($0.key, $0.value) }, compressed: true).write(to: bad)
        do { try await services.restoreBackup(from: bad); XCTFail("Corrupt backup was accepted") } catch { }
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
        XCTAssertEqual(services.workspaces.count, 1)
        XCTAssertFalse(services.busy)
        XCTAssertFalse(services.model?.workspaceTransitioning ?? true)
        var metadata = try JSONDecoder().decode(WorkspaceBackup.Manifest.self, from: package["manifest.json"]!)
        metadata.databaseSHA256 = SHA256.hash(data: package["workspace.sqlite"]!).map { String(format: "%02x", $0) }.joined()
        package["manifest.json"] = try JSONEncoder().encode(metadata)
        try ZIPPackage.encode(package.map { ($0.key, $0.value) }, compressed: true).write(to: bad)
        do { try await services.restoreBackup(from: bad); XCTFail("Invalid database was accepted") } catch { }
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
        XCTAssertFalse(services.busy)
        try Data("not a zip".utf8).write(to: bad)
        do { try await services.restoreBackup(from: bad); XCTFail("Invalid ZIP was accepted") } catch { }
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
        XCTAssertFalse(services.busy)
        XCTAssertThrowsError(try WorkspaceBackup.validateDatabase(at: bad))
    }

    func testBackupFlushesPendingEditsAndDoesNotOverwriteExistingArchive() async throws {
        let (directory, services) = try fixture()
        let store = try XCTUnwrap(services.store), model = try XCTUnwrap(services.model)
        let page = try await store.createPage()
        let block = try await store.createBlock(pageID: page.id, kind: .paragraph)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<100 where !model.blocks.contains(where: { $0.id == block.id }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.changeText("尚未防抖保存的中文 English", in: block)
        XCTAssertTrue(model.saving)
        let archive = try await services.createBackup(in: directory)
        XCTAssertFalse(model.saving)
        try await services.restoreBackup(from: archive)
        let restored = try await XCTUnwrap(services.store).blocks(in: page.id)
        XCTAssertEqual(restored.first?.text, "尚未防抖保存的中文 English")
        let originalBytes = try Data(contentsOf: archive)
        let snapshot = directory.appendingPathComponent("snapshot.sqlite")
        try await store.snapshot(to: snapshot)
        XCTAssertThrowsError(try WorkspaceBackup.write(snapshot: snapshot, profile: services.currentWorkspace!, to: archive))
        XCTAssertEqual(try Data(contentsOf: archive), originalBytes)
    }

    func testLanguageSwitchKeepsStableBlockIdentifiersAndSafeInterpolation() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "appLanguage")
        defer { if let previous { defaults.set(previous, forKey: "appLanguage") } else { defaults.removeObject(forKey: "appLanguage") } }
        defaults.set("en", forKey: "appLanguage")
        XCTAssertEqual(L10n.text("立即备份"), "Back up now")
        XCTAssertEqual(BlockKind.paragraph.label, "Text")
        XCTAssertEqual(BlockKind.equation.rawValue, "equation")
        XCTAssertEqual(BlockKind.categories, ["Basic blocks", "Media and links", "Advanced blocks"])
        let name = "中文 %@ 100%"
        XCTAssertEqual(L10n.tr("已创建「\(name)」"), "Created “中文 %@ 100%”")
        XCTAssertEqual(L10n.tr("已选中 \(3) 个块"), "3 blocks selected")
        for kind in BlockKind.allCases {
            XCTAssertFalse(kind.label.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, kind.rawValue)
        }
        let model = try fixture().1.model!
        XCTAssertEqual(AssistantService.localPlan("new page 中文", model: model)?.actions.first?.arguments["title"], "中文")
        XCTAssertEqual(AssistantService.localPlan("back up now", model: model)?.actions.first?.name, "backup")
        defaults.set("zh-Hans", forKey: "appLanguage")
        XCTAssertEqual(L10n.text("立即备份"), "立即备份")
        XCTAssertEqual(BlockKind.paragraph.label, "正文")
    }

    func testTranslationResourcesHaveMatchingKeysAndPlaceholders() throws {
        func table(_ code: String) throws -> [String: String] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let english = try table("en"), chinese = try table("zh-Hans")
        XCTAssertGreaterThan(english.count, 500)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for (key, value) in english {
            XCTAssertEqual(key.components(separatedBy: "%@").count, value.components(separatedBy: "%@").count, key)
            XCTAssertFalse(value.isEmpty, key)
        }
    }
}
