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
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let italic = style.italic { attributes[.obliqueness] = italic && !NSFontManager.shared.traits(of: font).contains(.italicFontMask) ? 0.18 : 0.0 }
        attributes[.underlineStyle] = style.underline ? NSUnderlineStyle.single.rawValue : 0
        attributes[.strikethroughStyle] = style.strikethrough ? NSUnderlineStyle.single.rawValue : 0
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
    case bold, italic, underline, strikethrough, clear
    case size(Double), family(String), color(String?), highlight(String?)
}

struct SelectionFormatBar: View {
    var style: InlineTextStyle
    var apply: (TextFormatAction) -> Void
    private let colors: [(String, String)] = [("红色", "D93D3D"), ("橙色", "D97015"), ("绿色", "24844B"), ("蓝色", "2563EB"), ("紫色", "7C3AED"), ("灰色", "737373"), ("黑色", "222222")]
    var body: some View {
        HStack(spacing: 4) {
            Menu(style.fontFamily ?? "系统字体") {
                ForEach(["系统字体", "PingFang SC", "Songti SC", "Heiti SC", "Helvetica Neue", "Arial", "Times New Roman", "Menlo"], id: \.self) { family in
                    Button(family) { apply(.family(family)) }
                }
            }.frame(width: 95)
            Menu("\(Int(style.fontSize ?? 17))") {
                ForEach([10, 12, 14, 16, 17, 18, 20, 24, 28, 32, 40, 48], id: \.self) { size in Button("\(size) pt") { apply(.size(Double(size))) } }
            }.frame(width: 43).help("文字大小")
            Divider().frame(height: 18)
            formatButton("B", help: "加粗 ⌘B", active: style.bold == true) { apply(.bold) }
            formatButton("I", help: "斜体 ⌘I", active: style.italic == true) { apply(.italic) }
            formatButton("U", help: "下划线 ⌘U", active: style.underline) { apply(.underline) }
            formatButton("S̶", help: "删除线", active: style.strikethrough) { apply(.strikethrough) }
            Menu {
                Button("自动颜色") { apply(.color(nil)) }
                ForEach(colors, id: \.0) { name, hex in Button(name) { apply(.color(hex)) } }
            } label: { Image(systemName: "textformat").foregroundStyle(Color(nsColor: style.color.flatMap(RichTextFormatting.color) ?? .labelColor)) }
                .frame(width: 35).help("文字颜色")
            Menu {
                Button("无高亮") { apply(.highlight(nil)) }
                Button("黄色") { apply(.highlight("FFF1A8")) }
                Button("绿色") { apply(.highlight("D4F4DD")) }
                Button("蓝色") { apply(.highlight("DCEAFF")) }
                Button("粉色") { apply(.highlight("FCE0EE")) }
            } label: { Image(systemName: "highlighter") }.frame(width: 33).help("背景高亮")
            Button { apply(.clear) } label: { Image(systemName: "textformat.alt") }.help("清除格式")
        }.font(.system(size: 12)).buttonStyle(.borderless).padding(9).fixedSize()
    }
    private func formatButton(_ text: String, help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(text).fontWeight(.semibold).frame(width: 25, height: 25).background(active ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4)) }.help(help)
    }
}
