import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

enum ImageSource {
    static let maximumBytes = 12 * 1024 * 1024
    static func validated(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("data:image/") {
            guard value.utf8.count <= maximumBytes * 4 / 3 + 200,
                  let split = value.range(of: ";base64,"),
                  let data = Data(base64Encoded: String(value[split.upperBound...])),
                  data.count <= maximumBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { throw AppError.message(L10n.tr("图片数据无效或超过 12 MB")) }
            return value
        }
        guard let parts = URLComponents(string: value), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, let url = parts.url else {
            throw AppError.message(L10n.tr("请输入完整的 HTTPS 图片 URL，或选择本地图片"))
        }
        return url.absoluteString
    }
    static func embedded(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= maximumBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw AppError.message(L10n.tr("请选择有效图片，文件大小不超过 12 MB"))
        }
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let mime = type?.preferredMIMEType ?? ""
        if ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) {
            return "data:\(mime);base64," + data.base64EncodedString()
        }
        guard let png = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]), png.count <= maximumBytes else {
            throw AppError.message(L10n.tr("图片转换后超过 12 MB，请缩小图片后重试"))
        }
        return "data:image/png;base64," + png.base64EncodedString()
    }
    static func load(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumBytes else { throw AppError.message(L10n.tr("图片文件不能超过 12 MB")) }
        return try embedded(Data(contentsOf: url))
    }
    static func thumbnail(_ value: String) -> NSImage? {
        guard let split = value.range(of: ";base64,"), let data = Data(base64Encoded: String(value[split.upperBound...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

struct MediaImageView: View {
    let source: String
    @State private var local: NSImage?
    @State private var loaded = false
    var body: some View {
        Group {
            if source.hasPrefix("data:image/") {
                if let local { Image(nsImage: local).resizable().scaledToFit() }
                else if loaded { Label(L10n.tr("本地图片数据无法读取，请重新选择"), systemImage: "exclamationmark.triangle") }
                else { ProgressView() }
            } else if let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: Label(L10n.tr("图片无法加载，请检查 URL、网络或访问权限"), systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    default: ProgressView()
                    }
                }
            } else { Label(L10n.tr("尚未选择图片"), systemImage: "photo").foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
        .task(id: source) { loaded = false; local = source.hasPrefix("data:image/") ? ImageSource.thumbnail(source) : nil; loaded = true }
    }
}

struct ImageSourcePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 1
    @State private var urlText: String
    @State private var localImage = ""
    @State private var filename = ""
    @State private var error = ""
    let onSelect: (String) -> Void
    init(initialValue: String = "", onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        _urlText = State(initialValue: initialValue.hasPrefix("data:") ? "" : initialValue)
        _localImage = State(initialValue: initialValue.hasPrefix("data:") ? initialValue : "")
        _mode = State(initialValue: initialValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || initialValue.hasPrefix("data:") ? 1 : 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("选择图片")).font(.title2.bold())
            Picker(L10n.tr("来源"), selection: $mode) { Text(L10n.tr("本地文件")).tag(1); Text(L10n.tr("图片 URL")).tag(0) }.pickerStyle(.segmented)
            if mode == 0 {
                TextField("https://example.com/image.png", text: $urlText).textFieldStyle(.roundedBorder)
                Text(L10n.tr("请输入图片文件的直接链接，推荐使用 HTTPS。")).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(L10n.tr("选择本地图片…")) { chooseFile() }
                    Text(filename.isEmpty ? (localImage.isEmpty ? L10n.tr("尚未选择") : L10n.tr("已保存的本地图片")) : filename).lineLimit(1)
                }
                Text(L10n.tr("支持系统可识别的图片，最大 12 MB；保存副本到页面，原文件移动后仍可查看。")).font(.caption).foregroundStyle(.secondary)
                if !localImage.isEmpty { MediaImageView(source: localImage).frame(height: 220) }
            }
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("使用图片")) {
                    do { onSelect(try ImageSource.validated(mode == 0 ? urlText : localImage)); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
    }
    private func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { localImage = try ImageSource.load(url); filename = url.lastPathComponent; error = "" }
        catch { self.error = error.localizedDescription }
    }
}

enum MediaSource {
    static func url(_ source: String) -> URL? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              parts.user == nil, parts.password == nil, let url = parts.url else { return nil }
        if scheme == "file" { return url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") ? url : nil }
        return ["https", "http"].contains(scheme) && !(parts.host ?? "").isEmpty ? url : nil
    }
}

struct MediaSourcePicker: View {
    let kind: BlockKind
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var error = ""
    init(kind: BlockKind, source: String, onSelect: @escaping (String) -> Void) {
        self.kind = kind; self.onSelect = onSelect; _source = State(initialValue: source)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(kind.label, systemImage: kind.symbol).font(.title2.weight(.semibold))
            TextField(L10n.tr("链接或本地文件路径"), text: $source).textFieldStyle(.roundedBorder)
            if kind != .bookmark {
                Button(L10n.tr("选择本地文件…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if kind == .video { panel.allowedContentTypes = [.movie] }
                    else if kind == .audio { panel.allowedContentTypes = [.audio] }
                    if panel.runModal() == .OK, let url = panel.url { source = url.absoluteString; error = "" }
                }
                Text(L10n.tr("本地媒体和文件以引用方式打开，移动原文件后需要重新选择。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.tr("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("插入")) {
                    guard let url = MediaSource.url(source), kind != .bookmark || !url.isFileURL else { error = L10n.tr("请输入有效链接或选择本地文件。"); return }
                    if url.isFileURL && !FileManager.default.isReadableFile(atPath: url.path) { error = L10n.tr("文件不存在或无法读取，请重新选择。"); return }
                    onSelect(url.absoluteString); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 480)
    }
}
