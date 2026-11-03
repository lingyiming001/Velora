import XCTest
import SQLite3
import CryptoKit
@testable import Velora

final class SQLiteStoreTests: XCTestCase {
    func testOrderedStartSurvivesReopenBlockAndPageCopiesAndJSON() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/ListStart-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let store = try SQLiteStore(databaseURL: url)
        let page = try await store.createPage()
        let block = try await store.createBlock(pageID: page.id, kind: .numbered)
        try await store.updateBlock(block.id, text: "Prompt")
        try await store.setListStart(2, for: block.id)
        let reopened = try SQLiteStore(databaseURL: url)
        let saved = try await reopened.blocks(in: page.id)
        XCTAssertEqual(saved.first?.listStart, 2)
        let copied = try await store.duplicateBlocks([block.id], pageID: page.id)
        XCTAssertEqual(copied.map(\.listStart), [2, 2])
        let copyID = try await store.duplicatePage(page.id)
        let pageCopy = try await store.blocks(in: copyID)
        XCTAssertEqual(pageCopy.map(\.listStart), [2, 2])
        let snapshot = try await store.transferSnapshot(name: "list", pageID: page.id)
        let decoded = try JSONDecoder().decode(TransferDocument.self, from: JSONEncoder().encode(snapshot))
        let imported = try await store.importTransfer(decoded)
        let importedBlocks = try await store.blocks(in: XCTUnwrap(imported.first))
        XCTAssertEqual(importedBlocks.map(\.listStart), [2, 2])
        let legacy = try JSONDecoder().decode(TransferBlock.self, from: Data(#"{"kind":"numbered","text":"old"}"#.utf8))
        XCTAssertNil(legacy.listStart)
    }

    func testImageWidthPersistsThroughReopenCopiesAndJSONImport() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/ImageWidth-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let store = try SQLiteStore(databaseURL: url)
        let page = try await store.createPage()
        let image = try await store.createBlock(pageID: page.id, kind: .image)
        try await store.setImageWidth(520, for: image.id)
        let reopened = try SQLiteStore(databaseURL: url)
        let saved = try await reopened.blocks(in: page.id)
        XCTAssertEqual(saved.first?.imageWidth, 520)
        let copied = try await store.duplicateBlocks([image.id], pageID: page.id)
        XCTAssertEqual(copied.map(\.imageWidth), [520, 520])
        let copiedPage = try await store.duplicatePage(page.id)
        let pageImages = try await store.blocks(in: copiedPage)
        XCTAssertEqual(pageImages.map(\.imageWidth), [520, 520])
        let snapshot = try await store.transferSnapshot(name: "width", pageID: page.id)
        let decoded = try JSONDecoder().decode(TransferDocument.self, from: JSONEncoder().encode(snapshot))
        let imported = try await store.importTransfer(decoded)
        let importedImages = try await store.blocks(in: XCTUnwrap(imported.first))
        XCTAssertEqual(importedImages.map(\.imageWidth), [520, 520])
        try await store.setImageWidth(nil, for: image.id)
        let reset = try await store.blocks(in: page.id)
        XCTAssertNil(reset.first?.imageWidth)
        let old = try JSONDecoder().decode(TransferBlock.self, from: Data(#"{"kind":"image","text":""}"#.utf8))
        XCTAssertNil(old.imageWidth)
        XCTAssertNil(ImageSizing.width(.nan))
        XCTAssertEqual(ImageSizing.width(50000), 2400)
        XCTAssertEqual(ImageSizing.width(-1), 80)
    }

    func testPageCopyNamesUseIncreasingNumbersAndFlattenOldSuffixes() {
        XCTAssertEqual(PageCopyNaming.title(for: "未命名", siblings: ["未命名"]), "未命名 1")
        XCTAssertEqual(PageCopyNaming.title(for: "未命名 1", siblings: ["未命名", "未命名 1", "未命名 3"]), "未命名 4")
        XCTAssertEqual(PageCopyNaming.title(for: "未命名 副本 副本 副本", siblings: []), "未命名 1")
        XCTAssertEqual(PageCopyNaming.title(for: "Note copy copy 2", siblings: ["Note 1"]), "Note 2")
        XCTAssertEqual(PageCopyNaming.title(for: "面试-2026", siblings: []), "面试-2026 1")
        XCTAssertEqual(PageCopyNaming.title(for: "未命名 5", siblings: []), "未命名 6")
        XCTAssertEqual(PageCopyNaming.title(for: "", siblings: []), L10n.tr("未命名") + " 1")
    }

    func testDuplicatePageCopiesActiveSubtreeMetadataAndSiblingPosition() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/DuplicatePage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let store = try SQLiteStore(databaseURL: url)
        let parent = try await store.createPage()
        let source = try await store.createPage(parentID: parent.id)
        try await store.renamePage(source.id, title: "原页面")
        let after = try await store.createPage(parentID: parent.id)
        let child = try await store.createPage(parentID: source.id)
        let grandchild = try await store.createPage(parentID: child.id)
        let trash = try await store.createPage(parentID: source.id)
        try await store.archivePage(trash.id, archived: true)
        let seed = try await store.createBlock(pageID: source.id, kind: .paragraph)
        var style = InlineTextStyle(); style.bold = true
        _ = try await store.replaceBlock(seed.id, pageID: source.id, with: [
            TransferBlock(.code, "let x = 1", language: "Swift", collapsed: true),
            TransferBlock(.table, "[[\"内容\"]]", tableLayout: TableLayout(columnWidths: [240], rowHeights: [88])),
            TransferBlock(.todo, "完成", checked: true, formatting: [TextStyleRun(location: 0, length: 2, style: style)]),
            TransferBlock(.file, "/tmp/external.pdf")
        ])
        let body = try await store.createBlock(pageID: grandchild.id, kind: .paragraph)
        try await store.updateBlock(body.id, text: "孙页面正文")
        let originalBlocks = try await store.blocks(in: source.id)
        let copyID = try await store.duplicatePage(source.id)
        let pages = try await store.pages()
        let copy = try XCTUnwrap(pages.first { $0.id == copyID })
        XCTAssertEqual(copy.parentID, parent.id)
        XCTAssertEqual(copy.title, "原页面 1")
        XCTAssertEqual(pages.filter { !$0.archived && $0.parentID == parent.id }.map(\.id), [source.id, copyID, after.id])
        let copiedChild = try XCTUnwrap(pages.first { $0.parentID == copyID })
        let copiedGrandchild = try XCTUnwrap(pages.first { $0.parentID == copiedChild.id })
        XCTAssertEqual(pages.filter { $0.parentID == copyID }.count, 1)
        let copiedBlocks = try await store.blocks(in: copyID)
        XCTAssertEqual(copiedBlocks.map(TransferBlock.init), originalBlocks.map(TransferBlock.init))
        XCTAssertTrue(Set(copiedBlocks.map(\.id)).isDisjoint(with: originalBlocks.map(\.id)))
        let grandBody = try await store.blocks(in: copiedGrandchild.id)
        XCTAssertEqual(grandBody.first?.text, "孙页面正文")
        try await store.updateBlock(copiedBlocks[0].id, text: "independent")
        let unchanged = try await store.blocks(in: source.id)
        XCTAssertEqual(unchanged, originalBlocks)
        let secondID = try await store.duplicatePage(source.id)
        let reopened = try SQLiteStore(databaseURL: url)
        let saved = try await reopened.pages()
        XCTAssertEqual(saved.first { $0.id == secondID }?.title, "原页面 2")
        XCTAssertNotNil(saved.first { $0.id == copyID })
        do { _ = try await store.duplicatePage(trash.id); XCTFail("Archived source must fail") } catch { }
    }

    func testDuplicatePageRollsBackWholeTreeOnBlockWriteFailure() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/DuplicateRollback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let store = try SQLiteStore(databaseURL: url)
        let (source, _) = try await store.createPageWithInitialBlock()
        _ = try await store.createPage(parentID: source.id)
        let before = try await store.pages()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_copy BEFORE INSERT ON blocks BEGIN SELECT RAISE(ABORT,'injected failure'); END", nil, nil, nil), SQLITE_OK)
        do { _ = try await store.duplicatePage(source.id); XCTFail("Injected write must fail") } catch { }
        let after = try await store.pages()
        XCTAssertEqual(after, before)
    }

