import Foundation

struct Page: Identifiable, Hashable, Sendable {
    let id: UUID
    var parentID: UUID?
    var title: String
    var order: Int64
    var archived: Bool
    var updatedAt: Date
    var trashBatch: String? = nil
}

/// Keep copy names short, including pages created by the older text-suffix rule.
enum PageCopyNaming {
    static func title(for source: String, siblings: Set<String>) -> String {
        var base = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = base.range(of: #"(?: (?:副本|copy)(?: [0-9]+)?)+$"#, options: [.regularExpression, .caseInsensitive]) {
            base.removeSubrange(range)
        }
        var sourceNumber = 0
        if let space = base.lastIndex(of: " "), let number = Int(base[base.index(after: space)...]), number > 0 {
            sourceNumber = number
            base = String(base[..<space])
        }
        if base.isEmpty { base = L10n.tr("未命名") }
        let prefix = base + " "
        let maximum = siblings.reduce(sourceNumber) { result, title in
            guard title.hasPrefix(prefix), let number = Int(title.dropFirst(prefix.count)), number > 0 else { return result }
            return max(result, number)
        }
        let next = maximum.addingReportingOverflow(1)
        var number = next.overflow ? 1 : next.partialValue
        while siblings.contains(prefix + String(number)) { number += 1 }
        return prefix + String(number)
    }
}
