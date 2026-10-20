import Foundation

enum BlockKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case paragraph, heading, heading2, heading3, bullet, numbered, todo, toggle, quote, callout, divider
    case image, video, audio, file, bookmark
    case code, table, tableOfContents

    var id: String { rawValue }
    static let categories = ["基础块", "媒体与链接", "进阶块"]
    var category: String {
        switch self {
        case .image, .video, .audio, .file, .bookmark: "媒体与链接"
        case .code, .table, .tableOfContents: "进阶块"
        default: "基础块"
        }
    }
    var label: String {
        switch self {
        case .paragraph: "正文"
        case .heading: "标题 1"
        case .heading2: "标题 2"
        case .heading3: "标题 3"
        case .bullet: "项目列表"
        case .numbered: "有序列表"
        case .todo: "待办"
        case .toggle: "折叠块"
        case .quote: "引用"
        case .callout: "提示块"
        case .divider: "分割线"
        case .image: "图片"
        case .video: "视频"
        case .audio: "音频"
        case .file: "文件链接"
        case .bookmark: "网页书签"
        case .code: "代码"
        case .table: "简单表格"
        case .tableOfContents: "页面目录"
        }
    }
    var symbol: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading, .heading2, .heading3: "textformat.size"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .todo: "checkmark.square"
        case .toggle: "chevron.right"
        case .quote: "text.quote"
        case .callout: "lightbulb"
        case .divider: "minus"
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .file: "doc"
        case .bookmark: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .table: "tablecells"
        case .tableOfContents: "list.bullet.indent"
        }
    }
    var isHeading: Bool { [.heading, .heading2, .heading3].contains(self) }
    var isMedia: Bool { [.image, .video, .audio, .file, .bookmark].contains(self) }
    var hint: String {
        switch self {
        case .heading: "#"
        case .heading2: "##"
        case .heading3: "###"
        case .bullet: "-"
        case .numbered: "1."
        case .todo: "[]"
        case .quote: ">"
        case .divider: "---"
        case .code: "```"
        default: rawValue
        }
    }
    var placeholder: String {
        if isMedia { return "粘贴 https:// 链接" }
        switch self {
        case .code: return "输入或粘贴代码"
        case .toggle: return "首行作为标题，换行输入可折叠内容"
        case .callout: return "记录提示或重要信息"
        default: return "输入 / 插入内容，或直接开始书写"
        }
    }

}

struct Block: Identifiable, Hashable, Sendable {
    let id: UUID
    let pageID: UUID
    var kind: BlockKind
    var text: String
    var order: Int64
    var checked: Bool
    var language: String = "Plain Text"
    var collapsed: Bool = false
    var formatting: [TextStyleRun] = []

    var hasContent: Bool {
        if kind == .divider || kind == .tableOfContents { return true }
        if kind == .table, let data = text.data(using: .utf8),
           let rows = try? JSONDecoder().decode([[String]].self, from: data) {
            return rows.joined().contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
