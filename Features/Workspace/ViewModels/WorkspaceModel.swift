import Foundation
import SwiftUI

struct DocumentBoundaryRequest {
    let id = UUID()
    let atStart: Bool
}

struct EditorFocusRequest: Equatable {
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
    @Published private(set) var editorContentRevisions: [UUID: UInt64] = [:]
    private var pendingConversions: [UUID: Task<Void, Never>] = [:]

    private var pageLoadTask: Task<Void, Never>?
    private var pageLoadGeneration = UUID()
    private var loadedPageID: UUID?
    private var pageCache: [UUID: [Block]] = [:]
    private var cachedPageOrder: [UUID] = []

    private func cacheCurrentPage() {
        guard let id = loadedPageID, id == selectedPageID else { return }
        // Bound retained content, especially embedded PDF/image data URLs.
        let size = blocks.reduce(0) { $0 + $1.text.utf8.count }
        guard size <= 4 * 1024 * 1024 else {
            pageCache[id] = nil
            cachedPageOrder.removeAll { $0 == id }
            return
        }
        pageCache[id] = blocks
        cachedPageOrder.removeAll { $0 == id }
        cachedPageOrder.append(id)
        while cachedPageOrder.count > 4 { pageCache[cachedPageOrder.removeFirst()] = nil }
    }