    func testPageWithInitialInputUsesSiblingOrderAndRejectsMissingParent() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/CreateInput-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("store.sqlite"))
        let (first, input) = try await store.createPageWithInitialBlock()
        let (second, _) = try await store.createPageWithInitialBlock()
        let (child, _) = try await store.createPageWithInitialBlock(parentID: first.id)
        XCTAssertEqual(second.order, first.order + 1024)
        XCTAssertEqual(child.order, 1024)
        let blocks = try await store.blocks(in: first.id)
        XCTAssertEqual(blocks, [input])
        do { _ = try await store.createPageWithInitialBlock(parentID: UUID()); XCTFail("Missing parent must fail") } catch { }
        let pages = try await store.pages()
        XCTAssertEqual(pages.count, 3)
    }

    func testDuplicateBlocksRetainsMetadataAndOrderAfterReopen() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/Duplicate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let store = try SQLiteStore(databaseURL: url)
        let page = try await store.createPage()
        let seed = try await store.createBlock(pageID: page.id, kind: .paragraph)
        var style = InlineTextStyle(); style.bold = true
        let runs = [TextStyleRun(location: 0, length: 2, style: style)]
        _ = try await store.replaceBlock(seed.id, pageID: page.id, with: [
            TransferBlock(.code, "代码", language: "Swift", collapsed: true, formatting: runs),
            TransferBlock(.table, "[[\"数据\"]]", tableLayout: TableLayout(columnWidths: [240], rowHeights: [80])),
            TransferBlock(.todo, "完成", checked: true)
        ])
        let source = try await store.blocks(in: page.id)
        let result = try await store.duplicateBlocks(Set(source.map(\.id)), pageID: page.id)
        XCTAssertEqual(result.count, 6)
        for index in source.indices {
            let copy = result[index + 3]
            XCTAssertNotEqual(copy.id, source[index].id)
            XCTAssertEqual(TransferBlock(copy), TransferBlock(source[index]))
        }
        XCTAssertEqual(result.map(\.order), (1...6).map { Int64($0 * 1024) })
        let reopened = try SQLiteStore(databaseURL: url)
        let saved = try await reopened.blocks(in: page.id)
        XCTAssertEqual(saved, result)
    }

    func testMergeTextBlocksRequiresAdjacentBlocksAndPreservesSavedFormatting() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/MergeText-" + UUID().uuidString)
        let url = directory.appendingPathComponent("test.sqlite")
        let store = try SQLiteStore(databaseURL: url)
        let page = try await store.createPage()
        let first = try await store.createBlock(pageID: page.id, kind: .paragraph)
        let middle = try await store.createBlock(pageID: page.id, kind: .paragraph)
        let last = try await store.createBlock(pageID: page.id, kind: .paragraph)
        try await store.updateBlock(first.id, text: "首段")
        var merged = first; merged.text = "首段下一段"
        var style = InlineTextStyle(); style.bold = true
        merged.formatting = [TextStyleRun(location: 2, length: 3, style: style)]
        do { try await store.mergeTextBlocks(merged, removing: last); XCTFail("Non-adjacent merge must fail") }
        catch { }
        let unchanged = try await store.blocks(in: page.id)
        XCTAssertEqual(unchanged.map(\.id), [first.id, middle.id, last.id])
        XCTAssertEqual(unchanged.first?.text, "首段")
        try await store.mergeTextBlocks(merged, removing: middle)
        let reopened = try SQLiteStore(databaseURL: url)
        let saved = try await reopened.blocks(in: page.id)
        XCTAssertEqual(saved.map(\.id), [first.id, last.id])
        XCTAssertEqual(saved.first?.text, merged.text)
        XCTAssertEqual(saved.first?.formatting, merged.formatting)
    }

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

    @MainActor
    func testSharedStorageMigratesAllWorkspacesAndFutureCreationUsesRoot() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/SharedStorage-" + UUID().uuidString)
        let catalogURL = directory.appendingPathComponent("workspaces.json")
        let services = ApplicationServices(catalogURL: catalogURL, legacyDatabaseURL: directory.appendingPathComponent("legacy.sqlite"), startBackgroundServices: false)
        let first = try XCTUnwrap(services.currentWorkspace)
        let firstStore = try XCTUnwrap(services.store)
        let firstPage = try await firstStore.createPage()
        try await firstStore.renamePage(firstPage.id, title: "原空间")
        try await services.createWorkspace(name: "第二空间", summary: "", symbol: "book.fill", color: "blue")
        let active = try XCTUnwrap(services.currentWorkspace)
        let activeStore = try XCTUnwrap(services.store)
        let page = try await activeStore.createPage()
        let block = try await activeStore.createBlock(pageID: page.id, kind: .paragraph)
        let model = try XCTUnwrap(services.model)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<100 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        model.changeText("迁移前待保存内容", in: block)
        let root = directory.appendingPathComponent("Unified")
        try await services.relocateStorage(to: root)
        XCTAssertEqual(services.storagePath, root.path)
        XCTAssertEqual(services.currentWorkspace?.id, active.id)
        XCTAssertFalse(services.busy)
        for profile in services.workspaces {
            XCTAssertTrue(profile.databasePath.hasPrefix(root.path + "/Workspaces/"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.databasePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.databasePath))
        let activeContent = try await XCTUnwrap(services.store).blocks(in: page.id)
        XCTAssertEqual(activeContent.first?.text, "迁移前待保存内容")
        try await services.switchWorkspace(first.id)
        let originalPages = try await XCTUnwrap(services.store).pages()
        XCTAssertEqual(originalPages.first?.title, "原空间")
        let restarted = ApplicationServices(catalogURL: catalogURL, legacyDatabaseURL: directory.appendingPathComponent("unused.sqlite"), startBackgroundServices: false)
        XCTAssertEqual(restarted.storagePath, root.path)
        try await restarted.createWorkspace(name: "第三空间", summary: "", symbol: "star.fill", color: "green")
        XCTAssertTrue(try XCTUnwrap(restarted.currentWorkspace).databasePath.hasPrefix(root.path + "/Workspaces/"))
        let archive = try await restarted.createBackup(in: directory.appendingPathComponent("Backups"))
        try await restarted.restoreBackup(from: archive)
        XCTAssertTrue(try XCTUnwrap(restarted.currentWorkspace).databasePath.hasPrefix(root.path + "/Workspaces/"))
        let before = restarted.catalog
        let conflict = directory.appendingPathComponent("Conflict")
        let target = conflict.appendingPathComponent("Workspaces").appendingPathComponent(first.id.uuidString).appendingPathComponent("velora.sqlite")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: target)
        try await restarted.relocateStorage(to: conflict.appendingPathComponent("Workspaces"))
        XCTAssertEqual(restarted.catalog?.storageRoot, conflict.path)
        XCTAssertEqual(restarted.workspaceDirectoryPath, conflict.appendingPathComponent("Workspaces").path)
        XCTAssertEqual(restarted.workspaces.map(\.id), before?.workspaces.map(\.id))
        let migrated = try XCTUnwrap(restarted.workspaces.first { $0.id == first.id })
        XCTAssertNotEqual(migrated.databasePath, target.path)
        let migratedStore = try SQLiteStore(databaseURL: URL(fileURLWithPath: migrated.databasePath))
        let migratedPages = try await migratedStore.pages()
        XCTAssertEqual(migratedPages.first?.title, "原空间")
        let stablePaths = restarted.workspaces.map(\.databasePath)
        try await restarted.relocateStorage(to: conflict.appendingPathComponent("Workspaces"))
        XCTAssertEqual(restarted.workspaces.map(\.databasePath), stablePaths)
        let relaunched = ApplicationServices(catalogURL: catalogURL, startBackgroundServices: false)
        XCTAssertNil(relaunched.startupError)
        XCTAssertEqual(relaunched.workspaces.map(\.databasePath), stablePaths)
        XCTAssertEqual(try Data(contentsOf: target), Data("existing".utf8))
        XCTAssertFalse(restarted.busy)
    }

    @MainActor
    func testSharedStorageCatalogFailureRollsBackStagedCopies() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/SharedStorageRollback-" + UUID().uuidString)
        let catalogURL = directory.appendingPathComponent("workspaces.json")
        let services = ApplicationServices(catalogURL: catalogURL, legacyDatabaseURL: directory.appendingPathComponent("legacy.sqlite"), startBackgroundServices: false)
        let original = try XCTUnwrap(services.currentWorkspace)
        let store = try XCTUnwrap(services.store)
        let page = try await store.createPage()
        let catalogBytes = try Data(contentsOf: catalogURL)
        try FileManager.default.removeItem(at: catalogURL)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent("FailedMigration")
        do { try await services.relocateStorage(to: root); XCTFail("Catalog commit should fail") } catch { }
        XCTAssertEqual(services.currentWorkspace, original)
        XCTAssertFalse(services.busy)
        XCTAssertNil(services.catalog?.storageRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.databasePath))
        let staged = root.appendingPathComponent("Workspaces").appendingPathComponent(original.id.uuidString).appendingPathComponent("velora.sqlite")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let pages = try await XCTUnwrap(services.store).pages()
        XCTAssertEqual(pages.first?.id, page.id)
        try FileManager.default.removeItem(at: catalogURL)
        try catalogBytes.write(to: catalogURL)
    }

    func testWritingMissingBlockReportsUnsavedContent() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/MissingBlockWrite-" + UUID().uuidString)
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        do { try await store.updateBlock(UUID(), text: "must not silently disappear"); XCTFail("Missing blocks must report a failed save") } catch { }
    }

    func testHeadingSplitWritesBothHalvesAtomicallyAndRollsBackConflict() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/BlockSplit-" + UUID().uuidString)
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let page = try await store.createPage()
        var heading = try await store.createBlock(pageID: page.id, kind: .heading)
        try await store.updateBlock(heading.id, text: "标题正文")
        let following = try await store.createBlock(pageID: page.id, kind: .paragraph)
        heading.text = "标题"
        var body = Block(id: following.id, pageID: page.id, kind: .paragraph, text: "正文", order: 0, checked: false)
        do { try await store.splitTextBlock(heading, inserting: body); XCTFail("Duplicate ID must roll back") } catch { }
        let unchanged = try await store.blocks(in: page.id)
        XCTAssertEqual(unchanged.first?.text, "标题正文")
        XCTAssertEqual(unchanged.count, 2)
        body = Block(id: UUID(), pageID: page.id, kind: .paragraph, text: "正文", order: 0, checked: false)
        try await store.splitTextBlock(heading, inserting: body)
        let reopened = try SQLiteStore(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        let saved = try await reopened.blocks(in: page.id)
        XCTAssertEqual(saved.map(\.id), [heading.id, body.id, following.id])
        XCTAssertEqual(saved.prefix(2).map(\.text), ["标题", "正文"])
        XCTAssertEqual(saved.prefix(2).map(\.kind), [.heading, .paragraph])
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
    private func namedPage(_ title: String, in store: SQLiteStore, parentID: UUID? = nil) async throws -> Page {
        var page = try await store.createPage(parentID: parentID)
        try await store.renamePage(page.id, title: title)
        page.title = title
        return page
    }
    func testMoveDocumentAcrossWorkspacesPreservesTreeUnsavedContentAndRecovery() async throws {
        let (directory, services) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceProfile = try XCTUnwrap(services.currentWorkspace)
        let source = try XCTUnwrap(services.store)
        let parent = try await namedPage("原父页面", in: source)
        let root = try await namedPage("文档", in: source, parentID: parent.id)
        let child = try await namedPage("子页面", in: source, parentID: root.id)
        let deleted = try await namedPage("已删除子页面", in: source, parentID: root.id)
        try await source.archivePage(deleted.id, archived: true)
        let prose = try await source.createBlock(pageID: root.id, kind: .heading)
        let code = try await source.createBlock(pageID: child.id, kind: .code)
        try await source.updateBlock(code.id, text: "    print('原样')\n")
        try await source.setBlockOptions(code.id, language: "Python", collapsed: true)
        let table = try await source.createBlock(pageID: child.id, kind: .table)
        try await source.updateBlock(table.id, text: #"[["A","B"],["`真实`","a|b"]]"#,
            tableLayout: TableLayout(columnWidths: [120, 280], rowHeights: [50, 90], cellsArePlain: true))
        let image = try await source.createBlock(pageID: child.id, kind: .image)
        try await source.updateBlock(image.id, text: "https://example.com/image.png")
        try await services.createWorkspace(name: "目标", summary: "", symbol: "book.fill", color: "blue")
        let targetProfile = try XCTUnwrap(services.currentWorkspace)
        let target = try XCTUnwrap(services.store)
        let existing = try await namedPage("文档", in: target)
        try await services.switchWorkspace(sourceProfile.id)
        let model = try XCTUnwrap(services.model)
        await model.refreshPages(); model.select(root.id)
        for _ in 0..<100 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        var bold = InlineTextStyle(); bold.bold = true
        model.changeRichText("尚未自动保存😀", formatting: [TextStyleRun(location: 0, length: 2, style: bold)], in: prose)
        let newID = try await services.movePage(root.id, toWorkspace: targetProfile.id)
        XCTAssertEqual(services.currentWorkspace?.id, sourceProfile.id)
        XCTAssertFalse(services.busy); XCTAssertFalse(model.workspaceTransitioning)
        XCTAssertEqual(model.selectedPageID, parent.id)
        let moved = try await target.transferSnapshot(name: "", pageID: newID)
        XCTAssertEqual(moved.pages.map(\.title), ["文档", "子页面"])
        XCTAssertNil(moved.pages[0].parentID)
        XCTAssertEqual(moved.pages[1].parentID, newID)
        XCTAssertEqual(moved.pages[0].blocks[0].text, "尚未自动保存😀")
        XCTAssertEqual(moved.pages[0].blocks[0].formatting.first?.style.bold, true)
        let originalChild = try await source.blocks(in: child.id).map(TransferBlock.init)
        XCTAssertEqual(moved.pages[1].blocks, originalChild)
        let destinationPages = try await target.pages()
        XCTAssertTrue(destinationPages.contains { $0.id == existing.id && !$0.archived })
        let archived = try await source.pages()
        XCTAssertTrue(archived.first { $0.id == root.id }?.archived == true)
        XCTAssertTrue(archived.first { $0.id == child.id }?.archived == true)
        XCTAssertFalse(archived.first { $0.id == parent.id }?.archived ?? true)
        try await source.restorePage(root.id)
        let restored = try await source.pages()
        XCTAssertFalse(restored.first { $0.id == child.id }?.archived ?? true)
        XCTAssertTrue(restored.first { $0.id == deleted.id }?.archived == true)
        let reopened = try SQLiteStore(databaseURL: URL(fileURLWithPath: targetProfile.databasePath))
        let persisted = try await reopened.transferSnapshot(name: "", pageID: newID)
        XCTAssertEqual(persisted, moved)
    }

    func testMoveCopyFailureRollsBackDestinationAndArchiveFailureKeepsBothCopies() async throws {
        let (directory, services) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceProfile = try XCTUnwrap(services.currentWorkspace)
        let source = try XCTUnwrap(services.store)
        let page = try await namedPage("安全移动", in: source)
        let block = try await source.createBlock(pageID: page.id, kind: .paragraph)
        try await source.updateBlock(block.id, text: "不可丢失")
        try await services.createWorkspace(name: "目标", summary: "", symbol: "book.fill", color: "blue")
        let targetProfile = try XCTUnwrap(services.currentWorkspace)
        let target = try XCTUnwrap(services.store)
        try await services.switchWorkspace(sourceProfile.id)
        await services.model?.refreshPages()
        func execute(_ sql: String, path: String) throws {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let result = sqlite3_exec(db, sql, nil, nil, nil)
            XCTAssertEqual(result, SQLITE_OK)
        }
        try execute("CREATE TRIGGER reject_move BEFORE INSERT ON blocks BEGIN SELECT RAISE(ABORT,'test copy failure'); END;", path: targetProfile.databasePath)
        do { try await services.movePage(page.id, toWorkspace: targetProfile.id); XCTFail("Copy must fail") } catch {}
        var targetPages = try await target.pages()
        XCTAssertTrue(targetPages.isEmpty, "Import transaction must roll back pages as well as blocks")
        var sourcePages = try await source.pages()
        XCTAssertFalse(sourcePages.first { $0.id == page.id }?.archived ?? true)
        XCTAssertFalse(services.busy); XCTAssertFalse(try XCTUnwrap(services.model).workspaceTransitioning)
        try execute("DROP TRIGGER reject_move;", path: targetProfile.databasePath)
        try execute("CREATE TRIGGER reject_archive BEFORE UPDATE OF archived ON pages WHEN NEW.archived=1 BEGIN SELECT RAISE(ABORT,'test archive failure'); END;", path: sourceProfile.databasePath)
        do { try await services.movePage(page.id, toWorkspace: targetProfile.id); XCTFail("Archive must fail") } catch {}
        targetPages = try await target.pages()
        XCTAssertEqual(targetPages.filter { !$0.archived }.count, 1)
        sourcePages = try await source.pages()
        XCTAssertFalse(sourcePages.first { $0.id == page.id }?.archived ?? true)
        let copy = try await target.blocks(in: try XCTUnwrap(targetPages.first).id)
        XCTAssertEqual(copy.first?.text, "不可丢失")
        XCTAssertFalse(services.busy)
    }

    func testSourceArchiveRejectsStaleTransferSnapshot() async throws {
        let (directory, services) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(services.store)
        let page = try await namedPage("文档", in: source)
        let block = try await source.createBlock(pageID: page.id, kind: .paragraph)
        let snapshot = try await source.transferSnapshot(name: page.title, pageID: page.id)
        try await source.updateBlock(block.id, text: "复制后产生的新修改")
        do { try await source.archiveTransferredPage(page.id, matching: snapshot); XCTFail("Do not hide new edits") } catch {}
        let pages = try await source.pages()
        XCTAssertFalse(pages.first?.archived ?? true)
    }

    private func fixture() throws -> (URL, ApplicationServices) {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agents/test/WorkspaceManagement-" + UUID().uuidString)
        let services = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"),
            legacyDatabaseURL: directory.appendingPathComponent("legacy/velora.sqlite"), startBackgroundServices: false)
        XCTAssertNil(services.startupError)
        return (directory, services)
    }

    func testMissingStartupDatabaseCanCreateNewDocumentsWithoutReplacingOldRecords() async throws {
        let (directory, initial) = try fixture()
        var catalog = try XCTUnwrap(initial.catalog)
        let original = catalog.active
        let missing = directory.appendingPathComponent("deleted/velora.sqlite")
        catalog.workspaces[0].databasePath = missing.path
        let retained = catalog.workspaces[0]
        let root = directory.appendingPathComponent("Unified")
        catalog.storageRoot = root.path
        let catalogURL = directory.appendingPathComponent("workspaces.json")
        try catalog.save(to: catalogURL)
        let failed = ApplicationServices(catalogURL: catalogURL, startBackgroundServices: false)
        XCTAssertNil(failed.model)
        XCTAssertNotNil(failed.startupError)
        XCTAssertTrue(failed.canCreateStartupWorkspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try await failed.createStartupWorkspace()
        XCTAssertNil(failed.startupError)
        XCTAssertFalse(failed.busy)
        XCTAssertNotEqual(failed.currentWorkspace?.id, original.id)
        XCTAssertTrue(try XCTUnwrap(failed.currentWorkspace).databasePath.hasPrefix(root.path + "/Workspaces/"))
        XCTAssertEqual(failed.catalog?.removedWorkspaces.first { $0.id == original.id }, retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let model = try XCTUnwrap(failed.model)
        XCTAssertNotNil(model.selectedPageID)
        let store = try XCTUnwrap(failed.store)
        let pages = try await store.pages()
        XCTAssertEqual(pages.count, 1)
        let blocks = try await store.blocks(in: XCTUnwrap(pages.first).id)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(blocks.first?.text, "")
        let newPage = try await store.createPage()
        _ = try await store.createBlock(pageID: newPage.id, kind: .paragraph)
        let restarted = ApplicationServices(catalogURL: catalogURL, startBackgroundServices: false)
        XCTAssertNil(restarted.startupError)
        let reloaded = try await XCTUnwrap(restarted.store).pages()
        XCTAssertEqual(reloaded.count, 2)
    }

    func testStartupRetryCanOpenAnotherWorkspaceOrRestoredDatabase() async throws {
        let (directory, initial) = try fixture()
        let original = try XCTUnwrap(initial.currentWorkspace)
        try await initial.createWorkspace(name: "可用空间", summary: "", symbol: "book.fill", color: "blue")
        let available = try XCTUnwrap(initial.currentWorkspace)
        let availableStore = try XCTUnwrap(initial.store)
        let page = try await availableStore.createPage()
        var catalog = try XCTUnwrap(initial.catalog)
        let missing = directory.appendingPathComponent("deleted/velora.sqlite")
        let index = try XCTUnwrap(catalog.workspaces.firstIndex { $0.id == original.id })
        catalog.workspaces[index].databasePath = missing.path
        catalog.activeID = original.id
        let catalogURL = directory.appendingPathComponent("workspaces.json")
        try catalog.save(to: catalogURL)
        let failed = ApplicationServices(catalogURL: catalogURL, startBackgroundServices: false)
        XCTAssertEqual(failed.availableStartupWorkspaces.map(\.id), [available.id])
        do { try await failed.retryStartup(); XCTFail("Retry must not silently recreate the missing file") } catch { }
        XCTAssertNil(failed.model)
        XCTAssertFalse(failed.busy)
        try await failed.retryStartup(opening: available.id)
        XCTAssertNil(failed.startupError)
        XCTAssertEqual(failed.currentWorkspace?.id, available.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        catalog.activeID = original.id
        try catalog.save(to: catalogURL)
        let restored = ApplicationServices(catalogURL: catalogURL, startBackgroundServices: false)
        try await availableStore.snapshot(to: missing)
        try await restored.retryStartup()
        XCTAssertNil(restored.startupError)
        XCTAssertEqual(restored.currentWorkspace?.id, original.id)
        let pages = try await XCTUnwrap(restored.store).pages()
        XCTAssertEqual(pages.first?.id, page.id)
    }

    func testStartupRecoveryCatalogFailureLeavesOriginalMetadataAndCleansFreshDatabase() async throws {
        let (directory, initial) = try fixture()
        var catalog = try XCTUnwrap(initial.catalog)
        catalog.workspaces[0].databasePath = directory.appendingPathComponent("deleted.sqlite").path
        let catalogURL = directory.appendingPathComponent("workspaces.json")
        try catalog.save(to: catalogURL)
        let failed = ApplicationServices(catalogURL: catalogURL, startBackgroundServices: false)
        try FileManager.default.removeItem(at: catalogURL)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        do { try await failed.createStartupWorkspace(); XCTFail("Catalog save must fail") } catch { }
        XCTAssertNil(failed.model)
        XCTAssertNotNil(failed.startupError)
        XCTAssertEqual(failed.catalog?.workspaces, catalog.workspaces)
        XCTAssertFalse(failed.busy)
        let root = directory.appendingPathComponent("Workspaces")
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertEqual(Set(remaining), [catalog.workspaces[0].id.uuidString])
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

    func testDeleteActiveRemovesFolderAndRejectsLastWorkspace() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        try await services.createWorkspace(name: "临时空间", summary: "", symbol: "star.fill", color: "orange")
        let created = try XCTUnwrap(services.currentWorkspace)
        let createdStore = try XCTUnwrap(services.store)
        _ = try await createdStore.createPage()
        try await services.deleteWorkspace(created.id)
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
        XCTAssertEqual(services.workspaces.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: created.databasePath).deletingLastPathComponent().path))
        XCTAssertTrue(services.trashedWorkspaces.contains { $0.id == created.id })
        try await services.refreshWorkspaces()
        XCTAssertEqual(services.workspaces.map(\.id), [original.id])
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: original.databasePath).deletingLastPathComponent().path))
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

    func testAllWorkspaceBackupRestoresInactiveAndRemovedSpacesAndUsesBackupSubdirectory() async throws {
        let (directory, services) = try fixture()
        let first = try XCTUnwrap(services.currentWorkspace)
        let firstPage = try await XCTUnwrap(services.store).createPage()
        try await XCTUnwrap(services.store).renamePage(firstPage.id, title: "first space")
        try await services.createWorkspace(name: "Second", summary: "", symbol: "book.fill", color: "blue")
        let secondPage = try await XCTUnwrap(services.store).createPage()
        try await XCTUnwrap(services.store).renamePage(secondPage.id, title: "second space")
        try await services.createWorkspace(name: "Removed", summary: "", symbol: "star.fill", color: "green")
        let removed = try XCTUnwrap(services.currentWorkspace)
        _ = try await XCTUnwrap(services.store).createPage()
        try await services.importExistingWorkspace(from: URL(fileURLWithPath: removed.databasePath).deletingLastPathComponent(), policy: .replace)
        try await services.deleteWorkspace(removed.id)
        let archive = try await services.createBackup(in: directory)
        XCTAssertEqual(archive.deletingLastPathComponent().lastPathComponent, "backup")
        let contents = try WorkspaceBackup.readAll(archive)
        XCTAssertEqual(contents.workspaces.count, 4)
        XCTAssertEqual(contents.workspaces.filter(\.removed).count, 2)
        XCTAssertEqual(contents.activeID, first.id)
        try await services.restoreBackup(from: archive)
        XCTAssertEqual(services.workspaces.count, 4)
        XCTAssertEqual(services.catalog?.removedWorkspaces.count, 4)
        let pages = try await XCTUnwrap(services.store).pages()
        XCTAssertEqual(pages.first?.title, "first space")
        for profile in services.workspaces {
            XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: profile.databasePath).deletingLastPathComponent().appendingPathComponent("workspace.json").path))
        }
    }

    func testLegacyCatalogMissingOptionalFieldsAndMovedFolderImportPreserveWAL() async throws {
        let (directory, services) = try fixture()
        let profile = try XCTUnwrap(services.currentWorkspace)
        let catalogURL = directory.appendingPathComponent("legacy.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(services.catalog)) as? [String: Any])
        json.removeValue(forKey: "removedWorkspaces"); json.removeValue(forKey: "storageRoot")
        try JSONSerialization.data(withJSONObject: json).write(to: catalogURL)
        let legacy = try WorkspaceCatalog.load(from: catalogURL, legacyDatabaseURL: URL(fileURLWithPath: profile.databasePath))
        XCTAssertTrue(legacy.removedWorkspaces.isEmpty)
        let source = directory.appendingPathComponent("Old/old-space/velora.sqlite")
        let old = try SQLiteStore(databaseURL: source)
        let page = try await old.createPage()
        try await old.renamePage(page.id, title: "from WAL")
        try await services.importExistingWorkspace(from: source.deletingLastPathComponent().deletingLastPathComponent())
        let imported = try await XCTUnwrap(services.store).pages()
        XCTAssertEqual(imported.first?.title, "from WAL")
        XCTAssertNotEqual(services.currentWorkspace?.databasePath, source.path)
        let original = try await old.pages()
        XCTAssertEqual(original.first?.title, "from WAL")
    }

    func testCorruptSecondWorkspaceRollsBackWholeRestore() async throws {
        let (directory, services) = try fixture()
        try await services.createWorkspace(name: "Second", summary: "", symbol: "book.fill", color: "blue")
        let archive = try await services.createBackup(in: directory)
        let before = services.workspaces
        let root = directory.appendingPathComponent("Workspaces")
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var files = try ZIPPackage.decode(Data(contentsOf: archive), maximumSize: WorkspaceBackup.maximumSize)
        var manifest = try JSONDecoder().decode(WorkspaceBackup.ArchiveManifest.self, from: XCTUnwrap(files["manifest.json"]))
        let broken = Data("not a database".utf8)
        let path = manifest.workspaces[1].path
        files[path] = broken
        manifest.workspaces[1].databaseSHA256 = SHA256.hash(data: broken).map { String(format: "%02x", $0) }.joined()
        files["manifest.json"] = try JSONEncoder().encode(manifest)
        let bad = directory.appendingPathComponent("corrupt-second.zip")
        try ZIPPackage.encode(files.map { ($0.key, $0.value) }, compressed: true).write(to: bad)
        do { try await services.restoreBackup(from: bad); XCTFail("Invalid second workspace accepted") } catch { }
        XCTAssertEqual(services.workspaces, before)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(folders))
        XCTAssertFalse(services.busy)
    }

    func testLegacyVersionZeroWithExistingColumnsImportsWithoutModifyingSource() async throws {
        let (directory, services) = try fixture()
        let source = directory.appendingPathComponent("legacy-zero.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        let page = UUID().uuidString
        let sql = """
        CREATE TABLE pages (id TEXT PRIMARY KEY, parent_id TEXT, title TEXT NOT NULL, sort_order INTEGER NOT NULL, archived INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL);
        CREATE TABLE blocks (id TEXT PRIMARY KEY, page_id TEXT NOT NULL, kind TEXT NOT NULL, body TEXT NOT NULL, sort_order INTEGER NOT NULL, checked INTEGER NOT NULL DEFAULT 0, language TEXT NOT NULL DEFAULT 'Plain Text', collapsed INTEGER NOT NULL DEFAULT 0);
        INSERT INTO pages VALUES ('\(page)', NULL, 'Legacy zero', 0, 0, 0);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let bytes = try Data(contentsOf: source)
        try await services.importExistingWorkspace(from: source)
        let pages = try await XCTUnwrap(services.store).pages()
        XCTAssertEqual(pages.first?.title, "Legacy zero")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testImportedWorkspaceNamesUseMetadataOrFriendlyFallbackAndUniqueNumbers() async throws {
        let (directory, services) = try fixture()
        let source = directory.appendingPathComponent("Existing/" + UUID().uuidString).appendingPathComponent("velora.sqlite")
        let database = try SQLiteStore(databaseURL: source)
        _ = try await database.createPage()
        try await services.importExistingWorkspace(from: source.deletingLastPathComponent())
        XCTAssertEqual(services.currentWorkspace?.name, L10n.text("导入的工作空间"))
        try await services.importExistingWorkspace(from: source.deletingLastPathComponent())
        XCTAssertEqual(services.currentWorkspace?.name, L10n.text("导入的工作空间") + " 2")
        var metadata = try XCTUnwrap(services.currentWorkspace)
        metadata.name = "项目研发"
        try JSONEncoder().encode(metadata).write(to: source.deletingLastPathComponent().appendingPathComponent("workspace.json"))
        try await services.importExistingWorkspace(from: source)
        XCTAssertEqual(services.currentWorkspace?.name, "项目研发")
        let oldID = UUID()
        let oldSource = directory.appendingPathComponent(oldID.uuidString).appendingPathComponent("velora.sqlite")
        metadata.id = oldID; metadata.name = "原空间名称"; metadata.databasePath = "/old/computer/velora.sqlite"
        let recovered = WorkspaceCatalog.importedProfile(for: oldSource, knownProfiles: [metadata])
        XCTAssertEqual(recovered.name, "原空间名称")
    }

    func testStorageRelocationKeepsMissingInactiveRecordWithoutCreatingEmptyDatabase() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        try await services.createWorkspace(name: "Available", summary: "", symbol: "book.fill", color: "blue")
        let active = try XCTUnwrap(services.currentWorkspace)
        var catalog = try XCTUnwrap(services.catalog)
        let missing = directory.appendingPathComponent("missing/velora.sqlite")
        let index = try XCTUnwrap(catalog.workspaces.firstIndex { $0.id == original.id })
        catalog.workspaces[index].databasePath = missing.path
        try catalog.save(to: directory.appendingPathComponent("workspaces.json"))
        let reopened = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
        try await reopened.relocateStorage(to: directory.appendingPathComponent("Destination/Workspaces"))
        XCTAssertEqual(reopened.workspaces.map(\.id), [active.id])
        XCTAssertEqual(reopened.catalog?.removedWorkspaces.first { $0.id == original.id }?.databasePath, missing.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(reopened.currentWorkspace?.id, active.id)
        _ = try await reopened.createBackup(in: directory)
    }

    func testChoosingStorageLoadsExistingFoldersAndPreservesNamesAcrossImportAndRestart() async throws {
        let (directory, services) = try fixture()
        let external = directory.appendingPathComponent("External")
        let sourceServices = ApplicationServices(catalogURL: external.appendingPathComponent("workspaces.json"), legacyDatabaseURL: external.appendingPathComponent("legacy.sqlite"), startBackgroundServices: false)
        try await sourceServices.createWorkspace(name: "设计资料", summary: "Original description", symbol: "book.fill", color: "blue")
        let named = try XCTUnwrap(sourceServices.currentWorkspace)
        let page = try await XCTUnwrap(sourceServices.store).createPage()
        try await XCTUnwrap(sourceServices.store).renamePage(page.id, title: "Existing content")
        try await services.relocateStorage(to: external.appendingPathComponent("Workspaces"))
        let loaded = try XCTUnwrap(services.workspaces.first { $0.id == named.id })
        XCTAssertEqual(loaded.name, "设计资料")
        XCTAssertEqual(loaded.databasePath, named.databasePath)
        XCTAssertEqual(loaded.summary, "Original description")
        let count = services.workspaces.count
        try await services.relocateStorage(to: external.appendingPathComponent("Workspaces"))
        XCTAssertEqual(services.workspaces.count, count)
        let restarted = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
        XCTAssertEqual(restarted.workspaces.first { $0.id == named.id }?.name, "设计资料")
        try await restarted.switchWorkspace(named.id)
        let pages = try await XCTUnwrap(restarted.store).pages()
        XCTAssertEqual(pages.first?.title, "Existing content")
        let (_, imported) = try fixture()
        try await imported.importExistingWorkspace(from: URL(fileURLWithPath: named.databasePath).deletingLastPathComponent())
        XCTAssertEqual(imported.currentWorkspace?.name, "设计资料")
    }

    func testImportKeepSkipAndReplacePreserveOriginalsAndWorkspaceIdentity() async throws {
        for policy in WorkspaceImportPolicy.allCases {
            let (directory, services) = try fixture()
            let original = try XCTUnwrap(services.currentWorkspace)
            let store = try XCTUnwrap(services.store)
            let page = try await store.createPage()
            try await store.renamePage(page.id, title: "Original")
            let source = directory.appendingPathComponent("Incoming/velora.sqlite")
            try await store.snapshot(to: source)
            try JSONEncoder().encode(original).write(to: source.deletingLastPathComponent().appendingPathComponent("workspace.json"))
            let incoming = try SQLiteStore(databaseURL: source)
            try await incoming.renamePage(page.id, title: "Incoming")
            let plan = try await services.prepareWorkspaceImport(from: source.deletingLastPathComponent())
            XCTAssertEqual(plan.conflicts, [original.name])
            try await services.applyWorkspaceImport(plan, policy: policy)
            let originalPages = try await store.pages()
            XCTAssertEqual(originalPages.first?.title, "Original")
            let incomingPages = try await incoming.pages()
            XCTAssertEqual(incomingPages.first?.title, "Incoming")
            let currentPages = try await XCTUnwrap(services.store).pages()
            switch policy {
            case .keep:
                XCTAssertEqual(services.workspaces.count, 2)
                XCTAssertNotEqual(services.currentWorkspace?.id, original.id)
                XCTAssertEqual(currentPages.first?.title, "Incoming")
            case .skip:
                XCTAssertEqual(services.workspaces, [original])
                XCTAssertEqual(currentPages.first?.title, "Original")
            case .replace:
                XCTAssertEqual(services.workspaces.count, 1)
                XCTAssertEqual(services.currentWorkspace?.id, original.id)
                XCTAssertNotEqual(services.currentWorkspace?.databasePath, original.databasePath)
                XCTAssertEqual(currentPages.first?.title, "Incoming")
                XCTAssertEqual(services.catalog?.removedWorkspaces.last?.databasePath, original.databasePath)
                let reopened = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
                XCTAssertNil(reopened.startupError)
                XCTAssertEqual(reopened.currentWorkspace?.id, original.id)
                let reopenedPages = try await XCTUnwrap(reopened.store).pages()
                XCTAssertEqual(reopenedPages.first?.title, "Incoming")
            }
            XCTAssertFalse(services.busy)
        }
    }

    func testReplacementCommitFailureRestoresOriginalMetadataAndCatalog() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let originalMetadata = URL(fileURLWithPath: original.databasePath).deletingLastPathComponent().appendingPathComponent("workspace.json")
        let metadata = try Data(contentsOf: originalMetadata)
        let source = directory.appendingPathComponent("Incoming/velora.sqlite")
        try await XCTUnwrap(services.store).snapshot(to: source)
        try JSONEncoder().encode(original).write(to: source.deletingLastPathComponent().appendingPathComponent("workspace.json"))
        let catalogURL = directory.appendingPathComponent("workspaces.json")
        try FileManager.default.removeItem(at: catalogURL)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        do { try await services.importExistingWorkspace(from: source, policy: .replace); XCTFail("Invalid catalog target accepted") } catch { }
        XCTAssertEqual(services.workspaces, [original])
        XCTAssertEqual(try Data(contentsOf: originalMetadata), metadata)
        XCTAssertTrue(services.catalog?.removedWorkspaces.isEmpty == true)
        XCTAssertFalse(services.busy)
    }

    func testSameNameDuplicateAndImportingOwnDirectoryCanBeSkipped() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let source = directory.appendingPathComponent("Other/velora.sqlite")
        try await XCTUnwrap(services.store).snapshot(to: source)
        var metadata = original; metadata.id = UUID()
        try JSONEncoder().encode(metadata).write(to: source.deletingLastPathComponent().appendingPathComponent("workspace.json"))
        try await services.importExistingWorkspace(from: source, policy: .skip)
        XCTAssertEqual(services.workspaces, [original])
        try await services.importExistingWorkspace(from: URL(fileURLWithPath: original.databasePath).deletingLastPathComponent(), policy: .skip)
        XCTAssertEqual(services.workspaces, [original])
    }

    func testMovedCurrentWorkspaceCanReconnectToRenamedStorageFolderAndCreateThere() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let page = try await XCTUnwrap(services.store).createPage()
        let moved = directory.appendingPathComponent("Workspaces2")
        try FileManager.default.moveItem(at: directory.appendingPathComponent("Workspaces"), to: moved)
        // Simulate restarting after a Finder move: the old catalog points at a missing active file.
        let reopened = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
        XCTAssertNotNil(reopened.startupError)
        try await reopened.relocateStorage(to: moved)
        XCTAssertNil(reopened.startupError)
        XCTAssertEqual(reopened.currentWorkspace?.id, original.id)
        XCTAssertEqual(reopened.currentWorkspace?.name, original.name)
        XCTAssertEqual(reopened.workspaceDirectoryPath, moved.path)
        let pages = try await XCTUnwrap(reopened.store).pages()
        XCTAssertEqual(pages.map(\.id), [page.id])
        try await reopened.createWorkspace(name: "After move", summary: "", symbol: "book.fill", color: "blue")
        XCTAssertTrue(try XCTUnwrap(reopened.currentWorkspace).databasePath.hasPrefix(moved.path + "/"))
        let again = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
        XCTAssertNil(again.startupError)
        XCTAssertEqual(again.workspaceDirectoryPath, moved.path)
    }

    func testImportSkipRecognizesExistingUnregisteredFolder() async throws {
        let (directory, services) = try fixture()
        let id = UUID()
        let source = directory.appendingPathComponent("Workspaces/" + id.uuidString).appendingPathComponent("velora.sqlite")
        _ = try SQLiteStore(databaseURL: source)
        var metadata = try XCTUnwrap(services.currentWorkspace)
        metadata.id = id; metadata.name = "Already on disk"; metadata.databasePath = source.path
        try JSONEncoder().encode(metadata).write(to: source.deletingLastPathComponent().appendingPathComponent("workspace.json"))
        let plan = try await services.prepareWorkspaceImport(from: source)
        XCTAssertEqual(plan.conflicts, ["Already on disk"])
        try await services.applyWorkspaceImport(plan, policy: .skip)
        XCTAssertEqual(services.workspaces.count, 2)
        XCTAssertEqual(services.workspaces.first { $0.id == id }?.databasePath, source.path)
    }

    func testReplacingOwnWorkspaceIncludesPendingTextAndKeepsRecoveryCopy() async throws {
        let (_, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let store = try XCTUnwrap(services.store)
        let page = try await store.createPage()
        let block = try await store.createBlock(pageID: page.id, kind: .paragraph)
        let model = try XCTUnwrap(services.model)
        await model.refreshPages(); model.select(page.id)
        for _ in 0..<100 where model.blocks.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        model.changeText("Pending before import", in: block)
        try await services.importExistingWorkspace(from: URL(fileURLWithPath: original.databasePath).deletingLastPathComponent(), policy: .replace)
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
        let blocks = try await XCTUnwrap(services.store).blocks(in: page.id)
        XCTAssertEqual(blocks.first?.text, "Pending before import")
        XCTAssertTrue(services.catalog?.removedWorkspaces.contains { $0.databasePath == original.databasePath } == true)
    }

    func testImportCanRecoverStartupWithMissingActiveDatabaseWithoutCreatingEmptyOldFile() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let source = directory.appendingPathComponent("Saved/velora.sqlite")
        let page = try await XCTUnwrap(services.store).createPage()
        try await XCTUnwrap(services.store).snapshot(to: source)
        var catalog = try XCTUnwrap(services.catalog)
        let missing = directory.appendingPathComponent("Missing/velora.sqlite")
        catalog.workspaces[0].databasePath = missing.path
        try catalog.save(to: directory.appendingPathComponent("workspaces.json"))
        let failed = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
        XCTAssertNotNil(failed.startupError)
        try await failed.importExistingWorkspace(from: source, policy: .keep)
        XCTAssertNil(failed.startupError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertTrue(failed.catalog?.removedWorkspaces.contains { $0.id == original.id && $0.databasePath == missing.path } == true)
        let pages = try await XCTUnwrap(failed.store).pages()
        XCTAssertEqual(pages.map(\.id), [page.id])
    }

    func testRefreshFindsManuallyMovedFoldersWithoutChangingCurrentEditorAndIsIdempotent() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        let model = try XCTUnwrap(services.model)
        let source = directory.appendingPathComponent("Outside/velora.sqlite")
        let external = try SQLiteStore(databaseURL: source)
        let page = try await external.createPage()
        for name in ["Moved A", "Moved B"] {
            var profile = original
            profile.id = UUID(); profile.name = name
            let folder = directory.appendingPathComponent("Workspaces/" + profile.id.uuidString)
            try await external.snapshot(to: folder.appendingPathComponent("velora.sqlite"))
            try JSONEncoder().encode(profile).write(to: folder.appendingPathComponent("workspace.json"))
        }
        try await services.refreshWorkspaces()
        XCTAssertEqual(services.workspaces.count, 3)
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
        XCTAssertTrue(services.model === model)
        XCTAssertEqual(Set(services.workspaces.map(\.name)).count, 3)
        try await services.refreshWorkspaces()
        XCTAssertEqual(services.workspaces.count, 3)
        let discovered = try XCTUnwrap(services.workspaces.first { $0.name == "Moved A" })
        try await services.switchWorkspace(discovered.id)
        let pages = try await XCTUnwrap(services.store).pages()
        XCTAssertEqual(pages.map(\.id), [page.id])
    }

    func testRefreshDoesNotRestoreDeletedFoldersOrExposeReplacementArchives() async throws {
        let (_, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        try await services.importExistingWorkspace(from: URL(fileURLWithPath: original.databasePath).deletingLastPathComponent(), policy: .replace)
        XCTAssertTrue(services.catalog?.removedWorkspaces.last?.replacementArchive == true)
        try await services.createWorkspace(name: "Returned", summary: "", symbol: "book.fill", color: "blue")
        let returned = try XCTUnwrap(services.currentWorkspace)
        try await services.deleteWorkspace(returned.id)
        try await services.refreshWorkspaces()
        XCTAssertEqual(services.workspaces.count, 1)
        XCTAssertFalse(services.workspaces.contains { $0.id == returned.id })
        XCTAssertFalse(services.workspaces.contains { $0.replacementArchive == true })
        try await services.refreshWorkspaces()
        XCTAssertEqual(services.workspaces.count, 1)
    }

    func testMultiSelectionImportsAllDistinctFoldersAndDeduplicatesOverlappingSelection() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        var urls: [URL] = []
        for name in ["Selection A", "Selection B"] {
            let folder = directory.appendingPathComponent("Incoming/" + UUID().uuidString)
            try await XCTUnwrap(services.store).snapshot(to: folder.appendingPathComponent("velora.sqlite"))
            var metadata = original
            metadata.id = UUID(); metadata.name = name
            try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("workspace.json"))
            urls.append(folder)
        }
        let plan = try await services.prepareWorkspaceImport(from: [urls[0], urls[1], urls[0], directory.appendingPathComponent("Incoming")])
        XCTAssertEqual(plan.contents.workspaces.count, 2)
        XCTAssertTrue(plan.conflicts.isEmpty)
        try await services.applyWorkspaceImport(plan, policy: .keep)
        XCTAssertEqual(services.workspaces.count, 3)
        XCTAssertTrue(services.workspaces.contains { $0.name == "Selection A" })
        XCTAssertTrue(services.workspaces.contains { $0.name == "Selection B" })
        let repeated = try await services.prepareWorkspaceImport(from: urls)
        XCTAssertEqual(repeated.conflicts.count, 2)
        try await services.applyWorkspaceImport(repeated, policy: .skip)
        XCTAssertEqual(services.workspaces.count, 3)
    }

    func testWorkspaceDeletionCatalogFailureRestoresFolderAndLiveConnection() async throws {
        let (directory, services) = try fixture()
        try await services.createWorkspace(name: "Delete rollback", summary: "", symbol: "book.fill", color: "blue")
        let original = try XCTUnwrap(services.currentWorkspace)
        let model = try XCTUnwrap(services.model)
        let store = try XCTUnwrap(services.store)
        let page = try await store.createPage()
        let folder = URL(fileURLWithPath: original.databasePath).deletingLastPathComponent()
        try Data("included file".utf8).write(to: folder.appendingPathComponent("attachment.txt"))
        let catalogURL = directory.appendingPathComponent("workspaces.json")
        try FileManager.default.removeItem(at: catalogURL)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        do { try await services.deleteWorkspace(original.id); XCTFail("Invalid catalog destination accepted") } catch { }
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
        XCTAssertTrue(services.model === model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("attachment.txt").path))
        let pages = try await store.pages()
        XCTAssertEqual(pages.map(\.id), [page.id])
        _ = try await store.createPage()
        XCTAssertFalse(services.busy)
    }

    func testWorkspaceDeletionRefusesSharedFolderAndMissingFallback() async throws {
        let (directory, services) = try fixture()
        let first = try XCTUnwrap(services.currentWorkspace)
        try await services.createWorkspace(name: "Another", summary: "", symbol: "book.fill", color: "blue")
        let second = try XCTUnwrap(services.currentWorkspace)
        var catalog = try XCTUnwrap(services.catalog)
        var alias = first
        alias.id = UUID(); alias.name = "Shared alias"; alias.databasePath = second.databasePath
        catalog.removedWorkspaces.append(alias)
        // Write only the central catalog: this deliberately malformed reference must not rewrite folder ownership.
        try JSONEncoder().encode(catalog).write(to: directory.appendingPathComponent("workspaces.json"), options: .atomic)
        let reopened = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
        try JSONEncoder().encode(second).write(to: URL(fileURLWithPath: second.databasePath).deletingLastPathComponent().appendingPathComponent("workspace.json"), options: .atomic)
        do { try await reopened.deleteWorkspace(second.id); XCTFail("Shared folder accepted") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.databasePath))
        XCTAssertEqual(reopened.workspaces.count, 2)
        // A missing replacement must be rejected before moving the current folder.
        catalog.removedWorkspaces.removeAll()
        catalog.workspaces[0].databasePath = directory.appendingPathComponent("Missing/velora.sqlite").path
        try JSONEncoder().encode(catalog).write(to: directory.appendingPathComponent("workspaces.json"), options: .atomic)
        let missingFallback = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
        do { try await missingFallback.deleteWorkspace(second.id); XCTFail("Missing fallback accepted") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.databasePath))
    }

    func testDeletionIgnoresMissingHistoricalNestedReferencesButPreservesTheirRecords() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        try await services.createWorkspace(name: "Survivor", summary: "", symbol: "book.fill", color: "blue")
        var catalog = try XCTUnwrap(services.catalog)
        var stale = original
        stale.id = UUID(); stale.name = "Old migrated space"
        stale.databasePath = URL(fileURLWithPath: original.databasePath).deletingLastPathComponent()
            .appendingPathComponent("Workspaces/" + stale.id.uuidString + "/velora.sqlite").path
        catalog.removedWorkspaces.append(stale)
        try catalog.save(to: directory.appendingPathComponent("workspaces.json"))
        let reopened = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
        try await reopened.deleteWorkspace(original.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: original.databasePath).deletingLastPathComponent().path))
        XCTAssertTrue(reopened.catalog?.removedWorkspaces.contains { $0.id == stale.id } == true)
        XCTAssertEqual(reopened.workspaces.count, 1)
        XCTAssertFalse(reopened.busy)
    }

    func testDeletionProtectsActualNestedHistoricalDatabase() async throws {
        let (directory, services) = try fixture()
        let original = try XCTUnwrap(services.currentWorkspace)
        try await services.createWorkspace(name: "Survivor", summary: "", symbol: "book.fill", color: "blue")
        var catalog = try XCTUnwrap(services.catalog)
        var nested = original
        nested.id = UUID(); nested.name = "Real nested archive"
        let path = URL(fileURLWithPath: original.databasePath).deletingLastPathComponent()
            .appendingPathComponent("Workspaces/" + nested.id.uuidString + "/velora.sqlite")
        let nestedStore = try SQLiteStore(databaseURL: path)
        let page = try await nestedStore.createPage()
        nested.databasePath = path.path
        catalog.removedWorkspaces.append(nested)
        try catalog.save(to: directory.appendingPathComponent("workspaces.json"))
        let reopened = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
        do { try await reopened.deleteWorkspace(original.id); XCTFail("Real nested archive must be protected") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.databasePath))
        let pages = try await nestedStore.pages()
        XCTAssertEqual(pages.map(\.id), [page.id])
        XCTAssertEqual(reopened.workspaces.count, 2)
    }

    func testWorkspaceRecycleBinPreservesContentRestoresAfterRestartAndPurgesOnlyOnRequest() async throws {
        let (directory, services) = try fixture()
        let first = try XCTUnwrap(services.currentWorkspace)
        try await services.createWorkspace(name: "Recoverable", summary: "Keep description", symbol: "book.fill", color: "blue")
        let original = try XCTUnwrap(services.currentWorkspace)
        let store = try XCTUnwrap(services.store)
        let page = try await store.createPage()
        let block = try await store.createBlock(pageID: page.id, kind: .paragraph)
        try await store.updateBlock(block.id, text: "Keep all content")
        let sourceFolder = URL(fileURLWithPath: original.databasePath).deletingLastPathComponent()
        try Data("file contents".utf8).write(to: sourceFolder.appendingPathComponent("attachment.txt"))
        try await services.deleteWorkspace(original.id)
        XCTAssertEqual(services.currentWorkspace?.id, first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFolder.path))
        let recycled = try XCTUnwrap(services.trashedWorkspaces.first { $0.id == original.id })
        let recycleFolder = URL(fileURLWithPath: recycled.databasePath).deletingLastPathComponent()
        XCTAssertTrue(recycled.databasePath.contains("/.Trash/"))
        XCTAssertEqual(try Data(contentsOf: recycleFolder.appendingPathComponent("attachment.txt")), Data("file contents".utf8))
        try await services.refreshWorkspaces()
        XCTAssertEqual(services.workspaces.count, 1)
        let reopened = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
        XCTAssertEqual(reopened.trashedWorkspaces.count, 1)
        try await reopened.restoreWorkspace(original.id)
        XCTAssertTrue(reopened.trashedWorkspaces.isEmpty)
        let restored = try XCTUnwrap(reopened.workspaces.first { $0.id == original.id })
        XCTAssertEqual(restored.name, original.name)
        XCTAssertNil(restored.trashedAt)
        let restoredStore = try SQLiteStore(databaseURL: URL(fileURLWithPath: restored.databasePath))
        let blocks = try await restoredStore.blocks(in: page.id)
        XCTAssertEqual(blocks.first?.text, "Keep all content")
        try await reopened.deleteWorkspace(original.id)
        let toPurge = try XCTUnwrap(reopened.trashedWorkspaces.first)
        try await reopened.permanentlyDeleteWorkspace(original.id)
        XCTAssertTrue(reopened.trashedWorkspaces.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: toPurge.databasePath).deletingLastPathComponent().path))
    }

    func testWorkspaceTrashBulkRestoreClearAndAllDeleteCreateNewBlankWorkspace() async throws {
        let (_, services) = try fixture()
        try await services.createWorkspace(name: "Second", summary: "", symbol: "book.fill", color: "blue")
        let ids = Set(services.workspaces.map(\.id))
        try await services.deleteAllWorkspaces()
        XCTAssertEqual(services.workspaces.count, 1)
        XCTAssertFalse(ids.contains(try XCTUnwrap(services.currentWorkspace).id))
        XCTAssertEqual(Set(services.trashedWorkspaces.map(\.id)), ids)
        let folders = services.trashedWorkspaces.map { URL(fileURLWithPath: $0.databasePath).deletingLastPathComponent() }
        XCTAssertTrue(folders.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        try await services.restoreAllWorkspaces()
        XCTAssertEqual(services.workspaces.count, 3)
        XCTAssertTrue(services.trashedWorkspaces.isEmpty)
        for id in ids { try await services.deleteWorkspace(id) }
        let finalFolders = services.trashedWorkspaces.map { URL(fileURLWithPath: $0.databasePath).deletingLastPathComponent() }
        try await services.emptyWorkspaceTrash()
        XCTAssertTrue(services.trashedWorkspaces.isEmpty)
        XCTAssertTrue(finalFolders.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(services.workspaces.count, 1)
    }

    func testWorkspaceTrashMovesWithStorageAndRoundTripsInFullZIP() async throws {
        let (directory, services) = try fixture()
        try await services.createWorkspace(name: "Deleted space", summary: "", symbol: "book.fill", color: "blue")
        let id = try XCTUnwrap(services.currentWorkspace).id
        let page = try await XCTUnwrap(services.store).createPage()
        try await services.deleteWorkspace(id)
        try await services.relocateStorage(to: directory.appendingPathComponent("NewStorage"))
        let recycled = try XCTUnwrap(services.trashedWorkspaces.first)
        XCTAssertTrue(recycled.databasePath.hasPrefix(directory.appendingPathComponent("NewStorage/Workspaces/.Trash").path))
        let archive = try await services.createBackup(in: directory)
        try await services.restoreBackup(from: archive)
        XCTAssertEqual(services.trashedWorkspaces.count, 2)
        let imported = try XCTUnwrap(services.trashedWorkspaces.first { $0.id != id })
        XCTAssertTrue(imported.databasePath.contains("/.Trash/"))
        try await services.restoreWorkspace(imported.id)
        let profile = try XCTUnwrap(services.workspaces.first { $0.id == imported.id })
        let database = try SQLiteStore(databaseURL: URL(fileURLWithPath: profile.databasePath))
        let pages = try await database.pages()
        XCTAssertEqual(pages.map(\.id), [page.id])
    }

    func testWorkspaceTrashPurgeCatalogFailureKeepsRecoverableFiles() async throws {
        let (directory, services) = try fixture()
        try await services.createWorkspace(name: "Purging", summary: "", symbol: "book.fill", color: "blue")
        let id = try XCTUnwrap(services.currentWorkspace).id
        try await services.deleteWorkspace(id)
        let trashed = try XCTUnwrap(services.trashedWorkspaces.first)
        let catalogURL = directory.appendingPathComponent("workspaces.json")
        try FileManager.default.removeItem(at: catalogURL)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
        do { try await services.permanentlyDeleteWorkspace(id); XCTFail("Invalid catalog destination accepted") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.databasePath))
        XCTAssertEqual(services.trashedWorkspaces.map(\.id), [id])
        XCTAssertFalse(services.busy)
    }

    func testDocumentsBulkTrashRestoreAndPurgeKeepIndependentDeletionBatches() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".agents/test/DocumentRecycle-" + UUID().uuidString)
        let store = try SQLiteStore(databaseURL: directory.appendingPathComponent("velora.sqlite"))
        let a = try await store.createPage()
        let child = try await store.createPage(parentID: a.id)
        let b = try await store.createPage()
        let block = try await store.createBlock(pageID: a.id, kind: .paragraph)
        try await store.updateBlock(block.id, text: "Retained until purge")
        try await store.archiveAllPages()
        var pages = try await store.pages()
        XCTAssertTrue(pages.allSatisfy(\.archived))
        let retained = try await store.blocks(in: a.id)
        XCTAssertEqual(retained.first?.text, "Retained until purge")
        try await store.restorePage(a.id)
        pages = try await store.pages()
        XCTAssertTrue(pages.first { $0.id == b.id }?.archived == true)
        XCTAssertTrue(pages.first { $0.id == child.id }?.archived == false)
        try await store.restoreAllPages()
        pages = try await store.pages()
        XCTAssertTrue(pages.allSatisfy { !$0.archived })
        try await store.archivePage(a.id, archived: true)
        try await store.permanentlyDeletePage(a.id)
        pages = try await store.pages()
        XCTAssertEqual(pages.map(\.id), [b.id])
        try await store.archiveAllPages(); try await store.emptyTrash()
        pages = try await store.pages()
        XCTAssertTrue(pages.isEmpty)
        let removedBlocks = try await store.blocks(in: a.id)
        XCTAssertTrue(removedBlocks.isEmpty)
    }

    func testRefreshDoesNotResurrectOldMigrationCopyOfRecycledWorkspace() async throws {
        let (directory, services) = try fixture()
        try await services.createWorkspace(name: "Duplicate history", summary: "", symbol: "book.fill", color: "blue")
        let original = try XCTUnwrap(services.currentWorkspace)
        let oldCopy = directory.appendingPathComponent("Workspaces/old-migration-copy")
        try await XCTUnwrap(services.store).snapshot(to: oldCopy.appendingPathComponent("velora.sqlite"))
        try JSONEncoder().encode(original).write(to: oldCopy.appendingPathComponent("workspace.json"))
        try await services.deleteWorkspace(original.id)
        let recyclePath = try XCTUnwrap(services.trashedWorkspaces.first).databasePath
        try await services.refreshWorkspaces()
        XCTAssertEqual(services.workspaces.count, 1)
        XCTAssertEqual(services.trashedWorkspaces.map(\.id), [original.id])
        XCTAssertEqual(services.trashedWorkspaces.first?.databasePath, recyclePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recyclePath))
    }

    func testRefreshArchivesDuplicateDirectoriesWithoutOverwritingCurrentOrDiscardingOlderContent() async throws {
        let (directory, services) = try fixture()
        let profile = try XCTUnwrap(services.currentWorkspace)
        let store = try XCTUnwrap(services.store)
        let page = try await store.createPage()
        try await store.renamePage(page.id, title: "Current")
        let duplicate = directory.appendingPathComponent("Workspaces/" + profile.id.uuidString + "-old-copy")
        try await store.snapshot(to: duplicate.appendingPathComponent("velora.sqlite"))
        try JSONEncoder().encode(profile).write(to: duplicate.appendingPathComponent("workspace.json"))
        let old = try SQLiteStore(databaseURL: duplicate.appendingPathComponent("velora.sqlite"))
        _ = try await old.createPage()
        try await services.refreshWorkspaces()
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.databasePath))
        XCTAssertEqual(services.workspaces.count, 1)
        let current = try await store.pages()
        XCTAssertEqual(current.count, 1)
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("backup"), includingPropertiesForKeys: nil)
        let group = try XCTUnwrap(backups.first { $0.lastPathComponent.hasPrefix("WorkspaceCopies-") })
        let archive = group.appendingPathComponent(duplicate.lastPathComponent).appendingPathComponent("velora.sqlite")
        let archived = try SQLiteStore(databaseURL: archive)
        let historical = try await archived.pages()
        XCTAssertEqual(historical.count, 2)
        try await services.refreshWorkspaces()
        XCTAssertEqual(services.workspaces.count, 1)
    }

    func testDeletingWorkspaceCollectsAllUnregisteredCopiesAndPermanentDeleteRemovesThem() async throws {
        let (directory, services) = try fixture()
        try await services.createWorkspace(name: "Copies", summary: "", symbol: "book.fill", color: "blue")
        let original = try XCTUnwrap(services.currentWorkspace)
        let duplicate = directory.appendingPathComponent("Workspaces/" + original.id.uuidString + "-copy")
        try await XCTUnwrap(services.store).snapshot(to: duplicate.appendingPathComponent("velora.sqlite"))
        try JSONEncoder().encode(original).write(to: duplicate.appendingPathComponent("workspace.json"))
        try await services.deleteWorkspace(original.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.databasePath))
        let trashed = try XCTUnwrap(services.trashedWorkspaces.first)
        let recycleFolder = URL(fileURLWithPath: trashed.databasePath).deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: recycleFolder.appendingPathComponent(".MigrationCopies/" + duplicate.lastPathComponent + "/velora.sqlite").path))
        try await services.permanentlyDeleteWorkspace(original.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recycleFolder.path))
        try await services.refreshWorkspaces()
        XCTAssertFalse(services.workspaces.contains { $0.id == original.id })
    }

    func testRestartDoesNotCloneDedicatedUUIDSuffixFolderIntoCanonicalFolder() async throws {
        let (directory, services) = try fixture()
        var catalog = try XCTUnwrap(services.catalog)
        let original = catalog.active
        let canonical = URL(fileURLWithPath: original.databasePath).deletingLastPathComponent()
        let suffixed = canonical.deletingLastPathComponent().appendingPathComponent(original.id.uuidString + "-migration")
        try FileManager.default.moveItem(at: canonical, to: suffixed)
        catalog.workspaces[0].databasePath = suffixed.appendingPathComponent("velora.sqlite").path
        try catalog.save(to: directory.appendingPathComponent("workspaces.json"))
        for _ in 0..<2 {
            let reopened = ApplicationServices(catalogURL: directory.appendingPathComponent("workspaces.json"), startBackgroundServices: false)
            XCTAssertNil(reopened.startupError)
            XCTAssertEqual(reopened.currentWorkspace?.databasePath, suffixed.appendingPathComponent("velora.sqlite").path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
        }
    }

    func testLegacySingleWorkspaceZIPRemainsRestorable() async throws {
        let (directory, services) = try fixture()
        let page = try await XCTUnwrap(services.store).createPage()
        let snapshot = directory.appendingPathComponent("legacy.sqlite")
        try await XCTUnwrap(services.store).snapshot(to: snapshot)
        let archive = directory.appendingPathComponent("legacy.zip")
        try WorkspaceBackup.write(snapshot: snapshot, profile: XCTUnwrap(services.currentWorkspace), to: archive)
        try await services.restoreBackup(from: archive)
        let pages = try await XCTUnwrap(services.store).pages()
        XCTAssertEqual(pages.map(\.id), [page.id])
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
        let unpacked = try WorkspaceBackup.readAll(archive)
        XCTAssertLessThan(bytes.count, unpacked.workspaces[0].database.count)
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
        let databasePath = try XCTUnwrap(package.keys.first { $0.hasSuffix("/velora.sqlite") })
        package[databasePath] = Data("invalid database".utf8)
        let bad = directory.appendingPathComponent("bad.zip")
        try ZIPPackage.encode(package.map { ($0.key, $0.value) }, compressed: true).write(to: bad)
        do { try await services.restoreBackup(from: bad); XCTFail("Corrupt backup was accepted") } catch { }
        XCTAssertEqual(services.currentWorkspace?.id, original.id)
        XCTAssertEqual(services.workspaces.count, 1)
        XCTAssertFalse(services.busy)
        XCTAssertFalse(services.model?.workspaceTransitioning ?? true)
        var metadata = try JSONDecoder().decode(WorkspaceBackup.ArchiveManifest.self, from: package["manifest.json"]!)
        metadata.workspaces[0].databaseSHA256 = SHA256.hash(data: package[databasePath]!).map { String(format: "%02x", $0) }.joined()
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
