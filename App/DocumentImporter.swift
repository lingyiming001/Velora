import Foundation

@MainActor
enum DocumentImporter {
    static func loadSelection(_ urls: [URL]) throws -> TransferDocument {
        guard !urls.isEmpty, urls.count <= 1000 else { throw AppError.message("一次最多导入 1,000 个文件") }
        var result: [TransferPage] = []; var payloadSize = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let isDirectory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            let document = try isDirectory ? directory(url) : DocumentTransfer.load(url)
            payloadSize += document.pages.reduce(0) { $0 + $1.title.utf8.count + $1.blocks.reduce(0) { $0 + $1.text.utf8.count } }
            guard payloadSize <= DocumentTransfer.maximumFileSize else { throw AppError.message("本次导入的内容总计超过 100 MB") }
            result.append(contentsOf: remapped(document.pages))
        }
        let document = TransferDocument(name: urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "导入文件", pages: result)
        _ = try document.orderedPages()
        return document
    }
    static func remapped(_ pages: [TransferPage], parentID: UUID? = nil) -> [TransferPage] {
        let ids = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, UUID()) })
        return pages.map { page in
            TransferPage(id: ids[page.id]!, parentID: page.parentID.flatMap { ids[$0] } ?? parentID,
                         title: page.title, archived: page.archived, blocks: page.blocks)
        }
    }
    static func directory(_ root: URL) throws -> TransferDocument {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            throw AppError.message("无法读取文件夹")
        }
        var files: [URL] = []; var bytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                if url.lastPathComponent.contains(".assets-") { enumerator.skipDescendants() }
                continue
            }
            guard TransferFormat.detect(url) != nil else { continue }
            bytes += values.fileSize ?? 0; files.append(url)
            guard files.count <= 1000, bytes <= DocumentTransfer.maximumFileSize else { throw AppError.message("文件夹最多包含 1,000 个文档，总计不超过 100 MB") }
        }
        guard !files.isEmpty else { throw AppError.message("文件夹中没有支持的文档") }
        var pages: [TransferPage] = []
        var folders: [String: UUID] = [:]
        func ensureFolder(_ url: URL) -> UUID {
            if let id = folders[url.path] { return id }
            let parentID: UUID? = url.standardizedFileURL == root.standardizedFileURL ? nil : ensureFolder(url.deletingLastPathComponent())
            let page = TransferPage(parentID: parentID, title: url.lastPathComponent, blocks: [])
            folders[url.path] = page.id; pages.append(page); return page.id
        }
        for file in files.sorted(by: { $0.path < $1.path }) {
            let folder = ensureFolder(file.deletingLastPathComponent())
            let document = try DocumentTransfer.load(file)
            if file.deletingPathExtension().lastPathComponent.lowercased() == "index", document.pages.count == 1,
               let index = pages.firstIndex(where: { $0.id == folder }) {
                pages[index].title = document.pages[0].title
                pages[index].blocks = document.pages[0].blocks
            } else { pages.append(contentsOf: remapped(document.pages, parentID: folder)) }
        }
        let document = TransferDocument(name: root.lastPathComponent, pages: pages)
        _ = try document.orderedPages(); return document
    }
}
