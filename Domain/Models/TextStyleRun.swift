import Foundation

struct InlineTextStyle: Codable, Hashable, Sendable {
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
