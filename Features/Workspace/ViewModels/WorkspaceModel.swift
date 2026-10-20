import Foundation
import SwiftUI

struct DocumentBoundaryRequest {
    let id = UUID()
    let atStart: Bool
}

struct EditorFocusRequest {
    let id = UUID()
    let blockID: UUID
    let offset: Int
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var pages: [Page] = []
    @Published private(set) var blocks: [Block] = []
    @Published private(set) var selectedBlockIDs: Set<UUID> = []
    @Published private(set) var documentBoundaryRequest: DocumentBoundaryRequest?
    private var blockSelectionAnchor: UUID?
    var activeEditingBlockID: UUID?
    @Published var selectedPageID: UUID?
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published private(set) var saving = false
    @Published private(set) var automationBusy = false
    var workspaceTransitioning = false

    @Published private(set) var editorFocusRequest: EditorFocusRequest?

    private var creatingTrailingInput: Set<UUID> = []
    private let store: SQLiteStore
    private var pendingWrites: [UUID: Task<Void, Never>] = [:]
    private var latestText: [UUID: String] = [:]
    private var latestFormatting: [UUID: [TextStyleRun]] = [:]

    init(store: SQLiteStore) {
        self.store = store
        Task { await refreshPages() }
    }

    var selectedPage: Page? { pages.first { $0.id == selectedPageID } }

    var visiblePages: [Page] {
        let active = pages.filter { !$0.archived }
        guard !searchText.isEmpty else { return active }
        return active.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    func refreshPages() async {
        do { pages = try await store.pages() }
        catch { report(error) }
    }

    func select(_ pageID: UUID?) {
        selectedPageID = pageID
        selectedBlockIDs = []; blockSelectionAnchor = nil; activeEditingBlockID = nil
        blocks = []
        guard let pageID else { return }
        Task {
            do {
                let loaded = try await store.blocks(in: pageID)
                if selectedPageID == pageID {
                    blocks = loaded
                    ensurePageHasInput()
                }
            } catch { report(error) }
        }
    }

    func createPage(parentID: UUID? = nil) {
        Task {
            do {
                let page = try await store.createPage(parentID: parentID)
                await refreshPages()
                select(page.id)
            } catch { report(error) }
        }
    }

    func renameSelectedPage(_ title: String) {
        guard let id = selectedPageID else { return }
        if let index = pages.firstIndex(where: { $0.id == id }) { pages[index].title = title }
        Task {
            do { try await store.renamePage(id, title: title) }
            catch { report(error) }
        }
    }

    func archive(_ page: Page) {
        Task {
            do {
                await flushAll()
                try await store.archivePage(page.id, archived: true)
                await refreshPages()
                if selectedPage?.archived == true { select(nil) }
            } catch { report(error) }
        }
    }

    var trashedPages: [Page] {
        pages.filter { page in
            guard page.archived else { return false }
            guard let parentID = page.parentID, let parent = pages.first(where: { $0.id == parentID }), parent.archived else { return true }
            return page.trashBatch == nil || page.trashBatch != parent.trashBatch
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func isDescendant(_ candidate: UUID, of pageID: UUID) -> Bool {
        var current: UUID? = candidate
        var visited: Set<UUID> = []
        while let id = current, visited.insert(id).inserted {
            if id == pageID { return true }
            current = pages.first(where: { $0.id == id })?.parentID
        }
        return false
    }

    func move(_ page: Page, to parentID: UUID?, before beforeID: UUID? = nil) {
        Task {
            do {
                try await store.movePage(page.id, toParent: parentID, before: beforeID)
                await refreshPages()
            } catch { report(error) }
        }
    }

    func move(_ page: Page, by offset: Int) {
        let siblings = pages.filter { !$0.archived && $0.parentID == page.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == page.id }), siblings.indices.contains(index + offset) else { return }
        let beforeIndex = offset < 0 ? index - 1 : index + 2
        move(page, to: page.parentID, before: siblings.indices.contains(beforeIndex) ? siblings[beforeIndex].id : nil)
    }

    func rename(_ page: Page, to title: String) {
        Task {
            do { try await store.renamePage(page.id, title: title); await refreshPages() }
            catch { report(error) }
        }
    }

    func restore(_ page: Page) {
        Task {
            do { try await store.restorePage(page.id); await refreshPages() }
            catch { report(error) }
        }
    }

    func permanentlyDelete(_ page: Page) {
        Task {
            do { try await store.permanentlyDeletePage(page.id); await refreshPages() }
            catch { report(error) }
        }
    }

    func emptyTrash() {
        Task {
            do { try await store.emptyTrash(); await refreshPages() }
            catch { report(error) }
        }
    }

    func addBlock(_ kind: BlockKind = .paragraph, after previous: Block? = nil) {
        guard let id = selectedPageID else { return }
        Task {
            do {
                let block = try await store.createBlock(pageID: id, kind: kind, after: previous)
                if selectedPageID == id {
                    if let previous, let index = blocks.firstIndex(where: { $0.id == previous.id }) {
                        blocks.insert(block, at: index + 1)
                    } else {
                        blocks.append(block)
                    }
                    requestFocus(block.id, offset: 0)
                }
            } catch { report(error) }
        }
    }

    func changeText(_ text: String, in block: Block) {
        changeRichText(text, formatting: [], in: block)
    }

    func changeRichText(_ text: String, formatting: [TextStyleRun], in block: Block) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        guard blocks[index].text != text || blocks[index].formatting != formatting else { return }
        var updated = blocks[index]
        updated.text = text
        updated.formatting = formatting
        blocks[index] = updated
        latestText[block.id] = text
        latestFormatting[block.id] = formatting
        pendingWrites[block.id]?.cancel()
        if !saving { saving = true }
        pendingWrites[block.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.flush(block.id)
        }
    }

    func flush(_ id: UUID) async {
        guard let text = latestText[id] else { return }
        do {
            let formatting = latestFormatting[id] ?? []
            try await store.updateBlock(id, text: text, formatting: formatting)
            if latestText[id] == text && latestFormatting[id] == formatting { latestText[id] = nil; latestFormatting[id] = nil }
            saving = !latestText.isEmpty
        } catch { report(error) }
    }

    func flushAll() async {
        for id in Array(latestText.keys) { await flush(id) }
    }

    func exportDocument(name: String, pageID: UUID?, includeChildren: Bool, includeArchived: Bool) async throws -> TransferDocument {
        guard !workspaceTransitioning, !automationBusy else { throw AppError.message("正在执行其他操作，请稍后重试") }
        automationBusy = true; defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message("存在未保存内容，导出已停止") }
        return try await store.transferSnapshot(name: name, pageID: pageID, includeChildren: includeChildren, includeArchived: includeArchived)
    }

