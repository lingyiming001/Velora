import AppKit
import SwiftUI

enum RichTextFormatting {
    static func color(_ hex: String) -> NSColor? {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return NSColor(deviceRed: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
    }
    static func hex(_ color: NSColor) -> String? {
        guard color != .labelColor, color != .textColor, let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    static func attributes(_ style: InlineTextStyle, base: NSFont) -> [NSAttributedString.Key: Any] {
        let size = CGFloat(min(96, max(8, style.fontSize ?? Double(base.pointSize))))
        var font = style.fontFamily.flatMap { NSFont(name: $0, size: size) } ?? NSFontManager.shared.convert(base, toSize: size)
        let baseTraits = NSFontManager.shared.traits(of: base)
        let bold = style.bold ?? baseTraits.contains(.boldFontMask)
        let italic = style.italic ?? baseTraits.contains(.italicFontMask)
        font = NSFontManager.shared.convert(font, toHaveTrait: bold ? .boldFontMask : .unboldFontMask)
        font = NSFontManager.shared.convert(font, toHaveTrait: italic ? .italicFontMask : .unitalicFontMask)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key("VeloraInlineCode"): style.code]
        if let italic = style.italic { attributes[.obliqueness] = italic && !NSFontManager.shared.traits(of: font).contains(.italicFontMask) ? 0.18 : 0.0 }
        attributes[.underlineStyle] = style.underline ? NSUnderlineStyle.single.rawValue : 0
        attributes[.strikethroughStyle] = style.strikethrough ? NSUnderlineStyle.single.rawValue : 0
        if let value = style.link.flatMap(HTMLTransfer.safeLink) { attributes[.link] = value }
        if let value = style.color.flatMap(color) { attributes[.foregroundColor] = value }
        if let value = style.highlight.flatMap(color) { attributes[.backgroundColor] = value }
        return attributes
    }
    static func attributed(_ text: String, runs: [TextStyleRun], base: NSFont) -> NSAttributedString {
        let output = NSMutableAttributedString(string: text, attributes: [.font: base, .foregroundColor: NSColor.labelColor])
        for run in runs { if let range = run.validRange(in: text) { output.addAttributes(attributes(run.style, base: base), range: range) } }
        return output
    }
    static func runs(_ text: NSAttributedString, base: NSFont) -> [TextStyleRun] {
        var result: [TextStyleRun] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let font = attrs[.font] as? NSFont ?? base
            let traits = NSFontManager.shared.traits(of: font); let baseTraits = NSFontManager.shared.traits(of: base)
            var style = InlineTextStyle()
            style.code = attrs[NSAttributedString.Key("VeloraInlineCode")] as? Bool ?? false
            style.link = (attrs[.link] as? URL)?.absoluteString ?? (attrs[.link] as? String)
            if font.familyName != base.familyName { style.fontFamily = font.familyName ?? font.fontName }
            if abs(font.pointSize - base.pointSize) > 0.1 { style.fontSize = Double(font.pointSize) }
            if traits.contains(.boldFontMask) != baseTraits.contains(.boldFontMask) { style.bold = traits.contains(.boldFontMask) }
            let italic = traits.contains(.italicFontMask) || ((attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0) > 0
            if italic != baseTraits.contains(.italicFontMask) { style.italic = italic }
            style.underline = (attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0
            style.strikethrough = (attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0
            style.color = (attrs[.foregroundColor] as? NSColor).flatMap(hex)
            style.highlight = (attrs[.backgroundColor] as? NSColor).flatMap(hex)
            if !style.isEmpty { result.append(TextStyleRun(location: range.location, length: range.length, style: style)) }
        }
        return result
    }
}

enum TextFormatAction {
    case bold, italic, underline, strikethrough, clear, copyStyle, pasteStyle
    case size(Double), family(String), color(String?), highlight(String?)
}

/// A separate pasteboard keeps visual styles independent of copied content.
final class TextStyleClipboard: ObservableObject {
    static let shared = TextStyleClipboard()
    static let type = NSPasteboard.PasteboardType("com.velora.text-style")
    private let pasteboard: NSPasteboard
    @Published private(set) var style: InlineTextStyle?

    init(pasteboard: NSPasteboard = NSPasteboard(name: .init("com.velora.text-style"))) {
        self.pasteboard = pasteboard
        style = pasteboard.data(forType: Self.type).flatMap { try? JSONDecoder().decode(InlineTextStyle.self, from: $0) }
    }
    func read() -> InlineTextStyle? {
        pasteboard.data(forType: Self.type).flatMap { try? JSONDecoder().decode(InlineTextStyle.self, from: $0) }
    }
    func copy(attributes: [NSAttributedString.Key: Any], base: NSFont) {
        let font = attributes[.font] as? NSFont ?? base
        let traits = NSFontManager.shared.traits(of: font)
        var copied = InlineTextStyle()
        copied.fontFamily = font.familyName ?? font.fontName
        copied.fontSize = Double(font.pointSize)
        copied.bold = traits.contains(.boldFontMask)
        copied.italic = traits.contains(.italicFontMask) || ((attributes[.obliqueness] as? NSNumber)?.doubleValue ?? 0) > 0
        copied.underline = (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0
        copied.strikethrough = (attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0
        copied.color = (attributes[.foregroundColor] as? NSColor).flatMap(RichTextFormatting.hex)
        copied.highlight = (attributes[.backgroundColor] as? NSColor).flatMap(RichTextFormatting.hex)
        guard let data = try? JSONEncoder().encode(copied) else { return }
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: Self.type) else { return }
        style = copied
    }
}

final class SelectionFormatState: ObservableObject {
    @Published var style: InlineTextStyle
    init(_ style: InlineTextStyle) { self.style = style }
}

struct SelectionFormatBar: View {
    @ObservedObject var state: SelectionFormatState
    @ObservedObject var clipboard: TextStyleClipboard
    private var style: InlineTextStyle { state.style }
    var apply: (TextFormatAction) -> Void
    private let colors: [(String, String)] = [(L10n.tr("红色"), "D93D3D"), (L10n.tr("橙色"), "D97015"), (L10n.tr("绿色"), "24844B"), (L10n.tr("蓝色"), "2563EB"), (L10n.tr("紫色"), "7C3AED"), (L10n.tr("灰色"), "737373"), (L10n.tr("黑色"), "222222")]
    var body: some View {
        HStack(spacing: 4) {
            Menu(style.fontFamily ?? L10n.text("系统字体")) {
                ForEach(["系统字体", "PingFang SC", "Songti SC", "Heiti SC", "Helvetica Neue", "Arial", "Times New Roman", "Menlo"], id: \.self) { family in
                    Button(L10n.text(family)) { apply(.family(family)) }
                }
            }.frame(width: 95)
            Menu("\(Int(style.fontSize ?? 17))") {
                ForEach([10, 12, 14, 16, 17, 18, 20, 24, 28, 32, 40, 48], id: \.self) { size in Button("\(size) pt") { apply(.size(Double(size))) } }
            }.frame(width: 43).help(L10n.tr("文字大小"))
            Divider().frame(height: 18)
            formatButton("B", help: L10n.tr("加粗 ⌘B"), active: style.bold == true) { apply(.bold) }
            formatButton("I", help: L10n.tr("斜体 ⌘I"), active: style.italic == true) { apply(.italic) }
            formatButton("U", help: L10n.tr("下划线 ⌘U"), active: style.underline) { apply(.underline) }
            formatButton("S̶", help: L10n.tr("删除线"), active: style.strikethrough) { apply(.strikethrough) }
            Menu {
                Button(L10n.tr("自动颜色")) { apply(.color(nil)) }
                ForEach(colors, id: \.0) { name, hex in Button(name) { apply(.color(hex)) } }
            } label: { Image(systemName: "textformat").foregroundStyle(Color(nsColor: style.color.flatMap(RichTextFormatting.color) ?? .labelColor)) }
                .frame(width: 35).help(L10n.tr("文字颜色"))
            Menu {
                Button(L10n.tr("无高亮")) { apply(.highlight(nil)) }
                Button(L10n.tr("黄色")) { apply(.highlight("FFF1A8")) }
                Button(L10n.tr("绿色")) { apply(.highlight("D4F4DD")) }
                Button(L10n.tr("蓝色")) { apply(.highlight("DCEAFF")) }
                Button(L10n.tr("粉色")) { apply(.highlight("FCE0EE")) }
            } label: { Image(systemName: "highlighter") }.frame(width: 33).help(L10n.tr("背景高亮"))
            Menu {
                Button(L10n.tr("复制样式")) { apply(.copyStyle) }
                Button(L10n.tr("粘贴样式")) { apply(.pasteStyle) }.disabled(clipboard.style == nil)
            } label: { Label(L10n.tr("样式"), systemImage: "paintbrush") }
                .help(L10n.tr("复制样式 ⌥⌘C · 粘贴样式 ⌥⌘V"))
            Button { apply(.clear) } label: { Image(systemName: "textformat.alt") }.help(L10n.tr("清除格式"))
        }.font(.system(size: 12)).buttonStyle(.borderless).padding(9).fixedSize()
    }
    private func formatButton(_ text: String, help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(text).fontWeight(.semibold).frame(width: 25, height: 25).background(active ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4)) }.help(help)
    }
}
