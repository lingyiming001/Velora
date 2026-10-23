import Foundation

struct InlineTextStyle: Codable, Hashable, Sendable {
    var code = false
    var link: String?
    var fontFamily: String?
    var fontSize: Double?
    var bold: Bool?
    var italic: Bool?
    var underline = false
    var strikethrough = false
    var color: String?
    var highlight: String?
    var isEmpty: Bool { self == InlineTextStyle() }
}

struct TextStyleRun: Codable, Hashable, Sendable {
    var location: Int
    var length: Int
    var style: InlineTextStyle
    func validRange(in text: String) -> NSRange? {
        guard location >= 0, length > 0, location <= text.utf16.count, length <= text.utf16.count - location else { return nil }
        return NSRange(location: location, length: length)
    }
}

extension InlineTextStyle {
    private enum CodingKeys: String, CodingKey { case code, link, fontFamily, fontSize, bold, italic, underline, strikethrough, color, highlight }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decodeIfPresent(Bool.self, forKey: .code) ?? false
        link = try values.decodeIfPresent(String.self, forKey: .link)
        fontFamily = try values.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize)
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold)
        italic = try values.decodeIfPresent(Bool.self, forKey: .italic)
        underline = try values.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        strikethrough = try values.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        color = try values.decodeIfPresent(String.self, forKey: .color)
        highlight = try values.decodeIfPresent(String.self, forKey: .highlight)
    }
}
