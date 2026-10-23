import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var label: String { switch self { case .system: return L10n.text("跟随系统"); case .chinese: return "简体中文"; case .english: return "English" } }
    var locale: Locale { Locale(identifier: resolved) }
    var resolved: String {
        if self != .system { return rawValue }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
}

enum L10n {
    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: ["en", "zh-Hans"].compactMap { code in
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)).map { (code, $0) }
    })
    static var language: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") ?? .system }
    static func text(_ key: String, language: AppLanguage? = nil) -> String {
        let code = (language ?? self.language).resolved
        guard let bundle = bundles[code] else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: language.locale, arguments: arguments)
    }
}

extension L10n {
    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let values: [String]
        init(stringLiteral value: String) { key = value; values = [] }
        init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; values = stringInterpolation.values }
        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var values: [String] = []
            init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity) }
            mutating func appendLiteral(_ literal: String) { key += literal }
            mutating func appendInterpolation<T>(_ value: T) { key += "%@"; values.append(String(describing: value)) }
        }
    }
    static func tr(_ message: Message) -> String {
        let parts = text(message.key).components(separatedBy: "%@")
        guard !message.values.isEmpty else { return parts.joined(separator: "%@") }
        var result = parts[0]
        for index in 1..<parts.count {
            result += (index - 1 < message.values.count ? message.values[index - 1] : "%@") + parts[index]
        }
        return result
    }
}
