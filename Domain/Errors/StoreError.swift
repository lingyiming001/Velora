import Foundation

enum StoreError: LocalizedError {
    case database(String)
    case invalidMove
    case missingPage

    var errorDescription: String? {
        switch self {
        case .database(let message): L10n.tr("数据库错误：\(L10n.text(message))")
        case .invalidMove: L10n.text("无法将页面移入自身或子页面。")
        case .missingPage: L10n.text("页面已不存在。")
        }
    }
}
