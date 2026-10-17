import Foundation

enum StoreError: LocalizedError {
    case database(String)
    case invalidMove
    case missingPage

    var errorDescription: String? {
        switch self {
        case .database(let message): "数据库错误：\(message)"
        case .invalidMove: "无法将页面移入自身或子页面。"
        case .missingPage: "页面已不存在。"
        }
    }
}