    func importDocument(_ document: TransferDocument) async throws -> Int {
        guard !workspaceTransitioning, !automationBusy else { throw AppError.message("正在执行其他操作，请稍后重试") }
        automationBusy = true; defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message("存在未保存内容，导入已停止") }
        let ids = try await store.importTransfer(document)
        await refreshPages()
        if let first = ids.first(where: { id in pages.contains { $0.id == id && !$0.archived } }) { select(first) }
        return ids.count
    }

    func insertMedia(_ kind: BlockKind, text: String, pageID: UUID) async throws {
        guard !workspaceTransitioning, !automationBusy, [.image, .audio].contains(kind),
              pages.contains(where: { $0.id == pageID && !$0.archived }) else { throw AppError.message("目标页面不可用，请重新选择页面") }
        automationBusy = true
        defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message("尚有内容未保存，请稍后重试") }
        if kind == .image { _ = try ImageSource.validated(text) }
        let block = try await store.createBlock(pageID: pageID, kind: kind)
        try await store.updateBlock(block.id, text: text)
        if selectedPageID == pageID {
            var inserted = block; inserted.text = text; blocks.append(inserted)
        }
    }

    func changeKind(_ kind: BlockKind, of block: Block) {
        Task {
            do {
                try await store.setBlockKind(block.id, kind: kind)
                if let index = blocks.firstIndex(where: { $0.id == block.id }) { blocks[index].kind = kind }
                ensurePageHasInput()
            } catch { report(error) }
        }
    }

    private func ensurePageHasInput() {
        guard let pageID = selectedPageID, !creatingTrailingInput.contains(pageID),
              blocks.isEmpty else { return }
        creatingTrailingInput.insert(pageID)
        Task {
            defer { creatingTrailingInput.remove(pageID) }
            do {
                let block = try await store.createBlock(pageID: pageID, kind: .paragraph)
                if selectedPageID == pageID { blocks.append(block) }
            } catch { report(error) }
        }
    }

    func setBlockOptions(for block: Block, language: String? = nil, collapsed: Bool? = nil) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[index].language = language ?? blocks[index].language
        blocks[index].collapsed = collapsed ?? blocks[index].collapsed
        let updated = blocks[index]
        Task {
            do { try await store.setBlockOptions(updated.id, language: updated.language, collapsed: updated.collapsed) }
            catch { report(error) }
        }
    }

    func toggle(_ block: Block) {
        Task {
            do {
                try await store.setChecked(block.id, checked: !block.checked)
                if let index = blocks.firstIndex(where: { $0.id == block.id }) { blocks[index].checked.toggle() }
            } catch { report(error) }
        }
    }

    func selectBlock(_ id: UUID, extend: Bool = false, toggle: Bool = false) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        if extend, let anchor = blockSelectionAnchor ?? activeEditingBlockID,
           let from = blocks.firstIndex(where: { $0.id == anchor }) {
            selectedBlockIDs = Set(blocks[min(from, index)...max(from, index)].map(\.id))
        } else if toggle {
            if selectedBlockIDs.contains(id) { selectedBlockIDs.remove(id) } else { selectedBlockIDs.insert(id) }
            blockSelectionAnchor = id
        } else { selectedBlockIDs = [id]; blockSelectionAnchor = id }
    }

    func selectAllBlocks() { selectedBlockIDs = Set(blocks.map(\.id)); blockSelectionAnchor = blocks.first?.id }
    func clearBlockSelection() { selectedBlockIDs = []; blockSelectionAnchor = nil }

    func jumpToDocumentBoundary(atStart: Bool, extend: Bool = false) {
        if extend, let anchor = blockSelectionAnchor ?? activeEditingBlockID, let index = blocks.firstIndex(where: { $0.id == anchor }) {
            selectedBlockIDs = Set((atStart ? Array(blocks[...index]) : Array(blocks[index...])).map(\.id))
        } else { clearBlockSelection() }
        documentBoundaryRequest = DocumentBoundaryRequest(atStart: atStart)
        guard !extend else { return }
        let editable = blocks.filter { ![.image, .divider, .table, .tableOfContents].contains($0.kind) }
        if let target = atStart ? editable.first : editable.last {
            if target.collapsed { setBlockOptions(for: target, collapsed: false) }
            requestFocus(target.id, offset: atStart ? 0 : target.text.utf16.count)
        }
    }

    func deleteSelectedBlocks() async throws {
        guard !selectedBlockIDs.isEmpty, !workspaceTransitioning, !automationBusy else { return }
        automationBusy = true; defer { automationBusy = false }
        let ids = selectedBlockIDs.intersection(Set(blocks.map(\.id)))
        for id in ids { pendingWrites[id]?.cancel(); pendingWrites[id] = nil }
        try await store.deleteBlocks(Array(ids))
        for id in ids { latestText[id] = nil; latestFormatting[id] = nil }
        blocks.removeAll { ids.contains($0.id) }
        saving = !latestText.isEmpty; clearBlockSelection()
        if blocks.isEmpty, let pageID = selectedPageID {
            let block = try await store.createBlock(pageID: pageID, kind: .paragraph)
            blocks = [block]; requestFocus(block.id, offset: 0)
        }
    }

    func requestFocus(_ blockID: UUID, offset: Int) {
        editorFocusRequest = EditorFocusRequest(blockID: blockID, offset: offset)
    }

    /// Called only for Backspace at the beginning of an editor, outside IME composition.
    func backspaceAtStart(of block: Block) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return false }
        let current = blocks[index]
        if current.text.isEmpty && current.kind != .paragraph {
            changeKind(.paragraph, of: current)
            return true
        }
        guard index > 0 else { return false }
        if current.text.isEmpty {
            delete(current, focusPrevious: true)
            return true
        }
        return false
    }

    func delete(_ block: Block, focusPrevious: Bool = false) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let pageID = selectedPageID
        let target = index > 0 ? blocks[index - 1] : blocks.dropFirst().first
        pendingWrites[block.id]?.cancel()
        pendingWrites[block.id] = nil
        latestText[block.id] = nil
        latestFormatting[block.id] = nil
        selectedBlockIDs.remove(block.id)
        saving = !latestText.isEmpty
        blocks.remove(at: index)
        if focusPrevious, let target {
            if target.collapsed { setBlockOptions(for: target, collapsed: false) }
            requestFocus(target.id, offset: target.text.utf16.count)
        }
        Task {
            do {
                try await store.deleteBlock(block.id)
                if selectedPageID == pageID { ensurePageHasInput() }
            } catch {
                report(error)
                // Restore the row on a failed write rather than silently hiding stored data.
                if selectedPageID == pageID, !blocks.contains(where: { $0.id == block.id }) {
                    blocks.insert(block, at: min(index, blocks.count))
                }
            }
        }
    }

    func performSearch(_ query: String) async -> [Page] {
        do { return try await store.search(query) }
        catch { report(error); return [] }
    }

    private func report(_ error: Error) { errorMessage = error.localizedDescription }
}

