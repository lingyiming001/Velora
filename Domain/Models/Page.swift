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