    private var creatingTrailingInput: Set<UUID> = []
    private let store: SQLiteStore
    private var pendingWrites: [UUID: Task<Void, Never>] = [:]
    private var latestText: [UUID: String] = [:]
    private var latestFormatting: [UUID: [TextStyleRun]] = [:]
    private var latestTableLayouts: [UUID: TableLayout] = [:]

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
        do {
            pages = try await store.pages()
            // Refresh follows imports, automation and structural mutations.
            // Those operations may change pages that are currently cached.
            pageCache.removeAll()
            cachedPageOrder.removeAll()
        }
        catch { report(error) }
    }

    func select(_ pageID: UUID?) {
        // List can repeat its selection binding while SwiftUI reconciles rows.
        // Do not tear down and rebuild the current editor for those writes.
        guard selectedPageID != pageID else { return }
        cacheCurrentPage()
        pageLoadTask?.cancel()
        let generation = UUID()
        pageLoadGeneration = generation
        selectedPageID = pageID
        selectedBlockIDs = []; blockSelectionAnchor = nil; activeEditingBlockID = nil
        editorFocusRequest = nil
        documentBoundaryRequest = nil
        let cached = pageID.flatMap { pageCache[$0] }
        blocks = cached ?? []
        loadedPageID = cached == nil ? nil : pageID
        pageLoadTask = Task { [weak self] in
            guard let self else { return }
            // Pending edits belong to block IDs, so selection need not wait for I/O.
            // Save before reloading a page to avoid showing an older stored version.
            await flushAll()
            guard !Task.isCancelled, pageLoadGeneration == generation, let pageID else { return }
            // Cached content is visible immediately; revalidate in the background
            // to include mutations that completed after the outgoing snapshot.
            let displayed = blocks
            do {
                let loaded = try await store.blocks(in: pageID)
                guard !Task.isCancelled, pageLoadGeneration == generation else { return }
                // Never overwrite edits made while a cached page was being read.
                guard cached == nil || blocks == displayed else { return }
                let refreshed = loaded.map { block in
                    var block = block
                    if let text = latestText[block.id] {
                        block.text = text
                        block.formatting = latestFormatting[block.id] ?? []
                        block.tableLayout = latestTableLayouts[block.id] ?? block.tableLayout
                    }
                    return block
                }
                if blocks != refreshed { blocks = refreshed }
                loadedPageID = pageID
                ensurePageHasInput()
            } catch {
                if !Task.isCancelled, pageLoadGeneration == generation { report(error) }
            }
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

    func exitBlock(_ block: Block) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), selectedPageID == block.pageID else { return }
        clearBlockSelection()
        if blocks.indices.contains(index + 1), blocks[index + 1].kind == .paragraph, blocks[index + 1].text.isEmpty {
            requestFocus(blocks[index + 1].id, offset: 0)
        } else { addBlock(after: blocks[index]) }
    }

    func addBlock(_ kind: BlockKind = .paragraph, after previous: Block? = nil, text: String = "") {
        guard let id = selectedPageID else { return }
        Task {
            do {
                if let previous, let conversion = pendingConversions[previous.id] { await conversion.value }
                var block = try await store.createBlock(pageID: id, kind: kind, after: previous)
                let initial = text.isEmpty ? kind.initialText : text
                if !initial.isEmpty { try await store.updateBlock(block.id, text: initial); block.text = initial }
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

    func moveBlock(_ block: Block, offset: Int) {
        Task {
            do {
                let ordered = try await store.moveBlock(block.id, pageID: block.pageID, offset: offset)
                guard selectedPageID == block.pageID else { return }
                let positions = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.order) })
                blocks = blocks.map { item in
                    var updated = item; updated.order = positions[item.id] ?? item.order; return updated
                }.sorted { $0.order < $1.order }
            } catch { report(error) }
        }
    }

    func pasteDocument(plain: String?, html: String?, original: String, formatting: [TextStyleRun], selection: NSRange, in block: Block, copiedBlocks: [TransferBlock]? = nil) {
        Task {
            do {
                let source = copiedBlocks == nil ? try await ClipboardDocument.markdown(plain: plain, html: html) : " "
                guard !source.isEmpty else { throw AppError.message(L10n.tr("剪贴板中没有可粘贴的文档内容")) }
                guard selectedPageID == block.pageID, let current = blocks.first(where: { $0.id == block.id }),
                      current.text == original, current.kind == block.kind else {
                    throw AppError.message(L10n.tr("粘贴期间内容已变化，请在目标位置重新粘贴"))
                }
                let combined = ClipboardDocument.replacing(original, formatting: formatting, selection: selection, with: source)
                var imported: [TransferBlock]
                if let copiedBlocks { imported = ClipboardDocument.inserting(copiedBlocks, into: original, formatting: formatting, selection: selection) }
                else { imported = try DocumentTransfer.markdown(combined, title: "", consumeLeadingTitle: false).pages[0].blocks }
                if imported.isEmpty { imported = [TransferBlock(.paragraph)] }
                pendingWrites[current.id]?.cancel(); pendingWrites[current.id] = nil
                latestText[current.id] = nil; latestFormatting[current.id] = nil; latestTableLayouts[current.id] = nil
                let inserted = try await store.replaceBlock(current.id, pageID: current.pageID, with: imported)
                guard selectedPageID == current.pageID, let index = blocks.firstIndex(where: { $0.id == current.id }) else { return }
                blocks.replaceSubrange(index...index, with: inserted)
                saving = !latestText.isEmpty || !pendingConversions.isEmpty
                clearBlockSelection()
                if let last = inserted.last { requestFocus(last.id, offset: last.text.utf16.count) }
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
        latestTableLayouts[block.id] = updated.tableLayout
        scheduleWrite(block.id)
    }

    func changeTableLayout(_ layout: TableLayout, in block: Block) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), blocks[index].kind == .table,
              blocks[index].tableLayout != layout else { return }
        blocks[index].tableLayout = layout
        latestText[block.id] = blocks[index].text
        latestFormatting[block.id] = blocks[index].formatting
        latestTableLayouts[block.id] = layout
        scheduleWrite(block.id)
    }

    func changeTableCells(_ rows: [[String]], in block: Block) {
        guard let current = blocks.first(where: { $0.id == block.id }), current.kind == .table,
              let columns = rows.first?.count, columns > 0, rows.allSatisfy({ $0.count == columns }),
              let data = try? JSONEncoder().encode(rows) else { return }
        changeText(String(decoding: data, as: UTF8.self), in: current)
        var layout = current.tableLayout.fitted(rows: rows.count, columns: columns)
        layout.cellsArePlain = true
        changeTableLayout(layout, in: current)
    }

    func resizeTable(column: Int? = nil, row: Int? = nil, size: Double, in block: Block) {
        guard let current = blocks.first(where: { $0.id == block.id }), current.kind == .table,
              let rows = try? JSONDecoder().decode([[String]].self, from: Data(current.text.utf8)),
              let columns = rows.first?.count, columns > 0 else { return }
        // Merge against live state: a row drag immediately after a column drag
        // must not overwrite that column with an older view snapshot.
        var layout = current.tableLayout.fitted(rows: rows.count, columns: columns)
        if let column, layout.columnWidths.indices.contains(column) { layout.columnWidths[column] = TableLayout.width(size) }
        if let row, layout.rowHeights.indices.contains(row) { layout.rowHeights[row] = TableLayout.height(size) }
        changeTableLayout(layout, in: current)
    }

    private func scheduleWrite(_ id: UUID) {
        pendingWrites[id]?.cancel()
        if !saving { saving = true }
        pendingWrites[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.flush(id)
        }
    }

    func flush(_ id: UUID) async {
        if let conversion = pendingConversions[id] { await conversion.value }
        guard let text = latestText[id] else { return }
        do {
            let formatting = latestFormatting[id] ?? []
            let layout = latestTableLayouts[id] ?? TableLayout()
            try await store.updateBlock(id, text: text, formatting: formatting, tableLayout: layout)
            if latestText[id] == text && latestFormatting[id] == formatting && latestTableLayouts[id] == layout { latestText[id] = nil; latestFormatting[id] = nil; latestTableLayouts[id] = nil }
            saving = !latestText.isEmpty || !pendingConversions.isEmpty
        } catch { report(error) }
    }

    func flushAll() async {
        for conversion in Array(pendingConversions.values) { await conversion.value }
        for id in Array(latestText.keys) { await flush(id) }
    }

    func exportDocument(name: String, pageID: UUID?, includeChildren: Bool, includeArchived: Bool) async throws -> TransferDocument {
        guard !workspaceTransitioning, !automationBusy else { throw AppError.message(L10n.tr("正在执行其他操作，请稍后重试")) }
        automationBusy = true; defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message(L10n.tr("存在未保存内容，导出已停止")) }
        return try await store.transferSnapshot(name: name, pageID: pageID, includeChildren: includeChildren, includeArchived: includeArchived)
    }

    func importDocument(_ document: TransferDocument) async throws -> Int {
        guard !workspaceTransitioning, !automationBusy else { throw AppError.message(L10n.tr("正在执行其他操作，请稍后重试")) }
        automationBusy = true; defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message(L10n.tr("存在未保存内容，导入已停止")) }
        let ids = try await store.importTransfer(document)
        await refreshPages()
        if let first = ids.first(where: { id in pages.contains { $0.id == id && !$0.archived } }) { select(first) }
        return ids.count
    }

    func insertMedia(_ kind: BlockKind, text: String, pageID: UUID) async throws {
        guard !workspaceTransitioning, !automationBusy, [.image, .audio].contains(kind),
              pages.contains(where: { $0.id == pageID && !$0.archived }) else { throw AppError.message(L10n.tr("目标页面不可用，请重新选择页面")) }
        automationBusy = true
        defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message(L10n.tr("尚有内容未保存，请稍后重试")) }
        if kind == .image { _ = try ImageSource.validated(text) }
        let block = try await store.createBlock(pageID: pageID, kind: kind)
        try await store.updateBlock(block.id, text: text)
        if selectedPageID == pageID {
            var inserted = block; inserted.text = text; blocks.append(inserted)
        }
    }

    func applyMarkdownHeading(_ text: String, formatting: [TextStyleRun], in block: Block, selection: NSRange? = nil) -> Bool {
        guard let current = blocks.first(where: { $0.id == block.id }), current.kind == .paragraph || current.kind.isHeading,
              let match = DocumentTransfer.firstMatch(#"^(#{1,3})[ \t]+([^\r\n]*)$"#, text) else { return false }
        let title = match[2]
        let prefix = text.utf16.count - title.utf16.count
        let range = NSRange(location: prefix, length: title.utf16.count)
        let runs = formatting.compactMap { run -> TextStyleRun? in
            guard let valid = run.validRange(in: text) else { return nil }
            let overlap = NSIntersectionRange(valid, range)
            guard overlap.length > 0 else { return nil }
            var style = run.style
            style.fontSize = nil
            return style.isEmpty ? nil : TextStyleRun(location: overlap.location - prefix, length: overlap.length, style: style)
        }
        insertSlashCommand(match[1].count == 1 ? .heading : match[1].count == 2 ? .heading2 : .heading3,
                           in: block, text: title, formatting: runs, focusOffset: selection.map { max(0, min(title.utf16.count, $0.location - prefix)) } ?? title.utf16.count)
        return true
    }

    func insertSlashCommand(_ kind: BlockKind, in block: Block, text: String? = nil, formatting: [TextStyleRun] = [], focusOffset: Int = 0) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let original = blocks[index]
        var updated = original
        updated.kind = kind
        updated.text = text ?? kind.initialText
        updated.formatting = formatting; updated.checked = false
        updated.language = "Plain Text"; updated.collapsed = false; updated.tableLayout = TableLayout()
        pendingWrites[block.id]?.cancel(); pendingWrites[block.id] = nil
        latestText[block.id] = nil; latestFormatting[block.id] = nil; latestTableLayouts[block.id] = nil
        blocks[index] = updated
        let revision = (editorContentRevisions[block.id] ?? 0) &+ 1
        editorContentRevisions[block.id] = revision
        clearBlockSelection()
        if kind.acceptsTextInput || kind == .table { requestFocus(block.id, offset: focusOffset) }
        else { editorFocusRequest = nil }
        let previous = pendingConversions[block.id]
        pendingConversions[block.id] = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            defer {
                if editorContentRevisions[block.id] == revision { pendingConversions[block.id] = nil }
                saving = !latestText.isEmpty || !pendingConversions.isEmpty
            }
            do {
                try await store.applyBlockCommand(block.id, kind: kind, text: updated.text, formatting: updated.formatting)
            }
            catch {
                pageCache[original.pageID] = nil
                cachedPageOrder.removeAll { $0 == original.pageID }
                if editorContentRevisions[block.id] == revision {
                    pendingConversions[block.id] = nil
                    if let current = blocks.firstIndex(where: { $0.id == block.id }), blocks[current] == updated {
                        blocks[current] = original
                        editorContentRevisions[block.id] = revision &+ 1
                    }
                }
                report(error)
            }
        }
        saving = true
    }

    @discardableResult
    func convertToHeading(_ level: Int, text: String, formatting: [TextStyleRun], selection: NSRange, in block: Block) -> Bool {
        guard (1...3).contains(level), blocks.contains(where: { $0.id == block.id }) else { return false }
        let runs = formatting.compactMap { run -> TextStyleRun? in
            var run = run
            // Heading size follows its level, rather than a pasted/body size.
            run.style.fontSize = nil
            return run.style.isEmpty ? nil : run
        }
        insertSlashCommand(level == 1 ? .heading : level == 2 ? .heading2 : .heading3,
                           in: block, text: text, formatting: runs, focusOffset: min(selection.location, text.utf16.count))
        return true
    }

    func changeKind(_ kind: BlockKind, of block: Block) {
        if kind.isHeading, let current = blocks.first(where: { $0.id == block.id }) {
            convertToHeading(kind == .heading ? 1 : kind == .heading2 ? 2 : 3, text: current.text,
                             formatting: current.formatting, selection: NSRange(location: current.text.utf16.count, length: 0), in: current)
            return
        }
        guard let index = blocks.firstIndex(where: { $0.id == block.id }), blocks[index].kind != kind else { return }
        let previous = blocks[index].kind
        blocks[index].kind = kind
        Task {
            do { try await store.setBlockKind(block.id, kind: kind) }
            catch {
                if let index = blocks.firstIndex(where: { $0.id == block.id }), blocks[index].kind == kind {
                    blocks[index].kind = previous
                }
                report(error)
            }
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

    func copySelectedBlocks() {
        let selected = blocks.filter { selectedBlockIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        ClipboardDocument.copyBlocks(selected.map(TransferBlock.init))
    }

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
        for id in ids { latestText[id] = nil; latestFormatting[id] = nil; latestTableLayouts[id] = nil }
        blocks.removeAll { ids.contains($0.id) }
        saving = !latestText.isEmpty || !pendingConversions.isEmpty; clearBlockSelection()
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
        latestFormatting[block.id] = nil; latestTableLayouts[block.id] = nil
        selectedBlockIDs.remove(block.id)
        saving = !latestText.isEmpty || !pendingConversions.isEmpty
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
        guard !automationBusy, !workspaceTransitioning else { throw AppError.message(L10n.tr("已有操作正在执行，请稍后重试")) }
        automationBusy = true
        defer { automationBusy = false }
        await flushAll()
        guard !saving else { throw AppError.message(L10n.tr("存在未保存内容，操作已停止")) }
        await refreshPages()
        func id(_ key: String) throws -> UUID {
            guard let value = arguments[key], let id = UUID(uuidString: value) else { throw AppError.message(L10n.tr("缺少有效的 \(key)")) }
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
            try await store.renamePage(page.id, title: arguments["title"] ?? L10n.tr("未命名"))
            result = ["page_id": page.id.uuidString]
        case "rename_page":
            let pageID = try id("page_id"); try active(pageID)
            guard let title = arguments["title"] else { throw AppError.message(L10n.tr("缺少标题")) }
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
            guard let text = arguments["text"], !text.isEmpty else { throw AppError.message(L10n.tr("正文不能为空")) }
            let block = try await store.createBlock(pageID: pageID, kind: .paragraph)
            try await store.updateBlock(block.id, text: text)
        case "open_page":
            let pageID = try id("page_id"); try active(pageID)
            selectedPageID = pageID
        default: throw AppError.message(L10n.tr("不支持的操作：\(name)"))
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