extension WorkspaceModel {
    static var automationTools: [[String: Any]] {
        let definitions: [(String, String, [String], [String])] = [
            ("list_pages", "List active pages with IDs, titles, and parent IDs.", ["query"], []),
            ("read_page", "Read a page and its blocks.", ["page_id"], ["page_id"]),
            ("create_page", "Create a page; parent_id is optional (root when empty).", ["title", "parent_id"], ["title"]),
            ("rename_page", "Rename an active page.", ["page_id", "title"], ["page_id", "title"]),
            ("move_page", "Move a page and descendants; omit parent_id or use empty string for root.", ["page_id", "parent_id"], ["page_id"]),
            ("trash_page", "Move a page and its active descendants to trash, recoverably.", ["page_id"], ["page_id"]),
            ("restore_page", "Restore a trashed page and its deletion batch.", ["page_id"], ["page_id"]),
            ("append_text", "Append a plain text block to an active page.", ["page_id", "text"], ["page_id", "text"]),
            ("open_page", "Open an active page in Velora.", ["page_id"], ["page_id"])
        ]
        return definitions.map { name, description, properties, required in
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0, ["type": "string"]) }),
                             "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": ["list_pages", "read_page"].contains(name), "destructiveHint": name == "trash_page"]] as [String: Any]
        }
    }

    func executeTool(_ name: String, arguments: [String: String]) async throws -> Any {
        guard !automationBusy, !workspaceTransitioning else { throw AppError.message("已有操作正在执行，请稍后重试") }
        automationBusy = true
        defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message("存在未保存内容，操作已停止") }
        await refreshPages()
        func id(_ key: String) throws -> UUID {
            guard let value = arguments[key], let id = UUID(uuidString: value) else { throw AppError.message("缺少有效的 \(key)") }
            return id
        }
        func active(_ id: UUID) throws {
            guard pages.contains(where: { $0.id == id && !$0.archived }) else { throw StoreError.missingPage }
        }
        func parent() throws -> UUID? {
            guard let value = arguments["parent_id"], !value.isEmpty else { return nil }
            guard let id = UUID(uuidString: value) else { throw StoreError.invalidMove }
            try active(id)
            return id
        }
        func record(_ page: Page) -> [String: Any] {
            ["id": page.id.uuidString, "title": page.title, "parent_id": page.parentID?.uuidString ?? "", "trashed": page.archived]
        }
        var result: Any = ["success": true]
        switch name {
        case "list_pages":
            let query = arguments["query"] ?? ""
            return pages.filter { !$0.archived && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }.map(record)
        case "read_page":
            let pageID = try id("page_id"); try active(pageID)
            guard let page = pages.first(where: { $0.id == pageID }) else { throw StoreError.missingPage }
            let content = try await store.blocks(in: pageID)
            return ["page": record(page), "blocks": content.map {
                ["id": $0.id.uuidString, "type": $0.kind.rawValue, "text": $0.text, "language": $0.language]
            }] as [String: Any]
        case "create_page":
            let page = try await store.createPage(parentID: parent())
            try await store.renamePage(page.id, title: arguments["title"] ?? "未命名")
            result = ["page_id": page.id.uuidString]
        case "rename_page":
            let pageID = try id("page_id"); try active(pageID)
            guard let title = arguments["title"] else { throw AppError.message("缺少标题") }
            try await store.renamePage(pageID, title: title)
        case "move_page":
            let pageID = try id("page_id"); try active(pageID)
            try await store.movePage(pageID, toParent: parent())
        case "trash_page":
            let pageID = try id("page_id"); try active(pageID)
            try await store.archivePage(pageID, archived: true)
        case "restore_page": try await store.restorePage(id("page_id"))
        case "append_text":
            let pageID = try id("page_id"); try active(pageID)
            guard let text = arguments["text"], !text.isEmpty else { throw AppError.message("正文不能为空") }
            let block = try await store.createBlock(pageID: pageID, kind: .paragraph)
            try await store.updateBlock(block.id, text: text)
        case "open_page":
            let pageID = try id("page_id"); try active(pageID)
            selectedPageID = pageID
        default: throw AppError.message("不支持的操作：\(name)")
        }
        await refreshPages()
        if let selectedPageID {
            if selectedPage?.archived == true { select(nil) }
            else {
                let loaded = try await store.blocks(in: selectedPageID)
                if self.selectedPageID == selectedPageID {
                    blocks = loaded.map { block in
                        var block = block
                        if let pending = latestText[block.id] { block.text = pending }
                        return block
                    }
                }
            }
        }
        return result
    }
}

